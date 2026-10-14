#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DEVTOOLS_DERIVED_DATA:-$project_root/DerivedData/MediaBuild}"
output_path="${DEVTOOLS_BUILD_OUTPUT:-$project_root/Build/DevTools-iOS-Simulator.zip}"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "This build needs Xcode on macOS. Run Scripts/build-ios.sh on a Mac with the iOS 27 SDK." >&2
    exit 1
fi
if ! xcodebuild -showsdks | grep -q 'iOS 27'; then
    echo "Install an Xcode version with the iOS 27 SDK, or change the project's deployment targets for your SDK." >&2
    exit 1
fi

cd "$project_root"
python3 Scripts/validate-project.py
xcodebuild -project DevTools.xcodeproj -scheme DevTools -resolvePackageDependencies
xcodebuild -project DevTools.xcodeproj -scheme DevTools -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO DEPLOYMENT_LOCATION=NO build

app_path="$derived_data/Build/Products/Debug-iphonesimulator/DevTools.app"
if [[ ! -d "$app_path" ]]; then
    echo "Xcode reported success but did not produce DevTools.app." >&2
    exit 1
fi
mkdir -p "$(dirname "$output_path")"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_path"
echo "Simulator build: $output_path"
echo "To install on an iPhone, use the DevTools scheme in Xcode with your signing team."
