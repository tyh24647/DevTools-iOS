# iOS media and browser update

This update is based on the supplied `DevTools-Android-main.zip` and iOS commit `3b14d784c8b2c653d71e153b8fe538be81528d65`. It adds a native WKWebView browser to the existing Safari extension app. Open the **DevTools** app target in `DevTools.xcodeproj`; the root Swift files are authoritative. The old `App/` copies are not the app target's source.

## Available controls

Open a website in **Browser**. A download button appears over discovered videos; Eruda's Resources panel includes media previews and saving controls. Confirm the source in the native save dialog. Enable quality selection in Media settings to choose an HLS variant; otherwise the highest advertised resolution/bandwidth is selected.

For a live HLS stream, Download starts recording complete new segments without needing a final duration. **Stop and finalize**, an ended/unloaded video, a removed video element, navigation, or closing its tab normally stops recording and creates a movie from completed segments. **Stop HLS when source leaves** can be disabled to keep a native HLS transfer running after leaving its page. Buffer captures depend on the page and always stop when its tab closes.

Choose MP4 or MOV and original codecs, H.264, or HEVC in **Media settings**. HEVC is a video codec inside a container, not a separate file format. Original codecs are fastest. Apple export availability depends on the device and captured track codecs. Non-MP4-compatible codecs can fail at the intermediate MP4 remux stage even if Apple could encode them; those captures remain available for recovery.

Set a 128–8192 MiB size limit. Live HLS can split and continue; each part ends after complete track segments, so the threshold is approximate. Conversion of a completed part runs separately while capture continues. MP4/WebM buffer recordings stop at the limit, because arbitrary byte offsets are not safe split points. Keep sufficient storage for both capture and conversion; a 512 MiB reserve stops further capture when space becomes low. Export can need considerably more space.

**Downloads** supports folders, playback/Quick Look preview, Share/Files export, and Save to Photos. Failed/interrupted HLS and buffer captures retain checkpoints and received data. Reopening the app tries to finalize them; **Retry retained recordings** retries failures. Captures live in the app's `.DevTools Captures` directory, also accessible through Files/iTunes file sharing. Saved outputs live in `DevTools Media`. Do not edit checkpoint files while recording.

## Android comparison

| Feature in supplied Android source | iOS behavior in this update |
|---|---|
| Tabbed native browser and independent rules | WKWebView browser, up to twelve tabs, separate AllowLists/blacklists |
| HLS download, variant selection, separate audio | Native segment downloads and local MP4 remux; audio playlists included |
| Unknown-duration livestream capture | Incremental segment checkpoints; stop/source close finalization |
| Resource/media/image preview and saving | Browser discovery plus Downloads preview, Share and Photos |
| Custom Eruda panels and userscripts | Import/edit, folders/tags, compile/metadata validation, explicit enable |
| CSS editor and source formatting | Bundled Android CSS panel, formatter, and CodeMirror editor |
| Firefox companion | Existing Safari extension preserved; HTTP video handoff opens the app's save dialog |
| MP4 remux | Added MOV/H.264/HEVC export settings and optional live HLS file rollover |

The Android source does not contain a general WebSocket-to-video converter. This update observes **MediaSource/SourceBuffer** MP4/WebM bytes, which can support socket-fed players that expose valid media through MSE. It captures a bounded initialization header and recent chunks, then writes acknowledged buffers to disk. Availability, codec compatibility, and a decodable starting keyframe depend on the player. Live video players exposing a `MediaStream` (including Agora/WebRTC) can now be recorded with `MediaRecorder` after enabling buffer recording in Page tools and reloading. Recording begins when requested; MP4 is preferred, with WebM used only if supported. Audio is included only when it is part of that same stream; a video-only stream creates a silent recording. Stop waits for the final recorder data before export and leaves the player tracks running. Incoming data is bounded to a 16 MiB queue and acknowledged in 256 KiB chunks. Browser/encoder availability is checked at runtime; unsupported streams report an error. Arbitrary WebSocket payloads, worker-owned media sources, DRM/SAMPLE-AES, and changing stream formats are unsupported. AES-128 identity HLS is supported; key and initialization requirements are validated.

