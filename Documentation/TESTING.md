# Validation record

## Completed in the creation environment

- 22 Node behavior checks passed for matching, page-runtime lifecycle and native-message authorization.
- All authored extension scripts and all 10 wrapped upstream bundles parsed.
- Manifest-referenced files were checked for existence.
- Six real Chromium smoke scenarios passed with no uncaught page errors:
  1. Eruda initializes with the requested defaults and preserves a page-owned global.
  2. Hide/Show controls the entry button and panel.
  3. Pro plugins initialize; resource timing observes a real fetch.
  4. A blocked decision tears down the console.
  5. The legacy eruda-vue-devtools adapter initializes.
  6. vConsole with vue-vconsole-devtools initializes.
- The latest eruda-fps package relied on the removed eruda.util.now helper; a runtime Date.now shim fixed that observed failure.
- Swift source parsed with tree-sitter-swift; this is a syntax check, not Swift type checking.
- The OpenStep Xcode project parsed with the xcode npm library and the independent structural validator.
- Plist, resource and eight-target embedding checks are performed by Scripts/validate-project.py.
- Previews/eruda-resource-timing.png is an actual browser fixture capture, not a native-app screenshot.

The browser smoke test used Playwright with Chromium 134 headless shell in Linux. It tests the real bundled JavaScript but does not reproduce Safari’s extension API, native messaging, share sheet, StoreKit or advertising SDK.

## Not verified in this environment

- Xcode compilation/linking, provisioning, signing or installation.
- Native SwiftUI layouts on an iPhone or iPad.
- Live Safari permissions and MAIN-world injection under Safari’s actual extension implementation.
- Native-message limits for large downloaded legacy Vue bundles.
- Real StoreKit and AdMob flows.
- A future upstream package upgrade or rollback.
- Actual component-tree inspection on every supported Vue version.

The iOS debugger skill was available when work resumed, but its XcodeBuildMCP tools were not exposed. No simulator build or launch is claimed.

## Reproduce

    npm ci --ignore-scripts
    npm test
    npm run check
    npx playwright install chromium
    npm run test:browser

To point the smoke test at another installed Chromium executable:

    DEVTOOLS_BROWSER_PATH=/absolute/path/to/chromium npm run test:browser

For native validation on a Mac:

    xcodebuild -project DevTools.xcodeproj -scheme DevTools \
      -configuration Debug -destination 'generic/platform=iOS Simulator' \
      CODE_SIGNING_ALLOWED=NO build

Then run on a signed device. Safari and share extensions must be verified from Safari itself.

## Suggested device acceptance run

1. Grant All Websites access. Confirm injection with airplane mode enabled after installation.
2. Add a domain to a selected blacklist from the share action. Confirm the console disappears.
3. Disable run-everywhere. Confirm unmatched pages stay untouched, then add an AllowList rule.
4. Select multiple lists, disable individual rules, delete a list, and test blacklist priority.
5. Exercise exact URL queries, subdomains, wildcard schemes and regex validation/timeouts.
6. Hide, Show, Disable and Enable through both the popup and share actions.
7. Revoke website permission. Confirm DevTools cannot override Safari’s permission.
8. Purchase each test product separately; restore, expire/refund, and verify plugin access and ad removal.
9. Test consent, ad no-fill, app-open presentation, completed rule edits and the three-minute eligibility boundary.
10. Toggle automatic updates; exercise offline checks, downloaded-cache clearing and Release’s bundle-only execution.
11. Open a Vue development app, a production Vue app, a strict-CSP site and a resource-heavy page. Inspect console logs and memory use.
