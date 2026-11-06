import SwiftUI
import QuickLook
import AVKit
import Observation

private enum DownloadPreviewMode: String, CaseIterable {
    case fullscreen, inline, pictureInPicture

    var title: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .inline: "Above the file"
        case .pictureInPicture: "Picture in Picture"
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var media: MediaLibrary
    @AppStorage("download-preview-mode-v1") private var previewMode = DownloadPreviewMode.fullscreen
    var relative = ""
    @State private var preview: URL?
    @State private var playback: DownloadPlayback?
    @State private var fullscreen = false
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var deleting: URL?
    @State private var renaming: URL?
    @State private var renamedName = ""
    @State private var moving: DownloadMove?

    var body: some View {
        List {
            if relative.isEmpty {
                Section("Transfers") {
                    ForEach(media.transfers) { transfer in
                        TransferRow(transfer: transfer)
                    }
                    if media.transfers.isEmpty {
                        Text("Use the download button over a video or in Eruda's Media panel.").foregroundStyle(.secondary)
                    }
                    Button("Retry retained recordings") { media.retryRecovery() }
                }
            }
            Section(relative.isEmpty ? "Saved media" : "Files") {
                ForEach(media.files(in: relative), id: \.self) { file in
                    if isFolder(file) {
                        NavigationLink {
                            DownloadsView(relative: relativePath(for: file))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 38)).foregroundStyle(.blue)
                                    .frame(width: 72, height: 54)
                                Text(file.lastPathComponent)
                            }
                        }
                        .contextMenu { fileActions(file) }
                        .swipeActions { Button("Delete", role: .destructive) { deleting = file } }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            if let playback, playback.url == file, !fullscreen {
                                DownloadInlinePreview(playback: playback, close: closePlayback)
                            }
                            Button { open(file) } label: {
                                HStack(spacing: 12) {
                                    DownloadThumbnail(file: file)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.lastPathComponent).lineLimit(2).foregroundStyle(.primary)
                                        Text(fileDetails(file)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if MediaThumbnailCache.isVideo(file) {
                                        Image(systemName: "play.circle").foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { fileActions(file) }
                            .accessibilityIdentifier("download-file-" + file.lastPathComponent)
                        }
                        .padding(.vertical, 4)
                        .swipeActions { Button("Delete", role: .destructive) { deleting = file } }
                    }
                }
                if media.files(in: relative).isEmpty {
                    ContentUnavailableView("No saved files", systemImage: "folder", description: Text("Downloaded files and folders appear here."))
                }
            }
        }
        .navigationTitle(relative.isEmpty ? "Downloads" : URL(fileURLWithPath: relative).lastPathComponent)
        .toolbar {
            Button("New folder", systemImage: "folder.badge.plus") { creatingFolder = true }
            NavigationLink { MediaSettingsView() } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Media settings")
        }
        .quickLookPreview($preview)
        .fullScreenCover(isPresented: $fullscreen, onDismiss: closePlayback) {
            if let playback {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    VideoPlayer(player: playback.player).ignoresSafeArea()
                    if let message = playback.message {
                        Text(message).foregroundStyle(.white).padding().frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    Button { fullscreen = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle)
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .padding().accessibilityLabel("Close preview")
                }
            }
        }
        .sheet(item: $moving) { item in
            DownloadMoveView(file: item.url)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("File name", text: $renamedName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") {
                guard let file = renaming else { return }
                closePlayback()
                do { try media.relocate(file, to: relative, name: renamedName) }
                catch { media.notice = error.localizedDescription }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Include the file extension when renaming a file.") }
        .alert("Create folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $newName)
            Button("Create") {
                do { try media.createFolder(newName, in: relative); newName = "" }
                catch { media.notice = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.lastPathComponent ?? "file")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting {
                    closePlayback()
                    do { try media.delete(deleting) }
                    catch { media.notice = error.localizedDescription }
                }
                deleting = nil
            }
        }
        .onDisappear {
            if !fullscreen && playback?.pipActive != true { closePlayback() }
        }
    }

    private func isFolder(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func relativePath(for file: URL) -> String {
        relative.isEmpty ? file.lastPathComponent : relative + "/" + file.lastPathComponent
    }

    private func fileDetails(_ file: URL) -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return file.pathExtension.uppercased() + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    @ViewBuilder private func fileActions(_ file: URL) -> some View {
        Button("Rename", systemImage: "pencil") { renamedName = file.lastPathComponent; renaming = file }
        Button("Move", systemImage: "folder") { closePlayback(); moving = DownloadMove(url: file) }
        ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
        if ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "heic"].contains(file.pathExtension.lowercased()), !isFolder(file) {
            Button("Save to Photos", systemImage: "photo") { Task { await media.saveToPhotos(file) } }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = file }
    }

    private func open(_ file: URL) {
        closePlayback()
        guard MediaThumbnailCache.isVideo(file) else { preview = file; return }
        playback = DownloadPlayback(url: file, wantsPiP: previewMode == .pictureInPicture,
                                    restore: { [weak media] in media?.onPreviewRestore?() })
        fullscreen = previewMode == .fullscreen
        playback?.player.play()
    }

    private func closePlayback() {
        playback?.close()
        playback = nil
    }
}

private struct DownloadThumbnail: View {
    let file: URL
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: MediaThumbnailCache.isVideo(file) ? "film" : "doc.fill")
                    .font(.title).foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 54)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: file) { data = await MediaThumbnailCache.shared.thumbnail(for: file) }
    }
}

