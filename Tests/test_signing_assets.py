"""No Apple credentials or macOS tools are used by these signing-boundary tests."""

import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import re
import signal
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("signing_assets", ROOT / "Scripts/signing-assets.py")
assets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(assets)
TEAM = "ABCDEFGHIJ"
PREFIX = "com.example.DevTools"
GROUP = "group.com.example.DevTools"
NOW = datetime(2026, 1, 1, tzinfo=timezone.utc)
CERTIFICATE = b"fixture distribution certificate; not a real credential"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()


def profiles():
    result = []
    for index, suffix in enumerate(assets.TARGET_SUFFIXES.values()):
        profile = {
            "UUID": str(uuid.UUID(int=index + 1)), "TeamIdentifier": [TEAM],
            "ApplicationIdentifierPrefix": ["OLDPREFIX1"], "Platform": ["iOS"],
            "ExpirationDate": (NOW + timedelta(days=30)).replace(tzinfo=None),
            "DeveloperCertificates": [CERTIFICATE],
            "Entitlements": {
                "application-identifier": "OLDPREFIX1." + PREFIX + suffix,
                "com.apple.developer.team-identifier": TEAM, "get-task-allow": False,
                "com.apple.security.application-groups": [GROUP],
            },
        }
        result.append((profile, plistlib.dumps(profile)))
    return result


