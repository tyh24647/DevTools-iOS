#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DEVTOOLS_DERIVED_DATA:-$project_root/DerivedData/MediaBuild}"
output_path="${DEVTOOLS_BUILD_OUTPUT:-$project_root/Build/DevTools-iOS-Simulator.zip}"
log_path="${DEVTOOLS_BUILD_LOG:-$project_root/Build/Logs/simulator-debug.log}"
package_cache="${DEVTOOLS_PACKAGE_CACHE:-$project_root/DerivedData/SourcePackages}"

cd "$project_root"
mkdir -p "$(dirname "$output_path")" "$(dirname "$log_path")"

build_simulator() {
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "This build needs Xcode on macOS. Run Scripts/build-ios.sh on a Mac with the iOS 27 SDK." >&2
        exit 1
    fi
    sdk_list="$(xcodebuild -showsdks)"
    if [[ "$sdk_list" != *"iOS 27"* ]]; then
        echo "Install an Xcode version with the iOS 27 SDK, or change the project's deployment targets for your SDK." >&2
        exit 1
    fi

    build_actions=(build)
    case "${DEVTOOLS_ANALYZE:-0}" in
        0)
            ;;
        1)
            build_actions+=(analyze)
            ;;
        *)
            echo "DEVTOOLS_ANALYZE must be 0 or 1." >&2
            exit 1
            ;;
    esac

    xcodebuild -version
    python3 Scripts/validate-project.py
    xcodebuild -project DevTools.xcodeproj -scheme DevTools \
        -clonedSourcePackagesDirPath "$package_cache" -resolvePackageDependencies
    xcodebuild -project DevTools.xcodeproj -scheme DevTools -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$package_cache" \
        CODE_SIGNING_ALLOWED=NO DEPLOYMENT_LOCATION=NO "${build_actions[@]}"

    app_path="$derived_data/Build/Products/Debug-iphonesimulator/DevTools.app"
    if [[ ! -d "$app_path" ]]; then
        echo "Xcode reported success but did not produce DevTools.app." >&2
        exit 1
    fi
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_path"
    echo "Simulator build: $output_path"
    echo "Build log: $log_path"
    echo "To install on an iPhone, use the DevTools scheme in Xcode with your signing team."
}

# pipefail preserves a failed validation/build result while retaining its full log.
build_simulator 2>&1 | tee "$log_path"
