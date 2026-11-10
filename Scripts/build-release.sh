#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DEVTOOLS_RELEASE_DERIVED_DATA:-$project_root/DerivedData/ReleaseBuild}"
output_path="${DEVTOOLS_RELEASE_BUILD_OUTPUT:-$project_root/Build/DevTools-iOS-Device-Release-Unsigned.zip}"
log_path="${DEVTOOLS_RELEASE_BUILD_LOG:-$project_root/Build/Logs/device-release-unsigned.log}"
archive_path="${DEVTOOLS_RELEASE_ARCHIVE_PATH:-$project_root/Build/DevTools-Unsigned.xcarchive}"

cd "$project_root"
mkdir -p "$(dirname "$output_path")" "$(dirname "$log_path")"

DEVTOOLS_ARCHIVE_PATH="$archive_path" \
DEVTOOLS_ARCHIVE_DERIVED_DATA="$derived_data" \
DEVTOOLS_ARCHIVE_LOG="$log_path" \
    bash Scripts/archive-ios.sh --unsigned

app_path="$archive_path/Products/Applications/DevTools.app"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_path"
echo "Unsigned Release device build: $output_path"
echo "Build log: $log_path"
echo "This unsigned .app is not ready for installation or TestFlight upload."
