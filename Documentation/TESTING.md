# Validation record — review candidate 1.0.0 (2)

## Current repair checkpoints

Verified **2026-11-10** for code commit **`72b32b8bdc0d7c19d89183c7043c8f8379fd83e2`**: [CI run 42881231065](https://github.com/tyh24647/DevTools-iOS/actions/runs/42881231065) completed successfully. These results apply to that code commit; the subsequent documentation update does not change the tested implementation.

| Check | Current result |
| --- | --- |
| `npm test` | 23/23 Node behavior checks passed |
| `npm run check` | Passed, including script/resource/project validation |
| `python3 Scripts/test-downloads.py --check-source` | Local-media boundary checks passed |
| Build scripts and workflow files | Bash syntax, YAML parsing, and whitespace checks passed |
| Chromium browser integration | Six scenarios passed with no uncaught errors |
| Native-browser bootstrap smoke | User scripts, debugger, source formatting, and absence of acquisition hooks passed |
| Full macOS Swift file/conversion/thumbnail tests | 11 tests passed |
| Debug simulator build/static analysis | `BUILD SUCCEEDED` and `ANALYZE SUCCEEDED` |
| Unsigned Release device build | `BUILD SUCCEEDED` |
| Simulator and Release ZIP inspection | All eight bundles are 1.0.0 (2); seven extensions have the expected IDs; generic script runtime matches the code commit; removed acquisition JavaScript, FFmpeg, and media URL scheme are absent |
| Simulator UI launch, physical-device/Photos-permission checks | Not performed |
| Signed archive, TestFlight upload, App Review approval | Pending |

The inspected Debug simulator product uses the iOS Simulator 27.1 SDK and includes arm64 and x86_64 architectures. The Release product uses the iPhoneOS 27.1 SDK and contains no code-signature directory, provisioning profile, or debug dylibs. Inspection confirms packaged contents, not launch or device behavior. [RELEASE.md](RELEASE.md) links the inspected artifacts, which expire on 2026-11-24.

## Historical baselines

The original creation environment recorded 22 Node checks and six successful smoke scenarios using **Playwright with Chromium 134 headless shell on Linux**. Those scenarios covered bundled Eruda initialization, show/hide, Pro tools/resource timing, blocked-page teardown, and the alternative Vue/vConsole adapters. They predate the build-2 changes and must not be reported as current-candidate passes. Any preview captured in that run is a browser fixture image, not an iPhone screenshot.

The prior `main` commit `d11231f8fed00d986f22ab76ae1a0dd677e34b9c` passed the [November 6 simulator workflow](https://github.com/tyh24647/DevTools-iOS/actions/runs/42166841843). Its separate generic analyzer workflow failed after choosing a device destination. The candidate workflow uses an explicit simulator destination and signing override. The historical success does not validate this changed source.

Earlier HLS/MSE/WebRTC capture or FFmpeg-remux results describe features removed from this candidate. They are not acceptance criteria for the local-media implementation.

## Configured CI gates

The [iOS workflow](../.github/workflows/ios-build.yml) has two jobs:

- Linux: install pinned npm dependencies and Chromium; run `npm test`, `npm run check`, `npm run test:browser`, and `npm run test:native-browser`.
- macOS (`xcode-27`): execute `python3 Scripts/test-downloads.py`, then build/analyze the Debug simulator app and build the unsigned Release device app.

The native-browser smoke suite exercises the browser bootstrap in Chromium, including developer tools and user scripts, and checks that the removed media bridge/capture hooks are absent. Chromium does not reproduce WKWebView, Safari extension APIs, SwiftUI, system permissions, StoreKit, or signing.

The full macOS helper harness compiles the actual local file/library/export/thumbnail implementations with Swift Testing. It exercises document/file boundaries, file operations, local conversion, and cache behavior. It does not exercise UIKit presentation or Photos permission dialogs. The `--check-source` mode checks source boundaries only.

## Reproduce

From the repository root, with a supported Node version and Python:

```bash
npm ci --ignore-scripts
npm test
npm run check
npx playwright install chromium
npm run test:browser
npm run test:native-browser
python3 Scripts/test-downloads.py --check-source
```

To use a specific installed Chromium executable:

```bash
DEVTOOLS_BROWSER_PATH=/absolute/path/to/chromium npm run test:browser
DEVTOOLS_BROWSER_PATH=/absolute/path/to/chromium npm run test:native-browser
```

On a Mac with Xcode and the iOS 27 SDK:

```bash
python3 Scripts/test-downloads.py
DEVTOOLS_ANALYZE=1 bash Scripts/build-ios.sh
bash Scripts/build-release.sh
```

The two build scripts produce separate simulator/unsigned-device ZIPs and write full logs under `Build/Logs/`. Their exit status preserves failures. See [RELEASE.md](RELEASE.md) for artifact names and the separate signing/upload procedure.

## Physical-device acceptance run

### Browser and Safari developer tools

1. Confirm **Browser** opens and navigation/tabs work. Use **Page and developer tools → Show console / Hide console**.
2. Enable the Safari extension and grant access to a test site. Test its popup and all six share actions from Safari itself.
3. Exercise selected AllowLists/blacklists, blacklist priority, enable/disable, exact URLs, domain matches, wildcard rules, and invalid regex handling.
4. Revoke Safari website permission and verify the extension respects it. Test a strict-CSP page, a Vue development page, and a page without Vue debugging hooks.
5. Check iPhone/iPad layouts and background/foreground restoration. Verify optional StoreKit purchase/restore separately; there is no ad-consent or advertising flow to test.

### Generic scripts

1. Create a harmless userscript matching `https://example.com/*`. Save it and confirm it remains disabled.
2. Enable it and reload a matching browser page; confirm its effect. A nonmatching page should remain unaffected.
3. Import a local JavaScript file and a UTF-8 script URL through **Read for review**. Confirm the editor appears before saving and neither import runs automatically.
4. Edit the source/kind of an enabled script, save it, and confirm it becomes disabled. Exercise invalid metadata, unsupported grants, and the size limit.
5. Confirm the Release bundled-tool updater behavior separately from script import. Generic user-script import remains available even though Release does not replace bundled tool packages.

### Local Files, playback, conversion, and Photos

1. Open **Media files → Import from Files**. Select multiple small tester-created documents, including audio, video, and an image. Test a configured file provider as well as local storage.
2. Create a folder, import into it, rename/move/share files, relaunch, and confirm originals and thumbnails remain accessible. Confirm name collisions do not silently overwrite existing files.
3. Tap local audio/video files. Exercise **Fullscreen**, **Above the file**, and **Picture in Picture** under **Media settings → Open videos**. Test PiP fallback and restoration on a supported physical device.
4. Use **Convert a copy** with supported MP4/MOV and codec choices. Verify playback of the output and preservation of the original. Try unsupported input/options, insufficient storage, and an imported file with external references; verify an error rather than remote acquisition or data loss.
5. Test **Save to Photos** for supported local images/videos with permission accepted and denied. Confirm unsupported files still offer sharing.
6. Inspect browser/Safari UI for obsolete website-video download controls or a dedicated media acquisition panel. Verify the old media deep links and native acquisition routes are absent from the packaged build.

Keep the final device models/OS versions and observed outcomes with the release evidence. The exact reviewer instructions are drafted in [APP-REVIEW-5.2.3.md](APP-REVIEW-5.2.3.md).
