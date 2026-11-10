> Review candidate: **1.0.0 (2)**. This revision removes the built-in website-media downloader, stream recorder, media deep-link handoff, and native media-acquisition bridge. It keeps browser debugging, generic user scripts, and media imported through Files. See [media behavior](MEDIA-PARITY.md), [release preparation](Documentation/RELEASE.md), and the [draft response to Guideline 5.2.3](Documentation/APP-REVIEW-5.2.3.md).

# ⚙︎ DevTools for iOS

SwiftUI app with an in-app browser, Safari Web Extension, and six independently named Safari share-sheet actions. The active app uses the Swift files at the repository root; the older copies in `App/` are not the `DevTools` target's app source.

The app defaults to **enabled** and **run on every webpage**. Safari still requires the owner to enable the extension and grant website access. Blacklists take priority over AllowLists. The package-update switch also defaults to on; Release builds use it to check bundled developer-tool versions. The generic script importer is a separate feature and remains available in Release.

## Open and run

1. Open **DevTools.xcodeproj** in Xcode with the **iOS 27 SDK**. The main app and Safari extension currently target iOS 27.0; use a compatible simulator or physical device.
2. Select your development team in Xcode. Optional shared identifier overrides belong in `Configuration/Developer.xcconfig`, copied from the supplied example. Target settings can override xcconfig values, so verify the effective settings in Xcode.
3. In Signing & Capabilities, verify the app and **all seven extension targets** use the same team and registered App Group. The supplied identifier is `group.com.tyh24647.DevTools`; `DT_APP_GROUP` and `DT_BUNDLE_PREFIX` define shared identifiers.
4. Select the **DevTools** scheme and your iPhone, then Run.
5. On the phone, open **Settings → Apps → Safari → Extensions → ⚙︎ DevTools**, enable it and grant website access. Choose All Websites for automatic operation everywhere.
6. Reload a normal HTTP/HTTPS page. The floating Eruda button should appear. Safari’s extension popup provides Show, Hide, enable/disable, and quick rule creation.
7. In Safari’s Share sheet, use **Edit Actions** to favorite the six DevTools actions. iOS controls their order and displayed/truncated labels.

No npm installation is needed to open or build the supplied project: the JavaScript assets are already bundled. npm is used only for development-time updates and tests.

