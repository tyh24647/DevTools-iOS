#!/usr/bin/env python3
"""Verify an exported DevTools iOS app before TestFlight upload.

This checks the actual macOS codesign result, signed entitlements, and embedded
App Store provisioning profiles. Pure validation helpers are also importable by
the Linux tests; passing those tests does not verify a real code signature.

Apple documents the inspection commands and profile fields in TN3125 and TN3161:
https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates
"""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError


EXTENSION_SUFFIXES = ('Safari', 'Show', 'Hide', 'Enable', 'Disable', 'AddBlacklist', 'AddAllowList')
APP_GROUPS_KEY = 'com.apple.security.application-groups'
TEAM_KEY = 'com.apple.developer.team-identifier'


class VerificationError(Exception):
    """A release bundle failed a signing or distribution consistency check."""


@dataclass(frozen=True)
class ReleaseExpectations:
    team_id: str
    bundle_prefix: str
    app_group: str
    version: str
    build: str

    @property
    def bundle_ids(self):
        return (self.bundle_prefix,) + tuple(
            f'{self.bundle_prefix}.{suffix}' for suffix in EXTENSION_SUFFIXES
        )


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def parse_plist(data, label):
    try:
        result = plistlib.loads(data)
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError, ExpatError) as error:
        raise VerificationError(f'{label}: invalid property list.') from error
    require(isinstance(result, dict), f'{label}: property list must be a dictionary.')
    return result


def read_plist(path, label):
    try:
        data = path.read_bytes()
    except OSError as error:
        raise VerificationError(f'{label}: property list is missing or unreadable.') from error
    return parse_plist(data, label)


def validate_bundle_info(info, bundle_id, release):
    require(isinstance(info, dict), f'{bundle_id}: Info.plist must be a dictionary.')
    expected = {
        'CFBundleIdentifier': bundle_id,
        'CFBundleShortVersionString': release.version,
        'CFBundleVersion': release.build,
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'DevToolsAppGroup': release.app_group,
    }
    for key, value in expected.items():
        require(info.get(key) == value, f'{bundle_id}: Info.plist {key} does not match the release.')
    if 'DTPlatformName' in info:
        require(info['DTPlatformName'] == 'iphoneos', f'{bundle_id}: DTPlatformName is not iphoneos.')


def collect_bundles(app_path, release):
    """Read exactly the containing app and its seven direct PlugIns extensions."""
    require(app_path.is_dir() and app_path.suffix == '.app', 'APP_PATH must be an existing .app directory.')
    require(not list(app_path.rglob('*.app')), 'Unexpected nested app bundle in the exported app.')
    extensions = sorted(app_path.rglob('*.appex'))
    require(len(extensions) == len(EXTENSION_SUFFIXES), 'Expected exactly seven embedded extensions.')
    for extension in extensions:
        require(
            extension.is_dir() and not extension.is_symlink() and extension.parent == app_path / 'PlugIns',
            'Every extension must be a real bundle directly inside the app PlugIns directory.',
        )

    bundles = {}
    for path in [app_path, *extensions]:
        info = read_plist(path / 'Info.plist', path.name)
        bundle_id = info.get('CFBundleIdentifier')
        require(isinstance(bundle_id, str) and bundle_id in release.bundle_ids, f'{path.name}: unexpected bundle identifier.')
        require(bundle_id not in bundles, f'{bundle_id}: duplicate bundle identifier.')
        require((path == app_path) == (bundle_id == release.bundle_prefix), 'Containing app and extension identifiers are misplaced.')
        validate_bundle_info(info, bundle_id, release)
        bundles[bundle_id] = path
    require(set(bundles) == set(release.bundle_ids), 'Exported app is missing an expected bundle identifier.')
    return [(bundle_id, bundles[bundle_id]) for bundle_id in release.bundle_ids]


