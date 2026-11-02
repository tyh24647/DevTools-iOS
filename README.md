> Native browser and media recording update: see [MEDIA-PARITY.md](MEDIA-PARITY.md) for usage, platform limits, build requirements and validation. On a Mac with an iOS 27 SDK, run `bash Scripts/build-ios.sh` for an unsigned Simulator app, or open the `DevTools` scheme in Xcode for a signed device build.

# ⚙︎ DevTools for iOS

SwiftUI containing app + Safari Web Extension + six independently named Safari share-sheet actions.

The app defaults to **enabled**, **run on every webpage**, and **automatically install updates**. Safari still requires the owner to enable the extension and grant website access. Blacklists take priority over AllowLists.

## Open and run

1. Open **DevTools.xcodeproj** in Xcode 16 or newer, using an Xcode version that supports the iOS version installed on your phone. Deployment target: iOS 17.5.
2. Copy Configuration/Developer.xcconfig.example to Configuration/Developer.xcconfig and set your development team. Use an App Group registered to that team.
3. In Signing & Capabilities, verify the app and **all seven extension targets** use the same team and App Group. The supplied identifier is group.com.tyh24647.DevTools; change DT_APP_GROUP once in Developer.xcconfig if needed. DT_BUNDLE_PREFIX defaults to com.tyh24647.DevTools.
4. Let Xcode resolve the media-processing package through Swift Package Manager.
5. Select the **DevTools** scheme and your iPhone, then Run.
6. On the phone, open **Settings → Apps → Safari → Extensions → ⚙︎ DevTools**, enable it and grant website access. Choose All Websites for automatic operation everywhere.
7. Reload a normal HTTP/HTTPS page. The floating Eruda button should appear. Safari’s extension popup provides Show, Hide, enable/disable, and quick rule creation.
8. In Safari’s Share sheet, use **Edit Actions** to favorite the six DevTools actions. iOS controls their order and displayed/truncated labels.

No npm installation is needed to open or build the supplied project: the JavaScript assets are already bundled. npm is used only for development-time updates and tests.

**Build status:** Swift syntax, project serialization, resources and JavaScript behavior were checked in a Linux workspace. Xcode compilation, signing, StoreKit integration, AdMob integration and real iPhone Safari behavior have **not** been verified here. This is an Xcode source deliverable, not a signed IPA or an App Store submission.

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

## Automatic updates: explicit build distinction

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
- The native bridge is compiled without DEVTOOLS_REMOTE_UPDATES, so it cannot supply downloaded executable assets.
- Deliver package upgrades in a signed app update. Do not re-enable personal-development remote execution without reviewing distribution requirements.
- The app explains this behavior instead of claiming that it installed newer executable packages.

iOS does not provide a usable npm command-line runtime inside an ordinary app. JavaScript “installation” here means bundling npm artifacts at build time or caching approved bundle files in the Debug build.

## Purchases

Local StoreKit configuration contains the requested US prices:

| Product ID | Type | US test price |
| --- | --- | --- |
| com.tyh24647.DevTools.pro.monthly | Auto-renewing, 1 month | $2.99 |
| com.tyh24647.DevTools.pro.lifetime | Non-consumable | $19.99 |

Choose the **DevTools-StoreKit** scheme for local purchase testing. If Xcode does not resolve the configuration automatically, select Configuration/DevTools.storekit in **Edit Scheme → Run → Options → StoreKit Configuration**. Testing transactions do not charge real money. Production products must be created in your App Store Connect account; real price labels come from StoreKit’s localized displayPrice.

Both products unlock the same Pro features. Restore, pending purchases, cancellation, verified transactions, expiry and revocation are handled. Buying lifetime does not cancel an existing monthly subscription; the paywall directs users to subscription management.

The app is ad-free. Advertising SDKs, banner views, interstitials, app-open ads, and ad consent UI are removed. The browser blocks known advertising hosts and explicitly marked ad containers; promotional clips served as normal site media remain distinguishable by their duration in the media picker.

See Documentation/RELEASE.md for the required account configuration and release considerations.

## Development commands

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

Regenerate the project after changing source/resource file membership:

    python3 Scripts/generate-project.py

This generator uses only Python’s standard library. It produces the already-included eight-target project; no XcodeGen installation is needed.

## Structure and boundaries

- App/: SwiftUI, StoreKit, advertising and package updater.
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
- App Review Guidelines 2.5.2 and 2.5.18: https://developer.apple.com/app-store/review/guidelines/
- iAd discontinuation: https://developer.apple.com/news/?id=01152016a
- AdMob iOS: https://developers.google.com/admob/ios/quick-start
- App-open ads: https://developers.google.com/admob/ios/app-open
- Eruda: https://github.com/liriliri/eruda
