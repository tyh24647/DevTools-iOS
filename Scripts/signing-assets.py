#!/usr/bin/env python3
"""Use existing signing assets; never create credentials or enable provisioning updates."""

import argparse
import base64
import binascii
from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import uuid
import zlib


TARGET_SUFFIXES = {
    "DevTools": "",
    "DevToolsSafari": ".Safari",
    "DevToolsAddBlacklist": ".AddBlacklist",
    "DevToolsAddAllowList": ".AddAllowList",
    "DevToolsShow": ".Show",
    "DevToolsHide": ".Hide",
    "DevToolsEnable": ".Enable",
    "DevToolsDisable": ".Disable",
}
SIGNING_ENV = (
    "DEVTOOLS_CERTIFICATE_P12_BASE64",
    "DEVTOOLS_CERTIFICATE_PASSWORD",
    "DEVTOOLS_PROFILES_TGZ_BASE64",
)
UPLOAD_ENV = ("DEVTOOLS_ASC_KEY_BASE64", "DEVTOOLS_ASC_KEY_ID", "DEVTOOLS_ASC_ISSUER_ID")
MAX_ASSET_BYTES = 4 * 1024 * 1024


class SigningError(Exception):
    """An actionable error that contains no credential or command values."""


def missing_inputs(mode, environment):
    required = SIGNING_ENV + (UPLOAD_ENV if mode == "upload" else ())
    return [name for name in required if not environment.get(name)]


def decoded_secret(name, environment):
    encoded = environment.get(name, "")
    if len(encoded) > MAX_ASSET_BYTES * 2:
        raise SigningError(f"{name} exceeds the supported size limit.")
    try:
        result = base64.b64decode("".join(encoded.split()), validate=True)
    except (ValueError, binascii.Error):
        raise SigningError(f"{name} is not valid Base64.") from None
    if not result or len(result) > MAX_ASSET_BYTES:
        raise SigningError(f"{name} is empty or exceeds the supported size limit.")
    return result


def profile_payloads(data):
    """Read exactly eight flat regular files without extracting archive paths."""
    payloads = {}
    total = 0
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
            uncompressed = compressed.read(MAX_ASSET_BYTES + 64 * 1024 + 1)
        if len(uncompressed) > MAX_ASSET_BYTES + 64 * 1024:
            raise SigningError("Profiles archive exceeds the supported expanded size limit.")
        with tarfile.open(fileobj=io.BytesIO(uncompressed), mode="r:") as archive:
            for index, member in enumerate(archive):
                if index > 8:
                    raise SigningError("Profiles archive contains too many entries.")
                name = member.name
                if member.isdir() and name in (".", "./"):
                    continue
                if name.startswith("./"):
                    name = name[2:]
                path = PurePosixPath(name)
                if (not member.isfile() or len(path.parts) != 1 or
                        path.name != name or not name.endswith(".mobileprovision") or
                        "\\" in name or name in payloads or member.size <= 0 or
                        member.size > 512 * 1024 or len(payloads) >= 8):
                    raise SigningError("Profiles archive must contain exactly eight distinct, flat .mobileprovision files; links and special files are forbidden.")
                total += member.size
                if total > MAX_ASSET_BYTES:
                    raise SigningError("Profiles archive exceeds the supported size limit.")
                stream = archive.extractfile(member)
                payloads[name] = stream.read(member.size + 1)
                if len(payloads[name]) != member.size:
                    raise SigningError("Profiles archive contains an incomplete file.")
    except (tarfile.TarError, OSError, EOFError, zlib.error):
        raise SigningError("Profiles archive is not a valid tar.gz file.") from None
    if len(payloads) != 8:
        raise SigningError("Profiles archive must contain exactly eight .mobileprovision files.")
    return payloads


