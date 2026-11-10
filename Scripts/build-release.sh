#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DEVTOOLS_RELEASE_DERIVED_DATA:-$project_root/DerivedData/ReleaseBuild}"
output_path="${DEVTOOLS_RELEASE_BUILD_OUTPUT:-$project_root/Build/DevTools-iOS-Device-Release-Unsigned.zip}"
log_path="${DEVTOOLS_RELEASE_BUILD_LOG:-$project_root/Build/Logs/device-release-unsigned.log}"
package_cache="${DEVTOOLS_PACKAGE_CACHE:-$project_root/DerivedData/SourcePackages}"

cd "$project_root"
mkdir -p "$(dirname "$output_path")" "$(dirname "$log_path")"

build_release() {
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "This build needs Xcode on macOS. Run Scripts/build-release.sh on a Mac with the iOS 27 SDK." >&2
        exit 1
    fi
    sdk_list="$(xcodebuild -showsdks)"
    if [[ "$sdk_list" != *"iOS 27"* ]]; then
        echo "Install an Xcode version with the iOS 27 SDK, or change the project's deployment targets for your SDK." >&2
        exit 1
    fi

    xcodebuild -version
    python3 Scripts/validate-project.py
    xcodebuild -project DevTools.xcodeproj -scheme DevTools \
        -clonedSourcePackagesDirPath "$package_cache" -resolvePackageDependencies
    xcodebuild -project DevTools.xcodeproj -scheme DevTools -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$package_cache" \
        CODE_SIGNING_ALLOWED=NO DEPLOYMENT_LOCATION=NO build

    app_path="$derived_data/Build/Products/Release-iphoneos/DevTools.app"
    if [[ ! -d "$app_path" ]]; then
        echo "Xcode reported success but did not produce the Release DevTools.app." >&2
        exit 1
    fi
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_path"
    echo "Unsigned Release device build: $output_path"
    echo "Build log: $log_path"
    echo "This unsigned .app is not ready for installation or TestFlight upload."
    echo "For TestFlight, archive and distribute the DevTools scheme in Xcode using your signing team."
}

# pipefail preserves a failed validation/build result while retaining its full log.
build_release 2>&1 | tee "$log_path"
