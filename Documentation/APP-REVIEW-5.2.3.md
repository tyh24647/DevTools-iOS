# Guideline 5.2.3 repair and draft review notes

## Verified rejection

The rejected submission was **DevTools iOS 1.0.0 (1)**. Apple cited **Guideline 5.2.3 — Audio/Video Downloading** and stated:

> The app allows users to save or download music, video, or other media content without authorization from the relevant third-party sources.

The retrieved message did not identify a particular website/provider or reproduction sequence. This document does not attribute the rejection to a named service.

Apple's [5.2.3 guideline](https://developer.apple.com/app-store/review/guidelines/#intellectual-property) requires authorization for the covered third-party media use; its [review-information guidance](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review) describes evidence of rights/permission. The repair changes the app's supplied functionality. It does not rely on a user checkbox or on moving the same supplied downloader to a separate script.

## Observed TestFlight metadata

A read-only App Store Connect check during this repair found that build 1's **What to Test** still asks testers to detect video/HLS streams they have permission to download and open saved media in **Downloads**. Those instructions describe the removed functionality and need replacement for build 2.

The app-level **Beta App Description** currently reads “Test build of the iOS DevTools Browser + Safari Extension + Media toolkit”. **Review Notes** is empty, and sign-in is marked as not required. No fields were changed and no review message was sent.

## Candidate changes

**Target: version 1.0.0, build 2.** Signing, upload, device verification, and App Review approval are pending. No message in this document has been sent.