def validate_profiles(profiles, team, prefix, app_group, identities, now=None):
    """Validate profile metadata and select one common, locally usable certificate."""
    expected = {prefix + suffix for suffix in TARGET_SUFFIXES.values()}
    result = {}
    profile_uuids = set()
    common_certificates = set(identities)
    now = now or datetime.now(timezone.utc)
    for profile, payload in profiles:
        if not isinstance(profile, dict):
            raise SigningError("A provisioning profile must decode to a dictionary.")
        entitlements = profile.get("Entitlements", {})
        if not isinstance(entitlements, dict):
            raise SigningError("A provisioning profile has invalid entitlements.")
        app_id = entitlements.get("application-identifier", "")
        bundle_id = app_id.partition(".")[2] if isinstance(app_id, str) else ""
        if bundle_id not in expected or bundle_id in result:
            raise SigningError("Profiles must match the eight expected bundle IDs exactly, without duplicates or wildcards.")
        expires = profile.get("ExpirationDate")
        if not isinstance(expires, datetime):
            raise SigningError(f"Profile for {bundle_id} has no valid expiration date.")
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        if expires <= now:
            raise SigningError(f"Profile for {bundle_id} has expired.")
        prefixes = profile.get("ApplicationIdentifierPrefix", [])
        if (profile.get("TeamIdentifier") != [team] or
                entitlements.get("com.apple.developer.team-identifier") != team or
                not isinstance(prefixes, list) or app_id.partition(".")[0] not in prefixes):
            raise SigningError(f"Profile for {bundle_id} has a mismatched team or App ID prefix.")
        if (not isinstance(profile.get("Platform"), list) or "iOS" not in profile["Platform"] or
                entitlements.get("get-task-allow") is not False or
                "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices", False) is not False):
            raise SigningError(f"Profile for {bundle_id} is not an iOS App Store distribution profile.")
        groups = entitlements.get("com.apple.security.application-groups", [])
        if not isinstance(groups, list) or app_group not in groups:
            raise SigningError(f"Profile for {bundle_id} does not authorize the required App Group.")
        try:
            profile_uuid = str(uuid.UUID(profile["UUID"])).upper()
        except (KeyError, ValueError, AttributeError, TypeError):
            raise SigningError(f"Profile for {bundle_id} has no valid UUID.") from None
        if profile_uuid in profile_uuids:
            raise SigningError("Different bundle profiles cannot share a UUID.")
        profile_uuids.add(profile_uuid)
        certificates = profile.get("DeveloperCertificates", [])
        if not certificates or any(not isinstance(cert, bytes) for cert in certificates):
            raise SigningError(f"Profile for {bundle_id} contains no valid signing certificate.")
        common_certificates &= {hashlib.sha1(cert).hexdigest().upper() for cert in certificates}
        result[bundle_id] = {"uuid": profile_uuid, "payload": payload}
    if set(result) != expected:
        raise SigningError("A distribution profile is required for the app and each of its seven extensions.")
    if len(common_certificates) != 1:
        raise SigningError("The supplied P12 must provide exactly one valid distribution identity shared by all eight profiles.")
    return result, common_certificates.pop()