def validate_entitlements(entitlements, bundle_id, release, *, application_identifier, profile=False):
    label = f'{bundle_id}: {"profile" if profile else "signature"}'
    require(isinstance(entitlements, dict), f'{label} entitlements are missing or malformed.')
    require(entitlements.get(TEAM_KEY) == release.team_id, f'{label} has the wrong team entitlement.')
    require(
        entitlements.get('application-identifier') == application_identifier,
        f'{label} has the wrong application-identifier entitlement.',
    )
    groups = entitlements.get(APP_GROUPS_KEY)
    require(
        isinstance(groups, list) and all(isinstance(group, str) for group in groups),
        f'{label} App Group entitlement is missing or malformed.',
    )
    if profile:
        # A profile is an allowlist and may authorize groups the app does not use.
        require(release.app_group in groups, f'{label} does not authorize the shared App Group.')
    else:
        require(groups == [release.app_group], f'{label} does not claim exactly the shared App Group.')
    require(
        'get-task-allow' not in entitlements or entitlements['get-task-allow'] is False,
        f'{label} get-task-allow must be absent or false for distribution.',
    )


def validate_signature_details(details, bundle_id, release):
    """Check codesign display metadata, after codesign --verify has succeeded."""
    fields = {}
    authorities = []
    for line in details.splitlines():
        key, separator, value = line.partition('=')
        if separator:
            if key == 'Authority':
                authorities.append(value)
            else:
                fields[key] = value
    require(
        fields.get('Signature', '').lower() not in ('adhoc', 'ad-hoc') and '(adhoc)' not in details.lower(),
        f'{bundle_id}: ad-hoc signatures are not valid for TestFlight.',
    )
    require(fields.get('Identifier') == bundle_id, f'{bundle_id}: code signature identifier does not match.')
    require(fields.get('TeamIdentifier') == release.team_id, f'{bundle_id}: code signature team does not match.')
    require(
        authorities and authorities[0].startswith(('Apple Distribution:', 'iPhone Distribution:')),
        f'{bundle_id}: code signature does not use an Apple distribution certificate.',
    )


def validate_profile(profile, bundle_id, release, signing_certificate, *, now=None):
    label = f'{bundle_id}: embedded profile'
    require(isinstance(profile, dict), f'{label} is malformed.')
    require(profile.get('TeamIdentifier') == [release.team_id], f'{label} has the wrong team.')
    profile_entitlements = profile.get('Entitlements')
    require(isinstance(profile_entitlements, dict), f'{label} entitlements are missing or malformed.')
    application_identifier = profile_entitlements.get('application-identifier')
    require(isinstance(application_identifier, str), f'{label} application-identifier is missing or malformed.')
    app_id_prefix, separator, profile_bundle_id = application_identifier.partition('.')
    authorized_prefixes = profile.get('ApplicationIdentifierPrefix')
    # Older accounts can have an App ID prefix distinct from their Team ID.
    # The profile must authorize that prefix, while the bundle suffix is exact.
    require(
        bool(app_id_prefix) and separator and profile_bundle_id == bundle_id
        and isinstance(authorized_prefixes, list) and app_id_prefix in authorized_prefixes
        and all(isinstance(prefix, str) and prefix for prefix in authorized_prefixes),
        f'{label} has an unauthorized App ID prefix or incorrect application-identifier.',
    )
    require('ProvisionedDevices' not in profile, f'{label} is a device-based development or Ad Hoc profile.')
    require(
        'ProvisionsAllDevices' not in profile or profile['ProvisionsAllDevices'] is False,
        f'{label} is not an App Store distribution profile.',
    )
    platforms = profile.get('Platform')
    require(isinstance(platforms, list) and 'iOS' in platforms, f'{label} does not authorize iOS.')

    expiration = profile.get('ExpirationDate')
    require(isinstance(expiration, datetime), f'{label} has no valid expiration date.')
    # plistlib reads Apple's UTC plist dates as naive datetime values by default.
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    current_time = now if now is not None else datetime.now(timezone.utc)
    if current_time.tzinfo is None:
        current_time = current_time.replace(tzinfo=timezone.utc)
    require(expiration > current_time, f'{label} has expired.')

    validate_entitlements(profile_entitlements, bundle_id, release, application_identifier=application_identifier, profile=True)
    certificates = profile.get('DeveloperCertificates')
    require(
        isinstance(certificates, list) and certificates and all(isinstance(value, bytes) and value for value in certificates),
        f'{label} has no valid signing certificate allowlist.',
    )
    require(
        isinstance(signing_certificate, bytes) and signing_certificate and signing_certificate in certificates,
        f'{label} does not authorize the actual signing certificate.',
    )
    return application_identifier


