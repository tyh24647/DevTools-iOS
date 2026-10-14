# Signing and release configuration

This project has not been submitted to Apple. It is not a guarantee of App Review approval.

## Identifiers

The containing app defaults to com.tyh24647.DevTools. Child targets append:

- .Safari
- .AddBlacklist
- .AddAllowList
- .Show
- .Hide
- .Enable
- .Disable

Every target needs the same registered App Group, group.com.tyh24647.DevTools, or the replacement chosen in Developer.xcconfig. Select a development team that supports App Groups. Provision all eight bundle identifiers and inspect the generated entitlements before archiving. A missing App Group produces a visible error rather than silently restoring run-everywhere defaults.

If you change the main identifier, also update the product IDs in PurchaseStore.swift, the local StoreKit file, and the background script’s native application identifier. Safari ignores the native application identifier on iOS, but keeping these values consistent avoids future portability errors.

## StoreKit

Create the monthly auto-renewable subscription and lifetime non-consumable in App Store Connect with the IDs in README.md. Put the monthly product in a subscription group. Set the desired US base prices to $2.99/month and $19.99 lifetime; local tax and storefront pricing are controlled by Apple.

Provide product names, descriptions, review screenshots and review notes. Verify purchase, cancellation, restore, pending approval, refund, expiry, and buying lifetime while a monthly subscription exists. The UI warns that lifetime does not cancel the existing subscription. The local StoreKit scheme is for development only and must not be mistaken for a real purchase.

The app caches verified entitlement results for extension use. Expiry is checked when Safari reads the snapshot; other entitlement changes are refreshed when the containing app receives StoreKit updates or returns to the foreground. No server-side subscription service is included.

## Advertising

Replace the sample AdMob app ID and banner/interstitial/app-open unit IDs. Register the app with AdMob, configure applicable privacy messages in Privacy & Messaging, and verify the UMP flow with consent required, declined, unavailable and previously granted.

Update the SKAdNetwork identifiers according to Google's current integration guide and any mediation partners you actually configure. The project includes Google’s primary identifier and no mediation setup. Respect the app’s final age rating and configure ad content rating in your account.

The project uses non-personalized requests and does not request IDFA access. Review the SDK’s actual data collection and your configuration when completing App Store privacy disclosures. SDK manifests do not substitute for accurate App Store Connect answers. PrivacyInfo.xcprivacy describes this app’s own direct API/data use; the SDKs supply their own manifests.

Publish a privacy policy on a URL you control and configure that URL in App Store Connect. The app already contains a readable privacy screen and a Google privacy link.

Ads are only linked into the app target. Do not link the SDK into extension targets or inject ads into inspected webpages. Full-screen ads are closeable SDK formats and are scheduled at completed interactions, with timing and readiness guards.

## Executable updates

Archive the Release configuration. It does not define DEVTOOLS_REMOTE_UPDATES. It only executes packaged JavaScript and reports available npm versions for the next app release.

The personal-development Debug path for downloaded package execution is explicit in source and in the Packages UI. Do not claim unrestricted remote feature updates are approved for App Store distribution. Review Apple’s downloaded-code rules and discuss your actual distribution model with App Review if needed.

## Device checks still required

Build and run on a physical iPhone. Test the extension from Safari, including private browsing permissions where applicable, all six share actions, background/foreground cycles, popup sender authorization, website permission revocation, strict CSP, Vue production/development pages, and cross-origin frames. Also test iPad layout if distributing as a universal app.

Use Product → Archive after these checks. This deliverable contains no signing certificate, provisioning profile, production ad identifiers or App Store Connect credentials.