def patch_release_settings(source, profiles, team, prefix, identity):
    """Change only signing fields in this repository's eight Release target blocks."""
    seen = set()
    pattern = re.compile(
        r'(?P<header>^[ \t]*[A-F0-9]{24} /\* Release configuration for PBXNativeTarget "(?P<target>[^"]+)" \*/ = \{\n)'
        r'(?P<body>.*?)(?P<footer>^\t\t\};)', re.M | re.S)

    def patch(match):
        target = match["target"]
        if target not in TARGET_SUFFIXES or target in seen:
            raise SigningError("Unexpected or duplicate Release target configuration.")
        seen.add(target)
        bundle_id = prefix + TARGET_SUFFIXES[target]
        body = match["body"]
        settings_match = re.search(r'(buildSettings = \{\n)(.*?)(^\t\t\t\};)', body, re.M | re.S)
        if not settings_match or not re.search(r'^\s*name = Release;', body, re.M):
            raise SigningError("The project configuration format changed; refusing an incomplete signing patch.")
        settings = settings_match[2]
        expected_identifier = '"$(DT_BUNDLE_PREFIX)' + TARGET_SUFFIXES[target] + '"'
        if not re.search(r'^\s*PRODUCT_BUNDLE_IDENTIFIER = ' + re.escape(expected_identifier) + ';', settings, re.M):
            raise SigningError(f"Unexpected bundle identifier setting for {target}.")
        if not re.search(r'^\s*CODE_SIGN_ENTITLEMENTS = Configuration/Shared\.entitlements;', settings, re.M):
            raise SigningError(f"Unexpected entitlement configuration for {target}; refusing to replace it.")
        replacements = {
            "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": team,
            "CODE_SIGN_IDENTITY": identity,
            "PROVISIONING_PROFILE_SPECIFIER": profiles[bundle_id]["uuid"],
        }
        for key in (*replacements, "PROVISIONING_PROFILE"):
            settings = re.sub(r'^\s*"?' + key + r'(?:\[[^\n"]+\])?"?\s*=\s*[^;\n]*;\n', '', settings, flags=re.M)
        settings += ''.join(f'\t\t\t\t{key} = {json.dumps(value)};\n' for key, value in replacements.items())
        body = body[:settings_match.start(2)] + settings + body[settings_match.end(2):]
        return match["header"] + body + match["footer"]

    updated = pattern.sub(patch, source)
    if seen != set(TARGET_SUFFIXES):
        raise SigningError("The signing patch must cover all eight Release targets.")
    return updated


def child_environment(extra=None):
    environment = {key: value for key, value in os.environ.items() if key not in SIGNING_ENV + UPLOAD_ENV}
    environment.pop("XCODE_XCCONFIG_FILE", None)
    environment.update(extra or {})
    return environment


def command(arguments, label, *, cwd=None, environment=None):
    # Never print commands or CalledProcessError: security arguments contain passwords.
    try:
        process = subprocess.Popen(arguments, cwd=cwd, env=environment or child_environment(),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError:
        raise SigningError(f"{label} could not start.") from None
    try:
        output, _ = process.communicate()
    except BaseException:
        # Stop Bash, xcodebuild, tee, and their descendants before signing cleanup.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            if sig == signal.SIGTERM:
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
        process.communicate()
        raise
    if process.returncode:
        raise SigningError(f"{label} failed (exit {process.returncode}). Command output is withheld to protect signing material.")
    return output


def upload_identifiers(environment):
    app_id = environment.get("DEVTOOLS_ASC_APP_ID", "6831456709")
    provider = environment.get("DEVTOOLS_ASC_PROVIDER_ID", "")
    if not re.fullmatch(r'[1-9][0-9]*', app_id):
        raise SigningError("DEVTOOLS_ASC_APP_ID must be the numeric App Store Connect app Apple ID.")
    if provider and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,127}', provider):
        raise SigningError("DEVTOOLS_ASC_PROVIDER_ID has an invalid format.")
    return app_id, provider


def upload_verified_ipa(ipa, api_key_data, environment, work, bundle_id, version, build):
    """Upload the inspected IPA without another signing/export operation."""
    # Apple documents API_PRIVATE_KEYS_DIR and the API-key auth pair in:
    # https://help.apple.com/asc/appsaltool/en.lproj/static.html
    app_id, provider = upload_identifiers(environment)
    key_directory = work / "private_keys"
    key_directory.mkdir(mode=0o700)
    key_path = key_directory / ("AuthKey_" + environment[UPLOAD_ENV[1]] + ".p8")
    key_path.write_bytes(api_key_data)
    key_path.chmod(0o600)
    arguments = ["xcrun", "altool", "--upload-package", str(ipa), "-t", "ios",
                 "--apple-id", app_id, "--bundle-id", bundle_id,
                 "--bundle-short-version-string", version, "--bundle-version", build,
                 "--apiKey", environment[UPLOAD_ENV[1]], "--apiIssuer", environment[UPLOAD_ENV[2]],
                 "--output-format", "json"]
    if provider:
        arguments.extend(["--asc-public-id", provider])
    command(arguments, "Authenticated App Store Connect upload", cwd=work,
            environment=child_environment({"API_PRIVATE_KEYS_DIR": str(key_directory)}))