def run_tool(command, label, *, cwd=None):
    try:
        result = subprocess.run(command, capture_output=True, check=False, timeout=60, cwd=cwd)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VerificationError(f'{label}: signing inspection command could not complete.') from error
    # Do not echo command output: it can contain the complete provisioning profile
    # or entitlement data. The label identifies which bundle and operation failed.
    require(result.returncode == 0, f'{label}: signing inspection command failed (exit {result.returncode}).')
    return result


def verify_exported_app(app_path, release):
    require(sys.platform == 'darwin', 'Actual exported-app signing verification requires macOS.')
    codesign = shutil.which('codesign')
    security = shutil.which('security')
    require(codesign and security, 'Apple codesign and security command-line tools are required.')
    app_path = app_path.resolve()
    bundles = collect_bundles(app_path, release)
    run_tool([codesign, '--verify', '--deep', '--strict', str(app_path)], 'Containing app and nested code verification')

    for bundle_id, path in bundles:
        if path != app_path:
            run_tool([codesign, '--verify', '--strict', str(path)], f'{bundle_id}: signature verification')
        details = run_tool([codesign, '--display', '--verbose=4', str(path)], f'{bundle_id}: signature metadata')
        validate_signature_details((details.stdout + details.stderr).decode('utf-8', errors='replace'), bundle_id, release)
        # --xml is necessary: current codesign can otherwise print a human-readable
        # representation of DER entitlements rather than a property list.
        entitlements = run_tool(
            [codesign, '--display', '--entitlements', '-', '--xml', str(path)],
            f'{bundle_id}: signed entitlements',
        )
        signed_entitlements = parse_plist(entitlements.stdout, f'{bundle_id}: signed entitlements')

        profile_path = path / 'embedded.mobileprovision'
        require(profile_path.is_file() and not profile_path.is_symlink(), f'{bundle_id}: embedded provisioning profile is missing.')
        decoded = run_tool([security, 'cms', '-D', '-i', str(profile_path)], f'{bundle_id}: provisioning profile decoding')
        profile = parse_plist(decoded.stdout, f'{bundle_id}: embedded profile')
        # Extract only public certificates to an isolated directory, never a key.
        # codesign0 is the actual leaf signer; compare its DER bytes with the
        # profile's DeveloperCertificates rather than trusting certificate names.
        with tempfile.TemporaryDirectory(prefix='devtools-signature-certificates-') as temporary:
            run_tool(
                [codesign, '--display', '--extract-certificates', str(path)],
                f'{bundle_id}: public signing certificate extraction',
                cwd=temporary,
            )
            try:
                certificate = (Path(temporary) / 'codesign0').read_bytes()
            except OSError as error:
                raise VerificationError(f'{bundle_id}: the signature has no extractable signing certificate.') from error
        application_identifier = validate_profile(profile, bundle_id, release, certificate)
        validate_entitlements(signed_entitlements, bundle_id, release, application_identifier=application_identifier)
        print(f'Verified signature, entitlements, and App Store profile: {bundle_id}', flush=True)
    print(f'Exported app verification passed for {len(bundles)} bundles ({release.version}, build {release.build}).')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app_path', type=Path, help='Exported Payload/DevTools.app directory.')
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--bundle-prefix', required=True)
    parser.add_argument('--app-group', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    arguments = parser.parse_args(argv)
    release = ReleaseExpectations(arguments.team_id, arguments.bundle_prefix, arguments.app_group, arguments.version, arguments.build)
    try:
        verify_exported_app(arguments.app_path, release)
    except VerificationError as error:
        print(f'Signing verification failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