Verified **2026-11-10**: code commit `72b32b8bdc0d7c19d89183c7043c8f8379fd83e2` passed [CI run 42881231065](https://github.com/tyh24647/DevTools-iOS/actions/runs/42881231065), including browser/Swift tests, simulator build/static analysis, and unsigned Release device compilation. Both packaged products were inspected; this does not establish simulator UI launch, device behavior, or Photos-permission handling. See [TESTING.md](TESTING.md) for the exact scope.

Removed from the candidate's active app/extension paths:

- Built-in website video download controls and the media discovery/saving panel.
- Native remote-media acquisition, HLS segment recording, MSE/MediaStream capture integration, and interrupted-recording recovery.
- Dedicated browser-to-native media acquisition messages and Safari media-download handoff.
- Media-download deep-link handling/registration and the FFmpeg acquisition/remux dependency.

Retained:

- In-app browsing, Eruda, page inspection/debugging, and the Safari debugger extension.
- The six existing list/show/hide/enable/disable share actions.
- Generic user scripts and Eruda panels, imported from local JavaScript or a user-entered script URL into a reviewable editor, with explicit enablement.
- Files import, local playback/preview, local conversion to a separate copy, file organization/sharing, and supported Photos export.

The local conversion/playback asset path uses file URLs and forbids external references. The generic script host has no app-supplied native media acquisition API. It still runs ordinary page JavaScript; do not claim that all network activity or every conceivable user-written download script is blocked.

## Draft message to App Review

**Draft only. Confirm the signed build matches these statements before sending.**

```text
Hello App Review,

We have revised DevTools iOS in response to the Guideline 5.2.3 issue reported for version 1.0.0 (1).

In version 1.0.0 (2), we removed the built-in website-media downloading and recording features, including the browser video download controls, media extraction panel, remote/HLS capture, Safari media handoff, and dedicated native media-acquisition bridge and deep-link routes.

The Media files tab now starts from documents that the user explicitly selects through the system Files picker. Its functions are local playback/preview, file organization, conversion to a separate local copy, sharing, and supported image/video export to Photos. Conversion preserves the original file and rejects non-file source URLs and external media references.

DevTools remains a browser development tool. Its generic Plugins feature allows users to import or edit JavaScript and Eruda panels. URL imports are read into the source editor for review; imported scripts remain disabled until the user enables them. These scripts run on matching pages in the in-app browser. We do not include a replacement media-downloader script or expose the removed native media-acquisition API to scripts.

The bundled developer-tool package updater uses packaged code in Release; optional package version checks are separate from the explicit user-script importer.

The review steps below identify the retained browser, script, and local-file features. Please let us know if you need further details about any remaining behavior.

Thank you.
```

## Draft build 2 What to Test

**Draft only; not saved to App Store Connect. Confirm the signed build and tap paths before using.**

```text
DevTools 1.0.0 (2) removes the built-in website-media downloading and recording features. Please test the retained browser debugging, generic scripts, and local-file tools:

1. Browser: open https://example.com, open the Page and developer tools menu beside the address field, and choose Show console. Check navigation and the Eruda console/inspection tools.

2. Safari extension: enable DevTools in Safari's extension settings, grant access to your test site, and check the console and extension controls.

3. Plugins: create a New userscript, review its source, and save it. Confirm it starts disabled, then enable it and reload the matching page in the in-app browser. Also test Import local JavaScript and Import JavaScript URL > Read for review. Imported code should open in the editor and require explicit enablement; changing its source should disable it again.

4. Media files: choose Import from Files and select a small audio/video/image file you created. Check supported playback/preview, folders, Rename, Move, Share, and Delete.

5. Long-press a supported audio/video file, choose Convert a copy, select the container, video codec, and destination folder, then Convert. Check the output and confirm the original is preserved. Report unsupported-format errors or conversion failures.

6. Long-press a supported image/video and choose Save to Photos. Check both allowing and declining Photos access.

No app sign-in is required for these flows. Please include your device, iOS version, reproduction steps, and any error message in feedback.
```

## Optional draft Beta App Description

**Draft only; not saved to App Store Connect.**

```text
DevTools combines an in-app browser and Safari extension for web debugging with Eruda and page inspection tools. In the app, review, import, and explicitly enable your own JavaScript scripts and Eruda panels. Import documents through Files for supported local media playback, organization, conversion to a separate copy, sharing, and image/video export to Photos.
```

## Draft reviewer tap paths

These labels were checked against the candidate source. The sequence still requires verification on the signed build before submission. No user account is implemented for these core flows; website accounts, if needed for a chosen site, are separate.

### Browser debugging

1. Open **Browser** and enter `https://example.com` in **Search or enter website**.
2. Open the text-format menu beside the address field, labeled **Page and developer tools** for accessibility.
3. Choose **Show console**. Inspect the Eruda console/elements/resources tabs. **Hide console** is in the same menu.
4. To test the Safari extension, enable **Settings → Apps → Safari → Extensions → ⚙︎ DevTools**, grant access for the test site, then reload it in Safari. Use the extension popup or the floating console control.

Safari's system permission presentation can vary with OS/profile settings. Verify its displayed extension name and prompts on the review device.

### Generic JavaScript import and explicit enablement

1. Open **Plugins → + → New userscript**. The supplied template matches `https://example.com/*` and logs `DevTools userscript`.
2. Review the source and tap **Save**. Its switch remains off.
3. Enable the switch, return to **Browser**, and reload `https://example.com`. Open the console to inspect the log.
4. For a local source file, use **Plugins → + → Import local JavaScript**. For a source URL, use **Import JavaScript URL → Read for review**, then review, save, and enable it.
5. Change the saved script's source or kind and save it; the switch becomes disabled again until explicitly enabled.

The reviewer may use their own harmless script. No externally hosted demo-script URL is supplied or required by this document. This script library runs in the in-app browser, not automatically in Safari.

### Local media import, conversion, and export

Prepare a small video or image created by the tester in Files; this document does not claim to bundle media fixtures.

1. Open **Media files → Import from Files** and select the file.
2. Tap a supported audio/video row for playback. Use the sliders button, **Media settings → Open videos**, to choose a video-preview mode.
3. Long-press a supported audio/video file and select **Convert a copy**. In **Convert media**, choose **Container**, **Video codec**, and **Folder**, then **Convert**. Verify that the original remains.
4. Long-press a supported image/video and select **Save to Photos**. Test the system permission prompt. **Share** exports the local file through the system share sheet.

## Submission evidence to record

The tested code commit and successful CI run are recorded above; [RELEASE.md](RELEASE.md) links the inspected unsigned artifacts. Still record the signed archive version/build, physical-device/OS checks, and App Store Connect processing/review status when completed. Attach a screen recording only after it has actually been captured from that build. Replace the old download-oriented testing instructions with the build 2 draft above when preparing the new build, and check the beta description and screenshots against the actual candidate.

Implementation references: [browser controller](../Browser/BrowserController.swift), [Safari injection](../SafariExtension/Resources/background.js), [script import UI](../Plugins/PluginsView.swift), [script enablement](../Plugins/PluginLibrary.swift), [local media UI](../Media/DownloadsView.swift), [local exporter](../Media/MediaExporter.swift), and [validation record](TESTING.md).