private struct DownloadMove: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct DownloadMoveView: View {
    let file: URL
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    Picker("Folder", selection: $destination) {
                        ForEach(media.destinationFolders(excluding: file), id: \.self) { folder in
                            Text(folder.isEmpty ? "Downloads" : folder).tag(folder)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Move \(file.lastPathComponent)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        do { try media.relocate(file, to: destination); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

private struct TransferRow: View {
    @EnvironmentObject private var media: MediaLibrary
    @ObservedObject var transfer: MediaTransfer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let data = transfer.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 72, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                Text(transfer.source.title).font(.headline)
            }
            Text(transfer.state).font(.caption)
            Text("\(ByteCountFormatter.string(fromByteCount: transfer.bytes, countStyle: .file)) · \(Int(transfer.duration))s captured")
                .font(.caption).monospacedDigit()
            if let progress = transfer.progress { ProgressView(value: progress) }
            if !transfer.captureEnded {
                Button(transfer.live ? "Stop and finalize" : "Stop") { media.stop(transfer) }
            }
            if let error = transfer.error { Text(error).font(.caption).foregroundStyle(.red) }
            ForEach(transfer.outputs, id: \.self) { output in ShareLink(item: output) { Text(output.lastPathComponent) } }
        }
        .padding(.vertical, 4)
    }
}

struct MediaSettingsView: View {
    @AppStorage("download-preview-mode-v1") private var previewMode = DownloadPreviewMode.fullscreen
    @EnvironmentObject private var media: MediaLibrary
    var body: some View {
        Form {
            Section("Video previews") {
                Picker("Open videos", selection: $previewMode) {
                    ForEach(DownloadPreviewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Inline previews make room above the selected file. Picture in Picture opens a floating player when supported; otherwise the inline player remains available.")
                    .font(.caption)
            }
            Section("Output") {
                Picker("Container", selection: $media.settings.container) {
                    ForEach(MediaSettings.Container.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                Picker("Video codec", selection: $media.settings.codec) {
                    Text("Keep original (fast)").tag(MediaSettings.Codec.copy)
                    Text("H.264").tag(MediaSettings.Codec.h264)
                    Text("HEVC").tag(MediaSettings.Codec.hevc)
                }
                Text("HEVC is a codec inside MP4 or MOV. Encoding can take longer and needs additional free storage. Unsupported track formats retain the capture for recovery.")
                    .font(.caption)
            }
            Section("Recording") {
                Stepper("File limit: \(media.settings.partLimitMB) MiB", value: $media.settings.partLimitMB, in: 128...8192, step: 128)
                Toggle("Split live HLS and continue", isOn: $media.settings.splitAndContinue)
                Toggle("Stop HLS when source leaves", isOn: $media.settings.stopOnSourceLeave)
                Toggle("Choose HLS quality before downloading", isOn: $media.settings.showQuality)
                Text("HLS parts close after complete video/audio segments, so the limit can be exceeded by a segment. Buffer captures stop at the limit. Closing their tab always stops them. On backgrounding, live recording stops and iOS grants limited time to finalize; retained checkpoints are recovered on reopening. Recording does not continue indefinitely while suspended.")
                    .font(.caption)
            }
            Section("Files") {
                TextField("Default folder (relative path)", text: $media.settings.defaultFolder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Show hidden files", isOn: $media.settings.showHiddenFiles)
                Text("Create the folder in Downloads first. Export through Share to save in Files.").font(.caption)
            }
        }
        .navigationTitle("Media settings")
    }
}


struct SaveMediaView: View {
    let source: PageMedia
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var browser: BrowserController
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [MediaChoice] = []
    @State private var selectedID = ""
    @State private var cookies: [HTTPCookie] = []
    @State private var userAgent = ""
    @State private var loading = true
    @State private var error: String?
    @State private var attempt = 0

    private var selectedChoice: MediaChoice? {
        choices.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    Text(source.title.isEmpty ? "Page media" : source.title)
                    if loading {
                        ProgressView("Loading media…")
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { attempt += 1 }
                    } else if source.isBlob {
                        Text("Record from now while this page plays. Stop in Downloads to finalize the file. Live streams include only the audio/video tracks exposed by the player.")
                    } else if media.settings.showQuality && choices.count > 1 {
                        Picker("Quality", selection: $selectedID) {
                            ForEach(choices) { choice in
                                Text(choice.label).tag(choice.id)
                            }
                        }
                    } else if let selectedChoice {
                        Text(selectedChoice.label)
                    }
                }
                Section("Save to") {
                    Text(media.settings.defaultFolder.isEmpty ? "Downloads" : media.settings.defaultFolder)
                    NavigationLink("Media settings") { MediaSettingsView() }
                }
                Section {
                    Button(source.isBlob || selectedChoice?.live == true ? "Start recording" : "Save media") {
                        media.start(source, choice: selectedChoice, cookies: cookies, userAgent: userAgent)
                        dismiss()
                    }
                    .disabled(loading || error != nil || (!source.isBlob && selectedChoice == nil))
                    .accessibilityIdentifier("save-media-start")
                }
            }
            .navigationTitle("Save Media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: attempt) { await load() }
        }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        do {
            guard let tab = browser.tabs.first(where: { $0.id == source.tabID }) else {
                throw MediaFailure.invalid("The source tab was closed. Open the page and select the media again.")
            }
            userAgent = try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
            cookies = await tab.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            try Task.checkCancellation()
            choices = try await media.choices(source, cookies: cookies, userAgent: userAgent)
            try Task.checkCancellation()
            guard source.isBlob || !choices.isEmpty else {
                throw MediaFailure.invalid("No supported media source was found.")
            }
            selectedID = choices.first?.id ?? ""
            loading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }
}

@MainActor @Observable
private final class DownloadPlayback: NSObject, @MainActor AVPictureInPictureControllerDelegate {
    let url: URL
    let player: AVPlayer
    var wantsPiP: Bool
    var pipActive = false
    var message: String?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var requested = false
    private let restore: () -> Void
    private var timeout: Task<Void, Never>?

    init(url: URL, wantsPiP: Bool, restore: @escaping () -> Void) {
        self.url = url
        self.player = AVPlayer(url: url)
        self.wantsPiP = wantsPiP
        self.restore = restore
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            message = error.localizedDescription
        }
        itemObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                if failed { self?.message = "This video could not be played. You can still share the original file." }
            }
        }
    }

    func attach(_ layer: AVPlayerLayer) {
        guard controller == nil, wantsPiP else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let pip = AVPictureInPictureController(playerLayer: layer) else {
            message = "Picture in Picture is unavailable on this device. Use the player below."
            return
        }
        controller = pip
        pip.delegate = self
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, possible, !self.requested else { return }
                self.requested = true
                self.controller?.startPictureInPicture()
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.pipActive else { return }
            self.message = "Picture in Picture could not start. Use the inline player or tap the PiP button to retry."
        }
    }