def readiness(environment):
    print("Manual signing readiness (presence only; values are never printed):")
    for name in SIGNING_ENV + UPLOAD_ENV:
        print(f"  {name}: {'present' if environment.get(name) else 'missing'}")
    tools_ready = platform.system() == "Darwin" and all(shutil.which(tool) for tool in ("xcodebuild", "xcrun", "security", "git", "ditto"))
    print(f"  macOS/Xcode signing tools: {'available' if tools_ready else 'unavailable'}")
    if tools_ready:
        identities = command(["security", "find-identity", "-v", "-p", "codesigning"], "Identity readiness check").decode(errors="replace")
        count = re.search(r'(\d+) valid identities found', identities)
        print(f"  existing usable keychain identities: {count[1] if count else 'unknown'}")
    for mode in ("export", "upload"):
        missing = missing_inputs(mode, environment)
        status = "NOT READY" if missing or not tools_ready else "INPUTS PRESENT; validation still required"
        print(f"  {mode}: {status}")
    print("Required: one existing distribution private key, eight matching nonexpired App Store profiles with the App Group, and API authentication for upload.")
    print("No signing state or Apple account data was changed. Use GitHub secrets or local environment variables; never paste keys into chat or commit them.")


def source_snapshot(repo, destination):
    revision = command(["git", "rev-parse", "HEAD"], "Read committed revision", cwd=repo).decode().strip()
    archive = command(["git", "archive", "--format=tar", revision], "Read committed source", cwd=repo)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        for member in source:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not (member.isdir() or member.isfile()):
                raise SigningError("Committed source contains an unsupported archive path or link.")
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.extractfile(member).read())
    return revision


