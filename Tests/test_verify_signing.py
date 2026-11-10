#!/usr/bin/env python3
"""Consistency tests only; actual exported-app codesign checks require macOS."""
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'Scripts/verify-signing.py'
SPEC = importlib.util.spec_from_file_location('verify_signing', SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = signing
SPEC.loader.exec_module(signing)

RELEASE = signing.ReleaseExpectations('GZ6B7VNBWJ', 'com.tyh24647.DevTools', 'group.com.tyh24647.DevTools', '1.0.0', '2')
NOW = datetime(2026, 11, 10, tzinfo=timezone.utc)
# Deliberately synthetic bytes for allowlist comparison, not an X.509 fixture.
CERTIFICATE = b'synthetic-leaf-certificate-for-consistency-tests'


def entitlements(bundle_id=None):
    return {
        signing.TEAM_KEY: RELEASE.team_id,
        'application-identifier': f'{RELEASE.team_id}.{bundle_id or RELEASE.bundle_prefix}',
        signing.APP_GROUPS_KEY: [RELEASE.app_group],
        'get-task-allow': False,
    }


def profile(bundle_id=None):
    return {
        'TeamIdentifier': [RELEASE.team_id],
        'ApplicationIdentifierPrefix': [RELEASE.team_id],
        'Platform': ['iOS'],
        'ExpirationDate': NOW + timedelta(days=30),
        'Entitlements': entitlements(bundle_id),
        'DeveloperCertificates': [CERTIFICATE],
    }


def bundle_info(bundle_id):
    return {
        'CFBundleIdentifier': bundle_id,
        'CFBundleShortVersionString': RELEASE.version,
        'CFBundleVersion': RELEASE.build,
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'DTPlatformName': 'iphoneos',
        'DevToolsAppGroup': RELEASE.app_group,
    }


class EntitlementTests(unittest.TestCase):
    def check(self, value, *, profile=False):
        signing.validate_entitlements(value, RELEASE.bundle_prefix, RELEASE,
                                      application_identifier=f'{RELEASE.team_id}.{RELEASE.bundle_prefix}', profile=profile)

    def test_signature_claims_the_expected_entitlements(self):
        self.check(entitlements())

    def test_missing_signature_app_group_fails_even_if_profile_authorizes_it(self):
        value = entitlements()
        del value[signing.APP_GROUPS_KEY]
        self.check(entitlements(), profile=True)
        with self.assertRaisesRegex(signing.VerificationError, 'App Group'):
            self.check(value)

    def test_wrong_or_extra_signature_groups_fail(self):
        for groups in [[], ['group.wrong'], RELEASE.app_group, [RELEASE.app_group, 'group.extra'], [RELEASE.app_group, RELEASE.app_group]]:
            with self.subTest(groups=groups), self.assertRaisesRegex(signing.VerificationError, 'App Group'):
                value = entitlements()
                value[signing.APP_GROUPS_KEY] = groups
                self.check(value)

    def test_profile_may_authorize_additional_groups(self):
        value = entitlements()
        value[signing.APP_GROUPS_KEY].append('group.extra')
        self.check(value, profile=True)

    def test_missing_and_incorrect_identity_entitlements_fail(self):
        for key in [signing.TEAM_KEY, 'application-identifier']:
            for replacement in [None, 'WRONG', f'{RELEASE.team_id}.*']:
                with self.subTest(key=key, replacement=replacement), self.assertRaises(signing.VerificationError):
                    value = entitlements()
                    if replacement is None:
                        del value[key]
                    else:
                        value[key] = replacement
                    self.check(value)

    def test_get_task_allow_must_be_a_false_boolean_or_absent(self):
        value = entitlements()
        del value['get-task-allow']
        self.check(value)
        for invalid in [True, 'false', 0, 1, None]:
            with self.subTest(invalid=invalid), self.assertRaisesRegex(signing.VerificationError, 'get-task-allow'):
                value['get-task-allow'] = invalid
                self.check(value)


class ProfileTests(unittest.TestCase):
    def check(self, value, certificate=CERTIFICATE):
        signing.validate_profile(value, RELEASE.bundle_prefix, RELEASE, certificate, now=NOW)

    def test_valid_profile_metadata_and_leaf_allowlist(self):
        self.assertEqual(signing.validate_profile(profile(), RELEASE.bundle_prefix, RELEASE, CERTIFICATE, now=NOW),
                         f'{RELEASE.team_id}.{RELEASE.bundle_prefix}')

    def test_historical_app_id_prefix_is_validated_then_matched_to_signature(self):
        value = profile()
        historical_id = f'OLDPREFIX1.{RELEASE.bundle_prefix}'
        value['ApplicationIdentifierPrefix'] = ['OLDPREFIX1']
        value['Entitlements']['application-identifier'] = historical_id
        validated_id = signing.validate_profile(value, RELEASE.bundle_prefix, RELEASE, CERTIFICATE, now=NOW)
        self.assertEqual(validated_id, historical_id)
        signature = entitlements()
        signature['application-identifier'] = historical_id
        signing.validate_entitlements(signature, RELEASE.bundle_prefix, RELEASE, application_identifier=validated_id)
        signature['application-identifier'] = f'{RELEASE.team_id}.{RELEASE.bundle_prefix}'
        with self.assertRaisesRegex(signing.VerificationError, 'application-identifier'):
            signing.validate_entitlements(signature, RELEASE.bundle_prefix, RELEASE, application_identifier=validated_id)

    def test_historical_prefix_does_not_relax_the_exact_team_requirement(self):
        value = profile()
        value['ApplicationIdentifierPrefix'] = ['OLDPREFIX1']
        value['Entitlements']['application-identifier'] = f'OLDPREFIX1.{RELEASE.bundle_prefix}'
        value['Entitlements'][signing.TEAM_KEY] = 'OTHERTEAM'
        with self.assertRaisesRegex(signing.VerificationError, 'team entitlement'):
            self.check(value)

    def test_missing_profile_is_rejected(self):
        with self.assertRaisesRegex(signing.VerificationError, 'embedded profile'):
            self.check(None)

    def test_plist_naive_utc_expiration_is_supported(self):
        value = profile()
        value['ExpirationDate'] = (NOW + timedelta(days=1)).replace(tzinfo=None)
        decoded = signing.parse_plist(plistlib.dumps(value), 'test fixture')
        self.check(decoded)

    def test_expired_missing_or_malformed_expiration_fails(self):
        for expiration in [NOW, NOW - timedelta(seconds=1), (NOW - timedelta(days=1)).replace(tzinfo=None), None, '2027-01-01']:
            with self.subTest(expiration=expiration), self.assertRaisesRegex(signing.VerificationError, 'expir'):
                value = profile()
                value['ExpirationDate'] = expiration
                self.check(value)

    def test_device_or_enterprise_profiles_fail_even_with_empty_values(self):
        for key, value in [('ProvisionedDevices', ['device-id']), ('ProvisionedDevices', []), ('ProvisionsAllDevices', True), ('ProvisionsAllDevices', 'false'), ('ProvisionsAllDevices', 0), ('ProvisionsAllDevices', None)]:
            with self.subTest(key=key, value=value), self.assertRaises(signing.VerificationError):
                candidate = profile()
                candidate[key] = value
                self.check(candidate)

    def test_explicit_false_enterprise_flag_is_allowed(self):
        value = profile()
        value['ProvisionsAllDevices'] = False
        self.check(value)

    def test_profile_team_prefix_and_platform_must_match(self):
        for key, value in [('TeamIdentifier', ['OTHERTEAM']), ('TeamIdentifier', [RELEASE.team_id, 'OTHERTEAM']), ('ApplicationIdentifierPrefix', ['OLDPREFIX']), ('Platform', ['OSX']), ('Platform', 'iOS')]:
            with self.subTest(key=key), self.assertRaises(signing.VerificationError):
                candidate = profile()
                candidate[key] = value
                self.check(candidate)

    def test_profile_entitlements_must_authorize_exact_bundle_and_group(self):
        for key, value in [('application-identifier', f'{RELEASE.team_id}.{RELEASE.bundle_prefix}.*'), ('application-identifier', f'{RELEASE.team_id}.{RELEASE.bundle_prefix}.Safari'), (signing.TEAM_KEY, 'OTHERTEAM'), (signing.APP_GROUPS_KEY, []), ('get-task-allow', True)]:
            with self.subTest(key=key, value=value), self.assertRaises(signing.VerificationError):
                candidate = profile()
                candidate['Entitlements'][key] = value
                self.check(candidate)

    def test_missing_profile_entitlements_fail(self):
        value = profile()
        del value['Entitlements']
        with self.assertRaisesRegex(signing.VerificationError, 'entitlements'):
            self.check(value)

    def test_actual_signer_must_be_authorized_by_profile(self):
        with self.assertRaisesRegex(signing.VerificationError, 'actual signing certificate'):
            self.check(profile(), b'different-public-certificate')
        for certificates in [None, [], ['not-certificate-bytes'], [b'']]:
            with self.subTest(certificates=certificates), self.assertRaisesRegex(signing.VerificationError, 'certificate'):
                value = profile()
                value['DeveloperCertificates'] = certificates
                self.check(value)


class SignatureMetadataTests(unittest.TestCase):
    def setUp(self):
        self.details = '\n'.join([
            f'Identifier={RELEASE.bundle_prefix}',
            'Signature size=1234',
            f'Authority=Apple Distribution: Example ({RELEASE.team_id})',
            'Authority=Apple Worldwide Developer Relations Certification Authority',
            'Authority=Apple Root CA',
            f'TeamIdentifier={RELEASE.team_id}',
        ])

    def check(self, value):
        signing.validate_signature_details(value, RELEASE.bundle_prefix, RELEASE)

    def test_distribution_metadata_is_consistent(self):
        self.check(self.details)
        self.check(self.details.replace('Apple Distribution:', 'iPhone Distribution:'))

    def test_ad_hoc_metadata_fails(self):
        for extra in ['Signature=adhoc', 'CodeDirectory v=20400 flags=0x2(adhoc)']:
            with self.subTest(extra=extra), self.assertRaisesRegex(signing.VerificationError, 'ad-hoc'):
                self.check(self.details + '\n' + extra)

    def test_development_or_missing_authority_fails(self):
        for value in [self.details.replace('Apple Distribution:', 'Apple Development:'), '\n'.join(line for line in self.details.splitlines() if not line.startswith('Authority='))]:
            with self.subTest(value=value), self.assertRaisesRegex(signing.VerificationError, 'distribution certificate'):
                self.check(value)

    def test_signature_team_and_identifier_must_match(self):
        for old, new in [(f'TeamIdentifier={RELEASE.team_id}', 'TeamIdentifier=OTHERTEAM'), (f'Identifier={RELEASE.bundle_prefix}', 'Identifier=com.wrong.app')]:
            with self.subTest(old=old), self.assertRaises(signing.VerificationError):
                self.check(self.details.replace(old, new))


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='devtools-bundle-consistency-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / 'DevTools.app'
        self.app.mkdir()
        self.paths = {RELEASE.bundle_prefix: self.app}
        for suffix in signing.EXTENSION_SUFFIXES:
            path = self.app / 'PlugIns' / f'{suffix}.appex'
            path.mkdir(parents=True)
            self.paths[f'{RELEASE.bundle_prefix}.{suffix}'] = path
        for bundle_id, path in self.paths.items():
            self.write_info(path, bundle_info(bundle_id))

    def write_info(self, path, value):
        (path / 'Info.plist').write_bytes(plistlib.dumps(value))

    def check(self):
        return signing.collect_bundles(self.app, RELEASE)

    def test_exact_bundle_membership(self):
        bundles = self.check()
        self.assertEqual(tuple(bundle_id for bundle_id, _ in bundles), RELEASE.bundle_ids)

    def test_missing_or_additional_extension_fails(self):
        safari = self.paths[f'{RELEASE.bundle_prefix}.Safari']
        renamed = safari.with_suffix('.saved')
        safari.rename(renamed)
        with self.assertRaisesRegex(signing.VerificationError, 'exactly seven'):
            self.check()
        renamed.rename(safari)
        (self.app / 'PlugIns/Extra.appex').mkdir()
        with self.assertRaisesRegex(signing.VerificationError, 'exactly seven'):
            self.check()

    def test_duplicate_or_unknown_extension_identifier_fails(self):
        path = self.paths[f'{RELEASE.bundle_prefix}.Safari']
        for bundle_id, message in [(f'{RELEASE.bundle_prefix}.Show', 'duplicate'), (f'{RELEASE.bundle_prefix}.Unknown', 'unexpected')]:
            with self.subTest(bundle_id=bundle_id), self.assertRaisesRegex(signing.VerificationError, message):
                self.write_info(path, bundle_info(bundle_id))
                self.check()

    def test_extension_cannot_be_nested_outside_plugins(self):
        path = self.paths[f'{RELEASE.bundle_prefix}.Safari']
        path.rename(self.app / path.name)
        with self.assertRaisesRegex(signing.VerificationError, 'directly inside'):
            self.check()

    def test_unexpected_nested_app_fails(self):
        (self.app / 'Other.app').mkdir()
        with self.assertRaisesRegex(signing.VerificationError, 'nested app'):
            self.check()

    def test_root_and_extension_ids_cannot_be_swapped(self):
        extension_id = f'{RELEASE.bundle_prefix}.Safari'
        self.write_info(self.app, bundle_info(extension_id))
        self.write_info(self.paths[extension_id], bundle_info(RELEASE.bundle_prefix))
        with self.assertRaisesRegex(signing.VerificationError, 'misplaced'):
            self.check()

    def test_version_build_platform_and_runtime_group_match_for_every_bundle(self):
        changes = {
            'CFBundleShortVersionString': '1.0.1',
            'CFBundleVersion': '1',
            'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
            'DTPlatformName': 'iphonesimulator',
            'DevToolsAppGroup': 'group.wrong',
        }
        for bundle_id, path in self.paths.items():
            for key, replacement in changes.items():
                with self.subTest(bundle_id=bundle_id, key=key), self.assertRaisesRegex(signing.VerificationError, key):
                    value = bundle_info(bundle_id)
                    value[key] = replacement
                    self.write_info(path, value)
                    self.check()
                self.write_info(path, bundle_info(bundle_id))

    def test_missing_or_invalid_info_plist_fails(self):
        path = self.paths[f'{RELEASE.bundle_prefix}.Safari'] / 'Info.plist'
        path.unlink()
        with self.assertRaisesRegex(signing.VerificationError, 'missing or unreadable'):
            self.check()
        path.write_bytes(b'not-a-property-list')
        with self.assertRaisesRegex(signing.VerificationError, 'invalid property list'):
            self.check()


class ParserTests(unittest.TestCase):
    def test_malformed_xml_reports_a_concise_validation_error(self):
        with self.assertRaisesRegex(signing.VerificationError, 'invalid property list'):
            signing.parse_plist(b'<?xml version="1.0"?><plist><dict>', 'test fixture')

    def test_non_dictionary_property_lists_are_rejected(self):
        with self.assertRaisesRegex(signing.VerificationError, 'dictionary'):
            signing.parse_plist(plistlib.dumps(['not-a-dictionary']), 'test fixture')

    @unittest.skipIf(sys.platform == 'darwin', 'This assertion applies to non-macOS hosts.')
    def test_non_macos_cannot_report_actual_signature_verification(self):
        with self.assertRaisesRegex(signing.VerificationError, 'requires macOS'):
            signing.verify_exported_app(Path('does-not-exist.app'), RELEASE)


if __name__ == '__main__':
    unittest.main()