**Candidate status, verified 2026-11-10:** Build 1 was submitted to TestFlight and rejected under Guideline 5.2.3. Build 2 code commit `72b32b8bdc0d7c19d89183c7043c8f8379fd83e2` passed [CI run 42881231065](https://github.com/tyh24647/DevTools-iOS/actions/runs/42881231065), including browser and Swift tests, the Debug simulator build/static analysis, and the unsigned Release device build. Both packaged products were inspected. Simulator UI launch, physical-device behavior, signing, upload, and App Review approval remain unverified or pending. See [release validation](Documentation/RELEASE.md).

## Included behavior

| Feature | Implementation |
| --- | --- |
| Run everywhere | On by default; selected blacklists exclude matching pages |
| Allow-only mode | Turn off Run on every webpage; any selected AllowList may permit a page |
| Named lists | Create, rename, change type, select/deselect and delete multiple lists |
| Rules | Domain/subdomains, exact URL, wildcard and bounded JavaScript regex |
| Precedence | Disabled → blacklist deny → run everywhere → AllowList match → deny |
| Live changes | Foreground pages refresh state approximately every 10 seconds; share actions, popup actions and navigation trigger immediate refresh |
| Show / Hide | Show opens panel + icon; Hide hides both but preserves the active page console session |
| Enable / Disable | Changes the global DevTools setting, not Safari’s system permission |
| Pro | StoreKit 2 monthly subscription or non-consumable lifetime purchase |
| In-app browser | Tabbed WKWebView browsing, address/search controls, console, page options, and cookie tools |
| Generic scripts | Local JavaScript import, URL-to-editor import, user editing, matching metadata, and explicit enablement in the in-app browser |
| Media files | Files import, folders, supported local playback, conversion of a copy, Share, and supported Photos export |
| App styling | RegexDojo-inspired native tabs, rounded material cards, accent presets and system/light/dark modes |
| App icon | Included opaque 1024px icon and extension icon sizes |

The six Action Extension titles are exactly:

- ⚙︎ DevTools - Add to Blacklist
- ⚙︎ DevTools - Add to AllowList
- ⚙︎ DevTools - Show
- ⚙︎ DevTools - Hide
- ⚙︎ DevTools - Enable
- ⚙︎ DevTools - Disable

The add actions offer list selection, match type and optional creation of a new list. Adding to an inactive list leaves it inactive. Ads are not included in any extension.

## User scripts and local media

In **Plugins → +**, choose **New userscript**, **New Eruda panel**, **Import local JavaScript**, or **Import JavaScript URL**. URL import uses **Read for review** to load source into the editor. Save it, then explicitly turn on its switch. New imports start disabled; changing a saved script's source or kind disables it again. Script validation checks syntax and supported metadata before enablement. The bundled Page CSS editor is a separate, initially enabled tool.

Custom scripts run on matching pages in the **in-app browser**. They are not automatically installed into the Safari extension. The library supports up to 20 scripts, each at most 256 KiB, and a bounded subset of userscript grants; unsupported grants are rejected. This is a general development feature, with no bundled media-downloader script or native media-acquisition API for scripts. It does not claim to prevent every operation that ordinary page JavaScript can perform.

Use **Media files → Import from Files** for documents selected through the system picker. Tap a supported audio/video file to play it. Long-press a file for **Convert a copy**, **Save to Photos** when supported, or sharing and file-management actions. Conversion operates on an imported local file and preserves the original. See [MEDIA-PARITY.md](MEDIA-PARITY.md) for precise paths and format limits.

## Bundled npm versions

These versions were resolved from npm on September 30, 2026 and pinned in package-lock.json:

| Package | Version | Role |
| --- | --- | --- |
| eruda | 3.4.3 | Core console |
| eruda-vue | 1.1.1 | Default current Eruda Vue adapter |
| eruda-vue-devtools | 1.0.1 | Optional legacy Eruda Vue adapter |
| vconsole | 3.15.1 | Optional alternative console |
| vue-vconsole-devtools | 1.0.9 | Vue adapter for vConsole |
| eruda-code | 2.2.0 | Code editor |
| eruda-dom | 2.0.0 | DOM explorer |
| eruda-timing | 2.0.1 | Navigation timing |
| eruda-fps | 2.0.0 | Frame-rate monitor |
| eruda-features | 2.1.0 | Browser feature detection |

A first-party **resource timing** plugin adds a buffered PerformanceObserver view for fetch, XHR and other resources: start, duration, DNS, connect, TLS, TTFB, download, bytes and a waterfall. It retains the latest 1,000 entries. Cross-origin detail needs Timing-Allow-Origin; zero timings may also reflect caching.

Vue adapters embed their own versions of the Vue DevTools frontend. The latest published mobile adapter is not necessarily the latest desktop Vue DevTools release. This project does not try to install the desktop/Electron @vue/devtools app on iOS. Vue inspection depends on the target page exposing compatible hooks; production builds may remove them.

Only the chosen console/Vue adapter initializes, avoiding overlapping Eruda and vConsole hooks. Bundled UMD modules use a private CommonJS scope to avoid replacing a page-owned window.eruda. The FPS adapter requires a Date.now compatibility shim with Eruda 3; the shim is outside the unmodified upstream package.

## Requested defaults

All six supplied settings groups are seeded before initialization:

- Console: async render, catch global errors, JavaScript execution, console override, extra info, unenumerable properties, getter values and lazy evaluation enabled; show on error disabled; unlimited logs.
- Dev tools: opacity 0.98, panel height 55%, Material Palenight.
- Elements: override event target and observe elements.
- Entry button: remember position, initial x 263.807642 / y 0; position is clamped to the current viewport and remembered per website.
- Resources: hideErudaSetting false, observeElement true.
- Sources: line numbers, formatting and four-space indentation.

Pro enables changing the panel size, transparency, theme and icon persistence, plus Eruda’s own settings controls. Unlimited logs and invasive console/DOM inspection can consume substantial memory or affect a page; these are the expressly requested defaults.

## Bundled-tool updates and script imports

`DEVTOOLS_REMOTE_UPDATES` controls the updater for the app's known bundled developer-tool packages. It does **not** control the separate **Plugins** importer described above. This distinction applies to both the implementation and the review notes.

**Debug / personal-development build**

- The automatic-update switch defaults to on.
- Checks npm’s latest dist-tag at app launch/foreground; falls back to jsDelivr version resolution if npm metadata cannot be reached.
- Downloads a **version-pinned** known bundle path from jsDelivr, verifies SHA-256 against jsDelivr file metadata and installs atomically in the App Group.
- The next page load can use the cached bundle. The integrity check detects corruption; it is not an independent vendor signature or a promise of API compatibility.
- Keeps bundled code available offline and when a page’s CSP blocks dynamically inserted code.
- A last-resort Eruda CDN load is attempted only if no bundled Eruda file can load and automatic updates are enabled.
- Clear downloaded packages to revert to bundled versions. Cached upgrades apply on new page loads; an existing page keeps its loaded versions.

**Release / distribution build**

- The same switch performs automatic version checks, but executable packages remain bundled.
- `DEVTOOLS_REMOTE_UPDATES` is absent, so the package-cache path cannot supply downloaded replacements for bundled developer tools.
- Deliver package upgrades in a signed app update. Do not re-enable personal-development remote execution without reviewing distribution requirements.
- The app explains this behavior instead of claiming that it installed newer executable packages.

iOS does not run npm inside this app. npm prepares bundled tool assets during development. Generic script import reads user-selected JavaScript into a reviewable editor and stores it separately from the bundled-tool package cache.

## Purchases

Local StoreKit configuration contains the requested US prices:

| Product ID | Type | US test price |
| --- | --- | --- |
| com.tyh24647.DevTools.pro.monthly | Auto-renewing, 1 month | $2.99 |
| com.tyh24647.DevTools.pro.lifetime | Non-consumable | $19.99 |

Choose the **DevTools-StoreKit** scheme for local purchase testing. If Xcode does not resolve the configuration automatically, select Configuration/DevTools.storekit in **Edit Scheme → Run → Options → StoreKit Configuration**. Testing transactions do not charge real money. Production products must be created in your App Store Connect account; real price labels come from StoreKit’s localized displayPrice.

Both products unlock the same Pro features. Restore, pending purchases, cancellation, verified transactions, expiry and revocation are handled. Buying lifetime does not cancel an existing monthly subscription; the paywall directs users to subscription management.

The app is ad-free. Advertising SDKs, banner views, interstitials, app-open ads, and ad consent UI are removed. The browser's page options retain its ad-blocking controls. There is no built-in website-media picker in this review candidate.

See Documentation/RELEASE.md for the required account configuration and release considerations.

## Development commands

On a Mac with the iOS 27 SDK:

```bash
bash Scripts/build-ios.sh
bash Scripts/build-release.sh
```

The first command writes `Build/DevTools-iOS-Simulator.zip`. The second writes `Build/DevTools-iOS-Device-Release-Unsigned.zip`. These are separate simulator and **unsigned device** products; the device ZIP is not an installable IPA or a TestFlight upload. Logs are written to `Build/Logs/`. Set `DEVTOOLS_ANALYZE=1` when calling the simulator script to include static analysis.

GitHub Actions runs the Node/script checks and both Chromium smoke suites on Linux. Its macOS job executes the local file/conversion/thumbnail tests, then the simulator build with analysis and the unsigned Release device build. Pull requests, pushes to `main`, and manual dispatch trigger the workflow. The older analyzer workflow is manual-only to avoid a duplicate automatic simulator build. App artifacts and logs are retained for 14 days. Signing and upload require a separate Xcode archive/distribution step. See [TESTING.md](Documentation/TESTING.md) for the verified run and [RELEASE.md](Documentation/RELEASE.md) for artifact links and remaining work.

Run from this folder, using Node 20.11+ and Python 3.9+:

    npm ci --ignore-scripts
    npm test
    npm run check
    npx playwright install chromium
    npm run test:browser

Refresh the bundled tools, then test before releasing:

    npm run update:tools
    npm test
    npm run check
    npm run test:browser

Update the existing project after changing source/resource file membership:

    python3 Scripts/patch-media-project.py

The patcher uses Python's standard library. `npm run project` invokes it. The compatibility entry point `Scripts/generate-project.py` delegates to the same maintained patcher and preserves the current project layout.

## Structure and boundaries

- Root Swift files: active SwiftUI app, StoreKit, settings, and bundled-tool package updater.
- Browser/ and BrowserResources/: in-app browser, debugger bootstrap, script runtime, and editor assets.
- Plugins/: generic JavaScript source import, editor, library, and enablement.
- Media/: local document library, playback, conversion, and export.
- App/: legacy app-source copies; not the active `DevTools` app target's source.
- Shared/: Codable models, locked atomic App Group storage, validation, package cache.
- SafariExtension/Resources/: MV3 background, isolated content script, popup, page runtime, rule worker and bundled tools.
- ActionExtension/: shared implementation compiled into six distinct action targets.
- Tests/: rule/runtime checks and actual browser smoke test.
- Configuration/: signing settings, plist files, entitlements and StoreKit testing.
- Documentation/: setup/release notes, test scope and actual browser preview.
- Licenses/: upstream distributed notices and npm metadata.

Safari-native messaging reads configuration from the shared container. Only messages originating in the extension popup can mutate settings through the JavaScript bridge. Page events cannot grant Pro, add lists or disable exclusions. Share commands use short-lived tickets bound to the shared URL. A regex runs in a dedicated worker with a 750ms deadline; failure stops injection.

This is page-context debugging, not an OS-level Safari Web Inspector. It cannot inspect Safari internals, recover already-missed request bodies or guarantee access to every cross-origin frame. Injection applies to top-level HTTP/HTTPS pages; Safari permissions and browser-protected pages remain authoritative. Vue hooks and page CSP can limit functionality.

## References

- Apple Safari Web Extensions: https://developer.apple.com/documentation/safariservices/safari-web-extensions
- Native messaging: https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension
- Safari action preprocessing/finalization: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html
- App Review Guidelines, including 5.2.3: https://developer.apple.com/app-store/review/guidelines/
- App Review information: https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review
- Eruda: https://github.com/liriliri/eruda
