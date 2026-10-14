import SwiftUI
import QuickLook

struct DownloadsView: View {
    @EnvironmentObject private var media: MediaLibrary
    var relative = ""
    @State private var preview: URL?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var deleting: URL?
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
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        NavigationLink {
                            DownloadsView(relative: relative.isEmpty ? file.lastPathComponent : relative + "/" + file.lastPathComponent)
                        } label: { Label(file.lastPathComponent, systemImage: "folder") }
                        .swipeActions { Button("Delete", role: .destructive) { deleting = file } }
                    } else {
                        VStack(alignment: .leading) {
                            Button(file.lastPathComponent) { preview = file }
                            HStack {
                                ShareLink(item: file)
                                if ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "heic"].contains(file.pathExtension.lowercased()) {
                                    Button("Save to Photos") {
                                        Task {
                                            await media.saveToPhotos(file)
                                        }
                                    }
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { deleting = file } }
                    }
                }
            }
        }
        .id(media.revision)
        .navigationTitle(relative.isEmpty ? "Downloads" : URL(fileURLWithPath: relative).lastPathComponent)
        .toolbar {
            Button("New folder", systemImage: "folder.badge.plus") { creatingFolder = true }
            NavigationLink { MediaSettingsView() } label: { Image(systemName: "slider.horizontal.3") }
        }
        .quickLookPreview($preview)
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
                    do { try media.delete(deleting) }
                    catch { media.notice = error.localizedDescription }
                }
                deleting = nil
            }
        }
    }
}

private struct TransferRow: View {
    @EnvironmentObject private var media: MediaLibrary
    @ObservedObject var transfer: MediaTransfer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transfer.source.title).font(.headline)
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
    @EnvironmentObject private var media: MediaLibrary
    var body: some View {
        Form {
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