def project_values(checkout):
    config = (checkout / "Configuration/Project.xcconfig").read_text()
    values = {}
    for key in ("DT_BUNDLE_PREFIX", "DT_APP_GROUP", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        match = re.search(r'^' + key + r'\s*=\s*([A-Za-z0-9.-]+)\s*$', config, re.M)
        if not match:
            raise SigningError(f"Cannot read committed project setting {key}.")
        values[key] = match[1]
    return values


def distribute(mode, repo, environment):
    # Complete missing-input checks before any temp files or signing-state changes.
    missing = missing_inputs(mode, environment)
    if missing:
        raise SigningError("Missing required environment variables: " + ", ".join(missing))
    if platform.system() != "Darwin" or any(not shutil.which(tool) for tool in ("xcodebuild", "xcrun", "security", "git", "ditto")):
        raise SigningError("Export/upload requires macOS, Xcode, xcrun, security, git, and ditto.")
    if mode == "upload":
        upload_identifiers(environment)
        command(["xcrun", "--find", "altool"], "Find App Store upload tool")
    team = environment.get("DEVTOOLS_TEAM_ID", "GZ6B7VNBWJ")
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise SigningError("DEVTOOLS_TEAM_ID must be a ten-character Apple team ID.")
    output = repo / "Build/TestFlight"
    if output.exists() and any(output.iterdir()):
        raise SigningError("Build/TestFlight must be empty to avoid mixing this run with an earlier export.")
    certificate_data = decoded_secret(SIGNING_ENV[0], environment)
    payloads = profile_payloads(decoded_secret(SIGNING_ENV[2], environment))
    api_key_data = None
    if mode == "upload":
        api_key_data = decoded_secret(UPLOAD_ENV[0], environment)
        if not api_key_data.startswith(b"-----BEGIN PRIVATE KEY-----") or b"-----END PRIVATE KEY-----" not in api_key_data:
            raise SigningError("DEVTOOLS_ASC_KEY_BASE64 must contain the existing PEM .p8 private key.")
        if not re.fullmatch(r'[A-Za-z0-9]{10}', environment[UPLOAD_ENV[1]]):
            raise SigningError("DEVTOOLS_ASC_KEY_ID has an invalid format.")
        try:
            uuid.UUID(environment[UPLOAD_ENV[2]])
        except ValueError:
            raise SigningError("DEVTOOLS_ASC_ISSUER_ID must be a UUID.") from None

    installed = []
    created_directories = []
    keychain = None
    original_keychains = None
    with tempfile.TemporaryDirectory(prefix="devtools-signing-", dir=environment.get("RUNNER_TEMP") or None) as temporary:
        work = Path(temporary)
        try:
            checkout = work / "source"
            checkout.mkdir()
            revision = source_snapshot(repo, checkout)
            values = project_values(checkout)
            prefix, group = values["DT_BUNDLE_PREFIX"], values["DT_APP_GROUP"]
            decoded_profiles = []
            for index, payload in enumerate(payloads.values()):
                path = work / f"profile-{index}.mobileprovision"
                path.write_bytes(payload)
                decoded = command(["security", "cms", "-D", "-i", str(path)], "Decode provisioning profile")
                try:
                    decoded_profiles.append((plistlib.loads(decoded), payload))
                except (plistlib.InvalidFileException, ValueError):
                    raise SigningError("A provisioning profile did not decode to a valid plist.") from None

            certificate = work / "certificate.p12"
            certificate.write_bytes(certificate_data)
            original_keychains = shlex.split(command(["security", "list-keychains", "-d", "user"], "Read keychain search list").decode())
            keychain = work / "signing.keychain-db"
            keychain_password = secrets.token_urlsafe(32)
            command(["security", "create-keychain", "-p", keychain_password, str(keychain)], "Create temporary keychain")
            command(["security", "set-keychain-settings", "-lut", "21600", str(keychain)], "Configure temporary keychain")
            command(["security", "unlock-keychain", "-p", keychain_password, str(keychain)], "Unlock temporary keychain")
            command(["security", "import", str(certificate), "-P", environment[SIGNING_ENV[1]], "-t", "cert", "-f", "pkcs12", "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], "Import existing distribution identity")
            command(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-k", keychain_password, str(keychain)], "Grant codesign access to temporary identity")
            identities = command(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], "Check imported distribution identity").decode(errors="replace")
            fingerprints = set(re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "(?:Apple|iPhone) Distribution:', identities, re.M))
            profiles, identity = validate_profiles(decoded_profiles, team, prefix, group, {value.upper() for value in fingerprints})
            project = checkout / "DevTools.xcodeproj/project.pbxproj"
            project.write_text(patch_release_settings(project.read_text(), profiles, team, prefix, identity))

            # Support current and legacy Xcode locations without replacing existing files.
            profile_directories = [Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles", Path.home() / "Library/MobileDevice/Provisioning Profiles"]
            for directory in profile_directories:
                if not directory.exists():
                    directory.mkdir(parents=True)
                    created_directories.append(directory)
                for profile in profiles.values():
                    path = directory / (profile["uuid"] + ".mobileprovision")
                    if path.is_symlink():
                        raise SigningError("An installed profile path is a symbolic link; it was not modified.")
                    if path.exists():
                        if path.read_bytes() != profile["payload"]:
                            raise SigningError("An installed profile UUID conflicts with the supplied profile; no existing profile was overwritten.")
                    else:
                        with path.open("xb") as stream:
                            installed.append(path)
                            stream.write(profile["payload"])
            command(["security", "list-keychains", "-d", "user", "-s", str(keychain), *original_keychains], "Select temporary signing keychain")

            archive = work / "DevTools.xcarchive"
            archive_environment = child_environment({
                "DEVTOOLS_ARCHIVE_PATH": str(archive), "DEVTOOLS_ARCHIVE_LOG": str(work / "archive.log"),
                "DEVTOOLS_ARCHIVE_DERIVED_DATA": str(work / "DerivedData"),
                "DEVTOOLS_PACKAGE_CACHE": str(work / "SourcePackages"),
            })
            print("Creating a normally signed archive from committed source; no automatic provisioning.", flush=True)
            command(["bash", "Scripts/archive-ios.sh", "--signed"], "Signed archive", cwd=checkout, environment=archive_environment)
            options = {
                "method": "app-store-connect", "destination": "export", "signingStyle": "manual",
                "teamID": team, "signingCertificate": identity, "manageAppVersionAndBuildNumber": False,
                "provisioningProfiles": {bundle: profile["uuid"] for bundle, profile in profiles.items()},
            }
            options_path = work / "ExportOptions.plist"
            options_path.write_bytes(plistlib.dumps(options))
            export = work / "export"
            command(["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportOptionsPlist", str(options_path), "-exportPath", str(export)], "App Store IPA export")
            ipas = list(export.glob("*.ipa"))
            if len(ipas) != 1:
                raise SigningError("Xcode export did not produce exactly one IPA.")
            unpacked = work / "unpacked"
            command(["ditto", "-x", "-k", str(ipas[0]), str(unpacked)], "Unpack exported IPA")
            command(["python3", "Scripts/verify-signing.py", str(unpacked / "Payload/DevTools.app"),
                     "--team-id", team, "--bundle-prefix", prefix, "--app-group", group,
                     "--version", values["MARKETING_VERSION"], "--build", values["CURRENT_PROJECT_VERSION"]],
                    "Verify all exported signatures and App Group entitlements", cwd=checkout)
            output.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ipas[0], output / "DevTools.ipa")
            summary = {"commit": revision, "version": values["MARKETING_VERSION"],
                       "build": values["CURRENT_PROJECT_VERSION"], "bundles_verified": 8,
                       "ipa_sha256": hashlib.sha256(ipas[0].read_bytes()).hexdigest(),
                       "export": "verified", "upload": "not attempted", "apple_processing": "not verified"}
            summary_path = output / "validation-summary.json"
            summary_path.write_text(json.dumps(summary, indent=2) + "\n")
            print("Export verified: app and seven extensions, matching App Group and distribution signatures.", flush=True)
            if mode == "upload":
                summary["upload"] = "attempted; completion not confirmed"
                summary_path.write_text(json.dumps(summary, indent=2) + "\n")
                upload_verified_ipa(ipas[0], api_key_data, environment, work, prefix,
                                    values["MARKETING_VERSION"], values["CURRENT_PROJECT_VERSION"])
                summary["upload"] = "altool completed; processing/review still unverified"
                summary_path.write_text(json.dumps(summary, indent=2) + "\n")
                print("Upload command completed. Confirm processing and TestFlight review status in App Store Connect.")
            else:
                print("No upload attempted.")
            print("Outputs: Build/TestFlight/DevTools.ipa and validation-summary.json")
        finally:
            cleanup_failed = False
            if original_keychains is not None:
                try:
                    command(["security", "list-keychains", "-d", "user", "-s", *original_keychains], "Restore keychain search list")
                except SigningError:
                    cleanup_failed = True
            if keychain is not None and keychain.exists():
                try:
                    command(["security", "delete-keychain", str(keychain)], "Remove temporary keychain")
                except SigningError:
                    cleanup_failed = True
            for path in installed:
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    cleanup_failed = True
            for directory in reversed(created_directories):
                try:
                    directory.rmdir()
                except OSError:
                    pass  # Preserve directories that another process populated.
            if cleanup_failed:
                raise SigningError("Signing cleanup was incomplete; inspect the runner keychain/profile state before another signing job.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("readiness", "export", "upload"), default="readiness")
    args = parser.parse_args()
    if args.mode == "readiness":
        try:
            readiness(os.environ)
        except SigningError:
            print("Readiness could not inspect existing signing state; NOT READY. No signing changes were made.")
        return 0
    def interrupted(signum, frame):
        raise SigningError("Signing was interrupted; temporary signing state is being cleaned up.")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        distribute(args.mode, Path(__file__).resolve().parents[1], os.environ)
    except SigningError as error:
        print(f"Signing stopped: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        print("Signing stopped: invalid input or a local operation failed. Details are withheld to protect signing material.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