    func startPiP() {
        guard controller?.isPictureInPicturePossible == true else {
            message = "Picture in Picture is not ready. Start playback and try again."
            return
        }
        message = nil
        controller?.startPictureInPicture()
    }

    func close() {
        timeout?.cancel()
        possibleObservation = nil
        itemObservation = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipActive = true
        message = nil
        timeout?.cancel()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipActive = false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        message = "Picture in Picture could not start: \(error.localizedDescription)"
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restore()
        completionHandler(true)
    }
}

private struct DownloadInlinePreview: View {
    let playback: DownloadPlayback
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }
            if playback.wantsPiP {
                DownloadPiPLayer(playback: playback)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button("Back 15 seconds", systemImage: "gobackward.15") { seek(-15) }
                    Button("Play", systemImage: "play.fill") { playback.player.play() }
                    Button("Pause", systemImage: "pause.fill") { playback.player.pause() }
                    Button("Forward 15 seconds", systemImage: "goforward.15") { seek(15) }
                    Spacer()
                    Button("Picture in Picture", systemImage: "pip.enter") { playback.startPiP() }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            } else {
                VideoPlayer(player: playback.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let message = playback.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func seek(_ offset: Double) {
        let seconds = playback.player.currentTime().seconds
        guard seconds.isFinite else { return }
        playback.player.seek(to: CMTime(seconds: max(0, seconds + offset), preferredTimescale: 600))
    }
}

private final class DownloadPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}

private struct DownloadPiPLayer: UIViewRepresentable {
    let playback: DownloadPlayback

    func makeUIView(context: Context) -> DownloadPlayerLayerView {
        let view = DownloadPlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer?.player = playback.player
        view.playerLayer?.videoGravity = .resizeAspect
        if let layer = view.playerLayer { playback.attach(layer) }
        return view
    }

    func updateUIView(_ uiView: DownloadPlayerLayerView, context: Context) {
        uiView.playerLayer?.player = playback.player
        if let layer = uiView.playerLayer { playback.attach(layer) }
    }
}
