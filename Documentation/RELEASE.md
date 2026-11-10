# Release preparation — 1.0.0 (2)

## Current status

Build **1.0.0 (1)** was submitted to TestFlight and rejected under **Guideline 5.2.3 — Audio/Video Downloading**. The `fix/testflight-media-review` branch prepares **1.0.0 (2)** with the dedicated website-media acquisition paths removed and local-file media tools retained.

Build 2 has **not yet been signed or uploaded as part of this repair**. The Apple response in [APP-REVIEW-5.2.3.md](APP-REVIEW-5.2.3.md) is a draft; no review message has been sent. A source change or passing unsigned build does not establish App Review approval.

Current local checkpoints: 23 Node behavior tests, `npm run check`, and the local-media source-boundary check passed. Candidate browser execution, macOS Swift helper execution, and Xcode CI results are pending. See [TESTING.md](TESTING.md) for details and historical baselines.

## Version and identifiers

`Configuration/Project.xcconfig` sets:

```text
MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 2
DT_BUNDLE_PREFIX = com.tyh24647.DevTools
DT_APP_GROUP = group.com.tyh24647.DevTools
```

The active scheme includes the containing app and these seven extension suffixes:

- `.Safari`
- `.AddBlacklist`
- `.AddAllowList`
- `.Show`
- `.Hide`
- `.Enable`
- `.Disable`

Set and verify the development team in Xcode for all eight targets. Register the shared App Group and provision every bundle identifier. Optional shared overrides belong in `Configuration/Developer.xcconfig`; target-level settings can override them, so inspect the effective build settings. Existing team identifiers do not supply signing credentials.

If changing the bundle prefix, reconcile the product IDs in `PurchaseStore.swift`, the local StoreKit configuration, and the native-application identifier used by the Safari extension. Preserve user data identifiers when preparing an update to an existing app.

## CI validation and artifacts

[The iOS workflow](../.github/workflows/ios-build.yml) runs on pull requests, pushes to `main`, and manual dispatch. A push to the repair branch alone does not trigger a second automatic build. Obsolete runs for the same workflow/ref are canceled.

The Linux job installs the pinned npm dependencies and Chromium, runs the Node suite and structural/script checks, then executes both browser smoke suites. The macOS job uses the verified `xcode-27` runner and runs the actual local file/conversion/thumbnail helper tests before building:

1. **Debug / generic iOS Simulator**, including static analysis.
2. **Release / generic iOS**, with signing disabled.

Both build commands explicitly select `DevTools.xcodeproj` and the `DevTools` scheme, with `CODE_SIGNING_ALLOWED=NO DEPLOYMENT_LOCATION=NO`. The legacy analyzer workflow remains manually runnable; automatic analysis is already included in the simulator build.

| Artifact | Output | Purpose |
| --- | --- | --- |
| `DevTools-iOS-Simulator-Debug` | `Build/DevTools-iOS-Simulator.zip` | Simulator build product |
| `DevTools-iOS-Device-Release-Unsigned` | `Build/DevTools-iOS-Device-Release-Unsigned.zip` | Release/device compilation product; not an installable IPA |
| `DevTools-Xcode-Logs` | `Build/Logs/` | Full build logs, retained even when a build fails |

Artifacts are retained for 14 days. The workflow has no certificate installation, provisioning setup, signed export, or App Store Connect upload step. Consult the run for the exact commit before reporting a gate as passed.

On a Mac with the iOS 27 SDK, reproduce the native checks with:

```bash
python3 Scripts/test-downloads.py
DEVTOOLS_ANALYZE=1 bash Scripts/build-ios.sh
bash Scripts/build-release.sh
```

## Prepare the signed submission

1. Complete the physical-device acceptance run in [TESTING.md](TESTING.md), including the Safari extension and local Files/Photos workflows.
2. Confirm the app and extensions resolve to version 1.0.0, build 2, and the intended team/App Group. If build 2 has already been uploaded by the time this procedure is used, select a new build number.
3. Select the **DevTools** scheme and a generic iOS device destination in Xcode. Its Archive action uses **Release**.
4. Use **Product → Archive**. Inspect the resulting app archive, included extensions, effective entitlements, and bundled resources. Check that the removed acquisition resources and FFmpeg frameworks are absent.
5. Use Organizer's distribution flow for **App Store Connect** with the appropriate account/signing configuration. Validate the archive and upload it.
6. After Apple finishes processing, select the actual new build in TestFlight. Update the beta description and testing notes to describe browser debugging, generic scripts, and local-file media tools. Review and adapt the draft 5.2.3 response to the verified build before sending it.

No completed step above should be inferred from the presence of this document. Record the archive/build identifier and resulting App Store Connect status when performed.

## Bundled packages and generic scripts

Release does not define `DEVTOOLS_REMOTE_UPDATES`. The bundled-tool updater may check npm/jsDelivr version metadata, but it does not replace the packaged developer-tool code in Release. This restriction is specific to that updater.

The separate **Plugins** feature remains available in Release: local JavaScript import, user-entered script URL import into an editor, source review/editing, and explicit enablement. Describe it accurately in review notes. Do not characterize the app as executing only bundled JavaScript, and do not characterize generic script support as approval for an otherwise rejected media feature.

## Purchases, privacy, and metadata

The app is ad-free; there is no AdMob account or consent-flow setup for this release. Keep screenshots and descriptions consistent with the current features and remove prior website-media downloading/recording claims.

StoreKit products remain `com.tyh24647.DevTools.pro.monthly` and `com.tyh24647.DevTools.pro.lifetime`. The local test configuration uses $2.99/month and $19.99 lifetime; production availability and localized prices come from App Store Connect. Test purchase, cancellation, restore, pending transactions, expiry/refund, and the warning that lifetime does not cancel an existing subscription. A StoreKit configuration file is not proof that production products are configured.

Review the actual Files, Photos, website permission, package-check, and user-script behavior when completing privacy disclosures. Use a working privacy-policy/support URL and verify the in-app privacy screen. Photos usage descriptions must describe exports of user-selected local files. Provide App Review with any information needed to exercise optional purchases and the retained features; do not claim a demo account or entitlement exists unless it has been configured.

References: [Apple's App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [complete review information](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review), and [replying to App Review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages).
