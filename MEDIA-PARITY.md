# Local media and browser behavior

## Review candidate 1.0.0 (2)

This document describes the current review candidate. The earlier Android-parity capture implementation is historical and is no longer the behavior shipped by this branch. Build 1 was rejected under Guideline 5.2.3; the source changes and draft reviewer response are recorded in [APP-REVIEW-5.2.3.md](Documentation/APP-REVIEW-5.2.3.md).

| Area | Current behavior |
| --- | --- |
| Browser | Tabbed WKWebView browsing, Eruda, page options, cookie tools, and generic user scripts |
| Safari | Existing debugger extension and six configuration/show/hide share actions |
| Media input | Documents explicitly selected through the Files picker |
| Playback | Supported local audio/video playback and previews |
| Conversion | A separate local MP4 or MOV copy using AVFoundation, subject to source/device support |
| Export | Share/Files export and supported image/video export to Photos |
| Website-media acquisition | Built-in download buttons, media discovery/saving panels, HLS acquisition, and page-stream recording removed |
| Browser-to-media handoff | Dedicated native media messages and media-download deep links removed |

## Import, play, and organize

1. Open the **Media files** tab.
2. Tap **Import from Files** and select one or more documents. Import places them in the currently open folder.
3. Tap an imported audio/video row to play a supported file. Images and other supported documents use the available preview path.
4. Long-press a file for **Rename**, **Move**, **Share**, or **Delete**. Use **New folder** to organize files.

The system Files picker can provide local documents or documents from configured file providers. Import copies selected document bytes into the app's library. There is no media-URL input in this workflow.

Video preview preferences are in **Media files → Media settings** (the sliders button), or **Settings → Media settings → Open videos**. Available choices are **Fullscreen**, **Above the file**, and **Picture in Picture**. PiP requires device/OS support and may fall back to the inline player. Physical-device behavior remains a release validation step.

## Convert a copy

1. Long-press a supported audio/video file and choose **Convert a copy**.
2. In **Convert media**, choose **Container**, **Video codec**, and **Folder**.
3. Tap **Convert**.

The container choices are MP4 and MOV. The codec choices are **Keep original (fast)**, **H.264**, and **HEVC**. The selected combination must be supported by AVFoundation for the input and device. An unsupported combination reports an error; the original stays available for playback or sharing. Conversion needs additional free storage and always creates a separate output.

The conversion boundary accepts file URLs only. Local AVFoundation assets forbid external references, so an imported reference movie is not a route to fetch another media resource. File import uses coordinated, security-scoped document access and bounded copying. The removed HLS recorder, capture recovery engine, FFmpeg remux bridge, and remote-transfer state are not part of this candidate.

## Save to Photos

Long-press a supported image or video and choose **Save to Photos**. Allow the requested Photos access when iOS asks. Audio and unsupported formats can still use **Share**. Verify both permission acceptance and denial on a physical device before submission.

## Generic scripts remain available

Open **Plugins → + → Import local JavaScript**, or **Import JavaScript URL → Read for review**. Review/edit the source, save it, and enable its switch. Imported scripts initially remain disabled. They execute on matching pages in the in-app browser; this library is not installed into Safari automatically.

This generic development feature does not provide the former native media downloader/recorder API, and this candidate does not package a replacement media-downloader script. Ordinary page JavaScript capabilities remain available; this is not a claim that every user-authored script is approved by Apple.

The `DEVTOOLS_REMOTE_UPDATES` flag governs replacement packages for the bundled developer tools. Release uses the bundled packages while optionally checking their versions. That flag does not disable the separate generic script importer.

## Build and validation

The active app uses the root Swift files and the **DevTools** scheme in `DevTools.xcodeproj`. Xcode with the iOS 27 SDK is required. The project retains the app, Safari extension, and six action extensions; the FFmpeg package dependency has been removed.

```bash
bash Scripts/build-ios.sh
bash Scripts/build-release.sh
```

These commands produce a Debug simulator ZIP and an unsigned Release device ZIP. Neither establishes a signed TestFlight upload. Full logs are written under `Build/Logs/`.

Verified 2026-11-10: code commit `72b32b8bdc0d7c19d89183c7043c8f8379fd83e2` passed [CI run 42881231065](https://github.com/tyh24647/DevTools-iOS/actions/runs/42881231065), including 11 Swift helper tests, both browser smoke suites, the Debug simulator build/analysis, and unsigned Release device compilation. The two ZIPs were inspected for versions, extensions, retained scripts, and removed resources. This confirms packaged contents; simulator UI launch, device/Photos-permission behavior, signing, upload, and approval remain unverified or pending. See [TESTING.md](Documentation/TESTING.md) and [RELEASE.md](Documentation/RELEASE.md).
