#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
archive_mode="${1:---unsigned}"
case "$archive_mode" in
    --unsigned)
        archive_name="DevTools-Unsigned"
        signing_settings=(CODE_SIGNING_ALLOWED=NO)
        ;;
    --signed)
        archive_name="DevTools"
        signing_settings=(CODE_SIGNING_ALLOWED=YES)
        ;;
    *)
        echo "Usage: bash Scripts/archive-ios.sh [--unsigned|--signed]" >&2
        exit 2
        ;;
esac

archive_path="${DEVTOOLS_ARCHIVE_PATH:-$project_root/Build/$archive_name.xcarchive}"
derived_data="${DEVTOOLS_ARCHIVE_DERIVED_DATA:-$project_root/DerivedData/ArchiveBuild}"
log_path="${DEVTOOLS_ARCHIVE_LOG:-$project_root/Build/Logs/archive.log}"
package_cache="${DEVTOOLS_PACKAGE_CACHE:-$project_root/DerivedData/SourcePackages}"

cd "$project_root"
mkdir -p "$(dirname "$archive_path")" "$(dirname "$log_path")"

archive_app() {
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "Archiving requires Xcode on macOS with the iOS 27 SDK." >&2
        exit 1
    fi
    if [[ -e "$archive_path" ]]; then
        echo "An archive already exists at $archive_path. Set DEVTOOLS_ARCHIVE_PATH to a new path to preserve it." >&2
        exit 1
    fi
    sdk_list="$(xcodebuild -showsdks)"
    if [[ "$sdk_list" != *"iOS 27"* ]]; then
        echo "Install Xcode with the iOS 27 SDK before archiving this project." >&2
        exit 1
    fi
    if [[ "$archive_mode" == --signed ]]; then
        identities="$(security find-identity -v -p codesigning)"
        if ! [[ "$identities" =~ [1-9][0-9]*[[:space:]]+valid[[:space:]]+identities[[:space:]]+found ]]; then
            echo "No valid signing identity is available. Configure this Mac's Xcode signing or install the existing signing credentials before creating a signed archive." >&2
            exit 1
        fi
    fi

    xcodebuild -version
    python3 Scripts/validate-project.py
    xcodebuild -project DevTools.xcodeproj -scheme DevTools -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" \
        -archivePath "$archive_path" -clonedSourcePackagesDirPath "$package_cache" \
        DEPLOYMENT_LOCATION=YES "${signing_settings[@]}" archive

    python3 - "$archive_path" "$archive_mode" <<'PY'
from pathlib import Path
import plistlib
import re
import sys

archive = Path(sys.argv[1])
metadata = plistlib.loads((archive / 'Info.plist').read_bytes())
relative_app = metadata.get('ApplicationProperties', {}).get('ApplicationPath')
assert relative_app == 'Applications/DevTools.app', 'Xcode did not produce an application archive.'
app = archive / 'Products' / relative_app
config = Path('Configuration/Project.xcconfig').read_text()
version = re.search(r'^MARKETING_VERSION\s*=\s*(\S+)', config, re.M).group(1)
build = re.search(r'^CURRENT_PROJECT_VERSION\s*=\s*(\d+)', config, re.M).group(1)
prefix = re.search(r'^DT_BUNDLE_PREFIX\s*=\s*(\S+)', config, re.M).group(1)
expected = {prefix + suffix for suffix in ('', '.Safari', '.Show', '.Hide', '.Enable', '.Disable', '.AddBlacklist', '.AddAllowList')}
bundles = [app, *sorted((app / 'PlugIns').glob('*.appex'))]
assert len(bundles) == 8, 'The archive must contain the app and all seven extensions.'
identifiers = set()
for bundle in bundles:
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    identifiers.add(info['CFBundleIdentifier'])
    assert info['CFBundleShortVersionString'] == version
    assert str(info['CFBundleVersion']) == build
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    assert 'CFBundleURLTypes' not in info
    if sys.argv[2] == '--unsigned':
        assert not (bundle / '_CodeSignature').exists()
        assert not (bundle / 'embedded.mobileprovision').exists()
assert identifiers == expected, 'The archive bundle identifiers differ from the project.'
removed = {'media-resources.js', 'mse-capture.js', 'native-bridge.js', 'media-discovery.js', 'media-handoff.js'}
assert not any(path.name in removed or 'ffmpeg' in path.name.lower() for path in app.rglob('*'))
for filename in ('native-bootstrap.js', 'userscripts.js', 'page-runtime.js'):
    assert (app / 'BrowserResources' / filename).read_bytes() == Path('BrowserResources', filename).read_bytes()
print(f'Validated application archive: {version} ({build}), eight matching bundles, retained scripts, and removed acquisition resources absent.')
PY
    ditto -c -k --sequesterRsrc --keepParent "$archive_path" "$archive_path.zip"
    echo "Archive: $archive_path"
    echo "Archive ZIP: $archive_path.zip"
    if [[ "$archive_mode" == --unsigned ]]; then
        echo "This archive is unsigned. TestFlight still requires a signed archive/export with the correct App Group entitlements."
    else
        echo "This archive has not been uploaded. Verify its signing and distribution export before TestFlight upload."
    fi
}

archive_app 2>&1 | tee "$log_path"