def profile_tar(extra=None, replace=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for index in range(7 if replace else 8):
            data = f"fixture-{index}".encode()
            member = tarfile.TarInfo(f"./profile-{index}.mobileprovision")
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        if extra is not None:
            archive.addfile(extra, io.BytesIO(b"x" * extra.size) if extra.isfile() else None)
    return output.getvalue()


class ProfileTests(unittest.TestCase):
    def validate(self, items=None, identities=None):
        return assets.validate_profiles(items if items is not None else profiles(), TEAM, PREFIX, GROUP,
                                        identities if identities is not None else {FINGERPRINT}, NOW)

    def test_valid_eight_profiles_allow_historical_app_id_prefix(self):
        mapping, identity = self.validate()
        self.assertEqual(identity, FINGERPRINT)
        self.assertEqual(set(mapping), {PREFIX + suffix for suffix in assets.TARGET_SUFFIXES.values()})
        self.assertEqual(len({entry["uuid"] for entry in mapping.values()}), 8)

    def test_missing_and_duplicate_bundle_profiles_are_rejected(self):
        with self.assertRaises(assets.SigningError):
            self.validate(profiles()[:-1])
        duplicate = profiles()
        duplicate[-1] = copy.deepcopy(duplicate[0])
        with self.assertRaises(assets.SigningError):
            self.validate(duplicate)

    def test_invalid_profile_requirements_are_rejected(self):
        cases = (
            lambda p: p.update(ExpirationDate=NOW.replace(tzinfo=None)),
            lambda p: p.update(TeamIdentifier=["WRONGTEAM1"]),
            lambda p: p.update(ProvisionedDevices=["device"]),
            lambda p: p.update(ProvisionsAllDevices=True),
            lambda p: p.update(ProvisionsAllDevices=None),
            lambda p: p.update(ProvisionsAllDevices="false"),
            lambda p: p.update(ApplicationIdentifierPrefix=[TEAM]),
            lambda p: p.update(Platform=["OSX"]),
            lambda p: p.update(UUID="../unsafe"),
            lambda p: p.update(DeveloperCertificates=[b"different certificate"]),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
            lambda p: p["Entitlements"].update({"application-identifier": "OLDPREFIX1.com.example.*"}),
            lambda p: p["Entitlements"].update({"com.apple.security.application-groups": []}),
            lambda p: p["Entitlements"].update({"com.apple.security.application-groups": GROUP}),
        )
        for mutate in cases:
            with self.subTest(case=cases.index(mutate)):
                items = profiles()
                mutate(items[3][0])
                with self.assertRaises(assets.SigningError):
                    self.validate(items)

    def test_explicit_false_enterprise_flag_is_allowed(self):
        items = profiles()
        items[0][0]["ProvisionsAllDevices"] = False
        self.validate(items)

    def test_no_matching_private_identity_or_duplicate_uuid_is_rejected(self):
        with self.assertRaises(assets.SigningError):
            self.validate(identities=set())
        items = profiles()
        items[-1][0]["UUID"] = items[0][0]["UUID"]
        with self.assertRaises(assets.SigningError):
            self.validate(items)

    def test_tar_accepts_only_eight_flat_regular_profiles(self):
        self.assertEqual(len(assets.profile_payloads(profile_tar())), 8)
        for name, member_type in (("../outside.mobileprovision", tarfile.REGTYPE),
                                  ("/absolute.mobileprovision", tarfile.REGTYPE),
                                  ("nested/profile.mobileprovision", tarfile.REGTYPE),
                                  ("link.mobileprovision", tarfile.SYMTYPE),
                                  ("hardlink.mobileprovision", tarfile.LNKTYPE),
                                  ("profile-0.mobileprovision", tarfile.REGTYPE),
                                  ("extra.mobileprovision", tarfile.REGTYPE)):
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = member_type
                member.size = 1 if member.isfile() else 0
                member.linkname = "/outside"
                with self.assertRaises(assets.SigningError):
                    assets.profile_payloads(profile_tar(member, replace=name != "extra.mobileprovision"))

    def test_compressed_profile_archive_has_bounded_expansion(self):
        data = assets.gzip.compress(b"\0" * (assets.MAX_ASSET_BYTES + 64 * 1024 + 1))
        with self.assertRaises(assets.SigningError):
            assets.profile_payloads(data)

    def test_invalid_base64_and_compression_are_rejected_without_values(self):
        secret = "example invalid secret !"
        with self.assertRaises(assets.SigningError) as error:
            assets.decoded_secret("TEST", {"TEST": secret})
        self.assertNotIn(secret, str(error.exception))
        with self.assertRaises(assets.SigningError):
            assets.profile_payloads(b"not gzip")


class ProjectAndBoundaryTests(unittest.TestCase):
    def test_patch_assigns_eight_distinct_profiles_and_preserves_entitlements(self):
        source = (ROOT / "DevTools.xcodeproj/project.pbxproj").read_text()
        mapping, identity = assets.validate_profiles(profiles(), TEAM, PREFIX, GROUP, {FINGERPRINT}, NOW)
        updated = assets.patch_release_settings(source, mapping, TEAM, PREFIX, identity)
        self.assertEqual(updated.count('CODE_SIGN_STYLE = "Manual";'), 8)
        self.assertEqual(updated.count('CODE_SIGN_IDENTITY = "' + identity + '";'), 8)
        for item in mapping.values():
            self.assertEqual(updated.count('PROVISIONING_PROFILE_SPECIFIER = "' + item["uuid"] + '";'), 1)
        for target, suffix in assets.TARGET_SUFFIXES.items():
            block = re.search(r'Release configuration for PBXNativeTarget "' + target + r'".*?^\t\t\};', updated, re.M | re.S)[0]
            self.assertIn('PROVISIONING_PROFILE_SPECIFIER = "' + mapping[PREFIX + suffix]["uuid"] + '";', block)
        entitlement_lines = lambda text: re.findall(r'^.*CODE_SIGN_ENTITLEMENTS.*$', text, re.M)
        self.assertEqual(entitlement_lines(source), entitlement_lines(updated))
        debug_blocks = lambda text: re.findall(r'^\t\t[^\n]+ /\* Debug configuration.*?^\t\t\};', text, re.M | re.S)
        self.assertEqual(debug_blocks(source), debug_blocks(updated))
        self.assertEqual(re.findall(r'^.*SKIP_INSTALL.*$', source, re.M), re.findall(r'^.*SKIP_INSTALL.*$', updated, re.M))

    def test_unexpected_target_or_entitlements_stop_project_patch(self):
        source = (ROOT / "DevTools.xcodeproj/project.pbxproj").read_text()
        mapping, identity = assets.validate_profiles(profiles(), TEAM, PREFIX, GROUP, {FINGERPRINT}, NOW)
        for changed in (source.replace('Release configuration for PBXNativeTarget "DevTools"',
                                       'Release configuration for PBXNativeTarget "Unknown"', 1),
                        source.replace('CODE_SIGN_ENTITLEMENTS = Configuration/Shared.entitlements;',
                                       'CODE_SIGN_ENTITLEMENTS = Different.entitlements;', 1)):
            with self.assertRaises(assets.SigningError):
                assets.patch_release_settings(changed, mapping, TEAM, PREFIX, identity)

    def test_missing_assets_fail_before_subprocess_or_temporary_directory(self):
        with patch.object(assets, "command") as run, patch.object(assets.tempfile, "TemporaryDirectory") as temporary:
            with self.assertRaises(assets.SigningError):
                assets.distribute("export", ROOT, {})
            with self.assertRaises(assets.SigningError):
                assets.distribute("upload", ROOT, {name: "present" for name in assets.SIGNING_ENV})
            run.assert_not_called()
            temporary.assert_not_called()

    def test_upload_authentication_is_not_required_for_export(self):
        environment = {name: "present" for name in assets.SIGNING_ENV}
        self.assertEqual(assets.missing_inputs("export", environment), [])
        self.assertEqual(assets.missing_inputs("upload", environment), list(assets.UPLOAD_ENV))

    def test_command_failure_does_not_print_password_arguments_or_output(self):
        secret = "password-must-not-appear"
        with self.assertRaises(assets.SigningError) as error:
            assets.command([sys.executable, "-c", "import sys; print(sys.argv[1]); sys.exit(1)", secret], "Import identity")
        self.assertNotIn(secret, str(error.exception))

    def test_upload_uses_exact_verified_ipa_and_temporary_key_directory(self):
        environment = {name: "fake-secret" for name in assets.SIGNING_ENV + assets.UPLOAD_ENV}
        environment[assets.UPLOAD_ENV[1]] = "KEYID12345"
        environment[assets.UPLOAD_ENV[2]] = str(uuid.UUID(int=42))
        private_key = b"fake private key used only in this test"
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            ipa = work / "already-verified.ipa"
            with patch.dict(os.environ, environment), patch.object(assets, "command") as run:
                assets.upload_verified_ipa(ipa, private_key, environment, work, PREFIX, "1.0.0", "2")
            arguments = run.call_args.args[0]
            self.assertEqual(arguments[:4], ["xcrun", "altool", "--upload-package", str(ipa)])
            self.assertEqual(arguments[arguments.index("--apple-id") + 1], "6831456709")
            self.assertEqual(arguments[arguments.index("--bundle-id") + 1], PREFIX)
            self.assertEqual(arguments[arguments.index("--bundle-short-version-string") + 1], "1.0.0")
            self.assertEqual(arguments[arguments.index("--bundle-version") + 1], "2")
            self.assertEqual(arguments[arguments.index("--apiKey") + 1], environment[assets.UPLOAD_ENV[1]])
            self.assertEqual(arguments[arguments.index("--apiIssuer") + 1], environment[assets.UPLOAD_ENV[2]])
            self.assertNotIn("-allowProvisioningUpdates", arguments)
            upload_environment = run.call_args.kwargs["environment"]
            self.assertEqual(upload_environment["API_PRIVATE_KEYS_DIR"], str(work / "private_keys"))
            self.assertTrue(all(name not in upload_environment for name in assets.SIGNING_ENV + assets.UPLOAD_ENV))
            key_path = work / "private_keys/AuthKey_KEYID12345.p8"
            self.assertEqual(key_path.read_bytes(), private_key)
            self.assertEqual(key_path.stat().st_mode & 0o777, 0o600)

    def test_upload_public_identifiers_validate_overrides(self):
        self.assertEqual(assets.upload_identifiers({"DEVTOOLS_ASC_APP_ID": "123", "DEVTOOLS_ASC_PROVIDER_ID": "provider-456"}), ("123", "provider-456"))
        for invalid in ({"DEVTOOLS_ASC_APP_ID": "0"}, {"DEVTOOLS_ASC_APP_ID": "app-name"},
                        {"DEVTOOLS_ASC_PROVIDER_ID": "--invalid"}):
            with self.assertRaises(assets.SigningError):
                assets.upload_identifiers(invalid)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux cancellation regression")
    def test_interruption_terminates_child_and_grandchild_before_return(self):
        def interrupt(signum, frame):
            raise assets.SigningError("test interruption")

        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "grandchild.pid"
            code = (
                "import subprocess, sys, time; from pathlib import Path; "
                "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)']); "
                "Path(sys.argv[1]).write_text(str(child.pid)); time.sleep(10)"
            )
            previous = signal.signal(signal.SIGALRM, interrupt)
            try:
                signal.setitimer(signal.ITIMER_REAL, 0.3)
                with self.assertRaises(assets.SigningError):
                    assets.command([sys.executable, "-c", code, str(pid_file)], "Harmless cancellation fixture")
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
            self.assertTrue(pid_file.exists(), "Grandchild must start before cancellation")
            pid = int(pid_file.read_text())
            status = Path(f"/proc/{pid}/stat")
            if status.exists():
                # A terminated orphan can briefly await reaping by the host init.
                self.assertIn(status.read_text().split()[2], {"Z", "X"})


if __name__ == "__main__":
    unittest.main()