Safari's extension cannot run the app's native recorder continuously in its page. Its video action hands an HTTP(S) URL to the native app, which asks before starting. Safari blob URLs and cookies cannot be transferred; open authenticated sites and sign in inside DevTools first. HTTP URLs without an HLS extension require the native browser's MIME-based discovery to classify them correctly.

iOS suspends apps: backgrounding stops live capture and requests finite time to finalize. If time expires, checkpoints remain for reopening. Force-quitting or a device shutdown can lose uncommitted data. There is no promise of indefinite recording while suspended. This implementation does not add an audio/background-mode workaround.

Backend/vendor changes apply completely after reloading a tab. Existing automatic update policy is preserved: signed bundled packages in Release; the existing developer build flag permits integrity-checked cached packages. The native browser also uses that cache for new documents.

## Build and dependency

Both existing app targets have the new sources/resources and pinned Swift package product `AetherFFmpegBuild` from [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild), revision `f93e7788796eeede40bf866ed2f802b4dbfbef50`. Xcode resolves and embeds its dynamic frameworks at build time. Device installation requires no npm process, runtime compiler, or FFmpeg executable. The C bridge only handles local files; URLSession handles remote requests and browser cookie snapshots. FFmpeg is not linked into extensions.

The package uses Swift tools 6.0 and iOS 16+ frameworks. Existing project deployment/signing settings are preserved (currently iOS 27). Choose an installed compatible SDK/device deployment target in Xcode as needed. FFmpeg/LGPL notices are bundled in `Licenses/FFmpegBuild`; review redistribution/relinking obligations before distribution. Existing advertising/purchase configuration remains unchanged. No certificates or provisioning profiles are supplied.

`Scripts/patch-media-project.py` idempotently patches the current nine-target project and embeds all seven extensions. **Do not run the legacy `generate-project.py`** on this updated project: it regenerates the older layout. `npm run project` now calls the patcher.

## Validation and remaining device checks

Automated checks cover the Foundation HLS parser, JavaScript rule/runtime/MSE behavior, native bootstrap in Chromium, local C remux with TS/fMP4 stopped prefixes and separate audio, source syntax, Xcode project structure, plists, and bundled scripts. Host remux fixtures use FFmpeg 6.1; the bridge also passes syntax checking against the pinned Apple FFmpeg 8.1 headers.

**No Xcode build, simulator run, or device test was available in this environment.** Swift syntax checks do not establish Apple SDK type correctness. Before shipping, build both desired app configurations, confirm SPM embedding/signing, and test real sites, Stop/tab close/navigation, cookies/redirects, separate audio sync, AAC/HEVC output playback, size rollover, low storage, Photos/Files permissions, background expiration and recovery. Also verify the six share actions and Safari permissions on device. This is an implementation ready for Xcode validation, not a claim of fully verified Android parity.

On a Mac with the iOS 27 SDK, run `bash Scripts/build-ios.sh` to resolve packages, compile the DevTools scheme and package a simulator-only app at `Build/DevTools-iOS-Simulator.zip`. The GitHub Actions workflow runs the same check on pushes/PRs and can be started manually. A signed iPhone build still requires the developer's Xcode team and provisioning for the app, all seven extensions, and the App Group.

## Live MediaStream recording validation

The DevTools Debug app passed `xcodebuild -project DevTools.xcodeproj -scheme DevTools -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/devtools-stream-build -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO DEPLOYMENT_LOCATION=NO build`. Existing project settings redirect the product into `DerivedData/Build/Products/Debug-iphonesimulator`; the bundled capture scripts were verified against their source. All 32 JavaScript tests and `node Scripts/check.mjs` passed. A temporary macOS WKWebView harness connected two real WebRTC peers, recorded the remote video MediaStream through the video button, stopped it through the same button, flushed ordered final chunks, and verified a playable 320×180 MP4 of about 3.5 seconds with AVFoundation. The player track remained live. This validates WebKit recording behavior; the actual Agora page on an iPhone still needs testing. No usable iOS Simulator runtime was available for an app launch.
