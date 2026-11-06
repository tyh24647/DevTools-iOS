import Foundation
import Combine
import UIKit
import Photos
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class MediaLibrary: ObservableObject {
    @Published var settings: MediaSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: "media-settings-v2")
            }
        }
    }
    @Published var transfers: [MediaTransfer] = []
    @Published var pending: PageMedia?
    @Published var notice: String?
    @Published var revision = 0
    let root: URL
    let captures: URL
    var onPreviewRestore: (() -> Void)?
    var onStatus: ((MediaTransfer) -> Void)?
    var onBlobStart: ((MediaTransfer) -> Void)?
    var onBlobStop: ((MediaTransfer) -> Void)?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var recovering = Set<URL>()
    private var activeRecoveries = Set<URL>()

    init() {
        settings = UserDefaults.standard.data(forKey: "media-settings-v2").flatMap {
            try? JSONDecoder().decode(MediaSettings.self, from: $0)
        } ?? MediaSettings()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("DevTools Media", isDirectory: true)
        captures = documents.appendingPathComponent(".DevTools Captures", isDirectory: true)
        settings.partLimitMB = min(8192, max(128, settings.partLimitMB))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.backgrounded()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.recoverInterrupted()
            }
        }
    }

    func directory(_ relative: String) throws -> URL {
        var url = root
        for name in relative.split(separator: "/") {
            try MediaExporter.validateName(String(name))
            url.appendPathComponent(String(name), isDirectory: true)
        }
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") || url == root else {
            throw MediaFailure.invalid("Invalid media folder.")
        }
        return url
    }

    func files(in relative: String) -> [URL] {
        guard let folder = try? directory(relative) else {
            return []
        }
        let options: FileManager.DirectoryEnumerationOptions = settings.showHiddenFiles ? [] : [.skipsHiddenFiles]
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: options)) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func createFolder(_ name: String, in relative: String) throws {
        try MediaExporter.validateName(name)
        try FileManager.default.createDirectory(at: directory(relative).appendingPathComponent(name), withIntermediateDirectories: false)
        revision += 1
    }

    func createFile(_ name: String, in relative: String) throws {
        try MediaExporter.validateName(name)
        let file = try directory(relative).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw MediaFailure.invalid("This file already exists.")
        }
        try Data().write(to: file, options: .atomic)
        revision += 1
    }

    private func checkedLibraryItem(_ file: URL) throws -> URL {
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        let library = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(library.path + "/") else {
            throw MediaFailure.invalid("Choose a file inside Downloads.")
        }
        guard !transfers.contains(where: { transfer in
            guard !transfer.finished else { return false }
            let destination = try? directory(transfer.settings.defaultFolder).resolvingSymlinksInPath()
            return destination == resolved || destination?.path.hasPrefix(resolved.path + "/") == true ||
                transfer.outputs.contains { $0 == file || $0.path.hasPrefix(file.path + "/") }
        }) else {
            throw MediaFailure.invalid("An active transfer uses this file or folder. Stop and finalize it first.")
        }
        return resolved
    }

    func delete(_ file: URL) throws {
        _ = try checkedLibraryItem(file)
        try FileManager.default.removeItem(at: file)
        revision += 1
    }

    func relocate(_ file: URL, to relative: String, name: String? = nil) throws {
        let source = try checkedLibraryItem(file)
        let filename = name ?? file.lastPathComponent
        try MediaExporter.validateName(filename)
        let folder = try directory(relative).resolvingSymlinksInPath()
        let library = root.resolvingSymlinksInPath()
        guard (folder == library || folder.path.hasPrefix(library.path + "/")),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              folder != source, !folder.path.hasPrefix(source.path + "/") else {
            throw MediaFailure.invalid("Choose a destination folder inside Downloads, outside this item.")
        }
        let target = folder.appendingPathComponent(filename)
        if target == source { return }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MediaFailure.invalid("An item with that name already exists in this folder.")
        }
        try FileManager.default.moveItem(at: file, to: target)
        if let selectedFolder = try? directory(settings.defaultFolder),
           selectedFolder == file || selectedFolder.path.hasPrefix(file.path + "/") {
            let suffix = String(selectedFolder.path.dropFirst(file.path.count))
            settings.defaultFolder = String((target.path + suffix).dropFirst(root.path.count + 1))
        }
        // Completed transfer links follow both individual files and renamed folders.
        for transfer in transfers {
            transfer.outputs = transfer.outputs.map { output in
                if output == file { return target }
                if output.path.hasPrefix(file.path + "/") {
                    return target.appendingPathComponent(String(output.path.dropFirst(file.path.count + 1)))
                }
                return output
            }
        }
        revision += 1
    }

    func destinationFolders(excluding file: URL) -> [String] {
        var folders = [""]
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return folders }
        for case let folder as URL in enumerator {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true || folder == file || folder.path.hasPrefix(file.path + "/") {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                folders.append(String(folder.path.dropFirst(root.path.count + 1)))
            }
        }
        return folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func choices(_ source: PageMedia, cookies: [HTTPCookie], userAgent: String? = nil) async throws -> [MediaChoice] {
        guard !source.isBlob, let url = URL(string: source.url), let page = URL(string: source.page) else {
            return []
        }
        if !source.hls && url.pathExtension.lowercased() != "m3u8" {
            return [MediaChoice(video: url, audio: nil, live: false, label: "Original")]
        }
        let http = MediaHTTP(page: page, cookies: cookies, userAgent: userAgent)
        defer { http.close() }
        let list = try await http.playlist(url)
        if list.variants.isEmpty {
            return [MediaChoice(video: url, audio: nil, live: !list.ended, label: list.ended ? "Video" : "Live")]
        }
        var results: [MediaChoice] = []
        for variant in list.variants.sorted(by: { ($0.width * $0.height, $0.bandwidth) > ($1.width * $1.height, $1.bandwidth) }) {
            let media = try await http.playlist(variant.url)
            results.append(MediaChoice(video: variant.url, audio: variant.audioGroup.flatMap { list.audio[$0] }, live: !media.ended, label: variant.label))
        }
        return results
    }

    func start(_ source: PageMedia, choice: MediaChoice?, cookies: [HTTPCookie], userAgent: String? = nil) {
        var inserted: MediaTransfer?
        do {
            guard transfers.filter({ !$0.finished }).count < 2 else {
                throw MediaFailure.invalid("Finish or stop an active transfer first (two-transfer limit).")
            }
            let destination = try directory(settings.defaultFolder)
            guard (try destination.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw MediaFailure.invalid("Choose an existing default folder.")
            }
            let transfer = MediaTransfer(source: source, settings: settings)
            transfers.insert(transfer, at: 0)
            inserted = transfer
            if source.isBlob {
                transfer.live = true
                let folder = captures.appendingPathComponent(transfer.id.uuidString + "-mse")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                transfer.blobFolder = folder
                transfer.state = "Recording page media"
                onStatus?(transfer)
                onBlobStart?(transfer)
                return
            }
            guard let choice, let page = URL(string: source.page) else {
                throw MediaFailure.invalid("No supported media source was selected.")
            }
            transfer.live = choice.live
            let http = MediaHTTP(page: page, cookies: cookies, userAgent: userAgent, limit: choice.live || source.hls ? 256 * 1024 * 1024 : Int64(settings.partLimitMB) * 1024 * 1024) { [weak self, weak transfer] bytes, total in
                Task { @MainActor in
                    guard let transfer, !transfer.live, !source.hls else {
                        return
                    }
                    transfer.bytes = bytes
                    transfer.progress = total > 0 ? Double(bytes) / Double(total) : nil
                    self?.onStatus?(transfer)
                }
            }
            if source.hls || choice.video.pathExtension.lowercased() == "m3u8" {
                let recorder = HLSRecorder(http: http, choice: choice, settings: transfer.settings, root: captures, title: source.title, id: transfer.id)
                transfer.recorder = recorder
                transfer.state = transfer.live ? "Recording live segments" : "Downloading HLS"
                transfer.task = Task {
                    do {
                        try await recorder.capture(progress: { [weak self, weak transfer] bytes, duration, progress in
                            await MainActor.run {
                                guard let transfer else {
                                    return
                                }
                                transfer.bytes = bytes
                                transfer.duration = duration
                                transfer.progress = progress
                                self?.onStatus?(transfer)
                            }
                        }, ready: { [weak self, weak transfer] folder, checkpoint in
                            await MainActor.run {
                                if let transfer {
                                    self?.enqueueExport(folder, checkpoint: checkpoint, transfer: transfer)
                                }
                            }
                        }, thumbnail: { [weak transfer] data in
                            await MainActor.run { transfer?.thumbnail = data }
                        })
                    } catch {
                        transfer.error = error.localizedDescription
                    }
                    transfer.captureEnded = true
                    self.completeIfReady(transfer)
                }
            } else {
                transfer.state = "Downloading"
                transfer.task = Task {
                    defer { http.close() }
                    do {
                        let ext = self.extensionFor(source: source)
                        let target = try self.uniqueOutput(title: source.title, extension: ext, relative: transfer.settings.defaultFolder)
                        let temporary = captures.appendingPathComponent(UUID().uuidString + "." + ext)
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        let response = try await http.download(choice.video, to: temporary)
                        transfer.thumbnail = await MediaThumbnailCache.shared.thumbnail(for: temporary)
                        transfer.bytes = Int64((try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        if source.mime.hasPrefix("video/") || response.mimeType?.hasPrefix("video/") == true || ["mp4", "mov", "m4v"].contains(ext) {
                            let output = try self.uniqueOutput(title: source.title, extension: transfer.settings.container.rawValue, relative: transfer.settings.defaultFolder)
                            transfer.state = "Converting video"
                            do {
                                try await MediaExporter.convert(temporary, settings: transfer.settings, destination: output)
                                try? FileManager.default.removeItem(at: temporary)
                            } catch {
                                // Preserve the complete original in the visible library when export is unsupported.
                                let original = try self.uniqueOutput(title: source.title + " original", extension: ext, relative: transfer.settings.defaultFolder)
                                try FileManager.default.moveItem(at: temporary, to: original)
                                transfer.outputs.append(original)
                                self.revision += 1
                                throw error
                            }
                            transfer.outputs.append(output)
                        } else {
                            try FileManager.default.moveItem(at: temporary, to: target)
                            transfer.outputs.append(target)
                        }
                        self.revision += 1
                    } catch {
                        transfer.error = error.localizedDescription
                    }
                    transfer.captureEnded = true
                    self.completeIfReady(transfer)
                }
            }
            onStatus?(transfer)
        } catch {
            inserted?.captureEnded = true
            inserted?.finished = true
            inserted?.state = "Could not start"
            inserted?.error = error.localizedDescription
            notice = error.localizedDescription
        }
    }

    func stop(_ transfer: MediaTransfer, reason: String = "Stopped by user") {
        guard !transfer.captureEnded else {
            return
        }
        transfer.state = "Finishing captured media"
        onStatus?(transfer)
        if let recorder = transfer.recorder {
            Task {
                await recorder.stop(reason)
            }
        } else if transfer.source.isBlob {
            onBlobStop?(transfer)
        } else {
            transfer.task?.cancel()
        }
    }

    func leave(tabID: UUID, url: String? = nil, reason: String) {
        for transfer in transfers where transfer.source.tabID == tabID && transfer.live && !transfer.captureEnded {
            guard url == nil || transfer.source.url == url, transfer.settings.stopOnSourceLeave else {
                continue
            }
            stop(transfer, reason: reason)
        }
    }

    /// Binary page ingress is accepted only for a user-started recording owned by this tab.
    func blobMessage(_ body: [String: Any], tabID: UUID) throws {
        guard let value = body["recording"] as? String, let id = UUID(uuidString: value),
              let transfer = transfers.first(where: { $0.id == id && $0.source.tabID == tabID && $0.source.isBlob && !$0.ingressClosed }),
              let folder = transfer.blobFolder else {
            throw MediaFailure.invalid("No active media-buffer recording belongs to this page.")
        }
        let type = body["type"] as? String
        if type == "blob-end" || type == "blob-error" {
            if type == "blob-error" {
                transfer.error = body["reason"] as? String ?? "Media buffer capture failed."
            }
            closeBlob(transfer, reason: body["reason"] as? String ?? "Media source ended")
            return
        }
        guard type == "blob-chunk", let index = body["stream"] as? Int, (0..<8).contains(index),
              let sequence = body["sequence"] as? Int, sequence == (transfer.blobSequences[index] ?? 0),
              let string = body["data"] as? String, string.utf8.count <= 360_000,
              let data = Data(base64Encoded: string), data.count <= 256 * 1024 else {
            throw MediaFailure.invalid("Invalid or out-of-order media buffer.")
        }
        if transfer.blobHandles[index] == nil {
            let mime = body["mime"] as? String ?? ""
            guard mime.contains("mp4") || mime.contains("webm") else {
                throw MediaFailure.invalid("Only MP4/WebM media buffers can be captured. Opaque WebSocket protocols are unsupported.")
            }
            let file = folder.appendingPathComponent("track-\(index).\(mime.contains("webm") ? "webm" : "mp4")")
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
            transfer.blobFiles[index] = file
            transfer.blobKinds[index] = mime
            transfer.blobHandles[index] = try FileHandle(forWritingTo: file)
        }
        let available = try captures.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= 512 * 1024 * 1024 else {
            closeBlob(transfer, reason: "Storage reserve reached")
            throw MediaFailure.invalid("Storage reserve reached; received bytes were retained.")
        }
        try transfer.blobHandles[index]?.write(contentsOf: data)
        try transfer.blobHandles[index]?.synchronize()
        transfer.blobSequences[index] = sequence + 1
        transfer.bytes += Int64(data.count)
        transfer.duration = Date().timeIntervalSince(transfer.startedAt)
        let indexes = transfer.blobFiles.keys.sorted()
        let checkpoint = RecordingCheckpoint(id: transfer.id, title: transfer.source.title, settings: transfer.settings,
                                              folder: transfer.settings.defaultFolder, streams: [],
                                              rawStreams: indexes.compactMap { transfer.blobFiles[$0]?.lastPathComponent },
                                              rawKinds: indexes.map { transfer.blobKinds[$0] ?? "" })
        try JSONEncoder().encode(checkpoint).write(to: folder.appendingPathComponent("checkpoint.json"), options: .atomic)
        if transfer.bytes >= Int64(transfer.settings.partLimitMB) * 1024 * 1024 {
            // MSE cannot be arbitrarily split at byte boundaries; close a valid capture instead.
            stop(transfer, reason: "Media-buffer size limit reached")
        }
        onStatus?(transfer)
    }

    func finishBlob(_ transfer: MediaTransfer, reason: String) {
        closeBlob(transfer, reason: reason)
    }

    private func closeBlob(_ transfer: MediaTransfer, reason: String) {
        guard !transfer.ingressClosed, let folder = transfer.blobFolder else {
            return
        }
        transfer.ingressClosed = true
        for handle in transfer.blobHandles.values {
            try? handle.synchronize()
            try? handle.close()
        }
        transfer.blobHandles = [:]
        var checkpoint = (try? Data(contentsOf: folder.appendingPathComponent("checkpoint.json"))).flatMap {
            try? JSONDecoder().decode(RecordingCheckpoint.self, from: $0)
        }
        checkpoint?.reason = reason
        if var checkpoint {
            if checkpoint.rawStreams.count > 1 {
                checkpoint.streams = Self.tracks(checkpoint, duration: max(1, transfer.duration))
            }
            enqueueExport(folder, checkpoint: checkpoint, transfer: transfer)
        } else {
            transfer.error = "No complete media buffers were received. Raw files, if any, are retained."
        }
        transfer.captureEnded = true
        completeIfReady(transfer)
    }

    private func enqueueExport(_ folder: URL, checkpoint: RecordingCheckpoint, transfer: MediaTransfer, recoveryJournal: URL? = nil) {
        let previous = transfer.exportTail
        transfer.pendingExports += 1
        transfer.exportTail = Task {
            // Successful export removes its capture folder and journal. Keep the
            // journal on any failure, including native failures that surface later,
            // so automatic startup recovery never repeats an unsuccessful attempt.
            defer {
                if recoveryJournal != nil { self.activeRecoveries.remove(folder) }
            }
            await previous?.value
            transfer.state = transfer.captureEnded ? "Finalizing movie" : "Recording; converting completed part"
            onStatus?(transfer)
            do {
                let name = try self.uniqueOutput(title: checkpoint.title, extension: checkpoint.settings.container.rawValue, relative: checkpoint.folder)
                try await MediaExporter.export(folder: folder, checkpoint: checkpoint, destination: name)
                transfer.outputs.append(name)
                if let data = transfer.thumbnail { await MediaThumbnailCache.shared.seed(data, for: name) }
                self.revision += 1
            } catch {
                transfer.error = error.localizedDescription
            }
            transfer.pendingExports -= 1
            if !transfer.captureEnded { transfer.state = "Recording live segments" }
            self.completeIfReady(transfer)
        }
    }

    private func completeIfReady(_ transfer: MediaTransfer) {
        guard transfer.captureEnded, transfer.pendingExports == 0 else {
            return
        }
        transfer.finished = true
        Task {
            for output in transfer.outputs {
                if let data = transfer.thumbnail {
                    await MediaThumbnailCache.shared.seed(data, for: output)
                } else {
                    transfer.thumbnail = await MediaThumbnailCache.shared.thumbnail(for: output)
                }
            }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)) ?? []
        let retained = folders.contains { folder in
            guard folder.lastPathComponent.hasPrefix(transfer.id.uuidString),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("checkpoint.json")),
                  let checkpoint = try? JSONDecoder().decode(RecordingCheckpoint.self, from: data) else { return false }
            return checkpoint.id == transfer.id && !checkpoint.finalized
        }
        transfer.state = transfer.error == nil ? "Saved" : (transfer.outputs.isEmpty ? (retained ? "Capture retained — recovery available" : "Download failed — no media saved") : "Saved partial recording")
        transfer.progress = transfer.error == nil ? 1 : nil
        onStatus?(transfer)
        endBackgroundIfIdle()
    }

    func retryRecovery() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !activeRecoveries.contains(folder) {
            let journal = folder.appendingPathComponent(".recovery-in-progress")
            if FileManager.default.fileExists(atPath: journal.path) {
                do { try FileManager.default.removeItem(at: journal) }
                catch { notice = "Could not restart recovery. Captured files are retained."; continue }
            }
            recovering.remove(folder)
        }
        recoverInterrupted()
    }

    func recoverInterrupted() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders {
            guard !recovering.contains(folder), !transfers.contains(where: { !$0.finished && folder.lastPathComponent.hasPrefix($0.id.uuidString) }),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("checkpoint.json")),
                  var checkpoint = try? JSONDecoder().decode(RecordingCheckpoint.self, from: data), !checkpoint.finalized,
                  !checkpoint.rawStreams.isEmpty || checkpoint.streams.first?.isEmpty == false else {
                continue
            }
            recovering.insert(folder)
            if checkpoint.rawStreams.count > 1 && checkpoint.streams.isEmpty {
                checkpoint.streams = Self.tracks(checkpoint, duration: 1)
            }
            let source = PageMedia(url: "", page: "", tabID: UUID(), title: checkpoint.title, hls: true, mime: "video/mp4")
            let transfer = MediaTransfer(source: source, settings: checkpoint.settings)
            transfer.captureEnded = true
            transfer.state = "Recovering interrupted capture"
            transfers.insert(transfer, at: 0)
            let journal = folder.appendingPathComponent(".recovery-in-progress")
            if FileManager.default.fileExists(atPath: journal.path) {
                transfer.error = "A previous recovery did not complete. Captured files are retained; use Retry retained recordings to try again."
                transfer.state = "Capture retained — manual recovery available"
                transfer.finished = true
                continue
            }
            do {
                try Data().write(to: journal, options: .atomic)
                activeRecoveries.insert(folder)
                enqueueExport(folder, checkpoint: checkpoint, transfer: transfer, recoveryJournal: journal)
            } catch {
                transfer.error = "Could not prepare recovery. Captured files are retained."
                transfer.state = "Capture retained — recovery unavailable"
                transfer.finished = true
            }
        }
    }

    private static func tracks(_ checkpoint: RecordingCheckpoint, duration: Double) -> [[CapturedSegment]] {
        let indexed = checkpoint.rawStreams.enumerated().sorted { left, right in
            let leftAudio = checkpoint.rawKinds?.indices.contains(left.offset) == true && checkpoint.rawKinds?[left.offset].hasPrefix("audio/") == true
            let rightAudio = checkpoint.rawKinds?.indices.contains(right.offset) == true && checkpoint.rawKinds?[right.offset].hasPrefix("audio/") == true
            return !leftAudio && rightAudio
        }
        return indexed.map { _, file in
            [CapturedSegment(file: file, duration: duration, initialization: nil, discontinuity: false)]
        }
    }

    private func backgrounded() {
        guard transfers.contains(where: { !$0.finished }) else {
            return
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finalize captured media") { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }
                for transfer in self.transfers where !transfer.finished && transfer.source.isBlob {
                    self.closeBlob(transfer, reason: "Background time expired")
                }
                if self.backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundTask)
                    self.backgroundTask = .invalid
                }
            }
        }
        for transfer in transfers where !transfer.finished {
            if transfer.live {
                stop(transfer, reason: "App entered background")
                if transfer.source.isBlob {
                    closeBlob(transfer, reason: "App entered background")
                }
            }
        }
        // iOS grants finite completion time. Checkpoints survive if conversion is suspended.
    }

    private func endBackgroundIfIdle() {
        if backgroundTask != .invalid && transfers.allSatisfy(\.finished) {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func extensionFor(source: PageMedia) -> String {
        if let ext = URL(string: source.url)?.pathExtension.lowercased(), !ext.isEmpty, ext.count <= 8,
           ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return ext
        }
        if source.mime.hasPrefix("image/") {
            return UTType(mimeType: source.mime)?.preferredFilenameExtension ?? "bin"
        }
        return source.mime.hasPrefix("video/") ? "mp4" : "bin"
    }

    private func uniqueOutput(title: String, extension ext: String, relative: String) throws -> URL {
        let folder = try directory(relative)
        let name = String(title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) ? Character(String($0)) : "_" }.prefix(80))
        let stem = name.isEmpty ? "Media" : name
        return folder.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    func saveToPhotos(_ file: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            notice = "Allow Photos access to save this media. Files export is still available."
            return
        }
        let isImage = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif"].contains(file.pathExtension.lowercased())
        let compatible = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: compatible) }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw MediaFailure.invalid("The saved file is empty. Download it again before saving to Photos.") }
            if !isImage {
                let asset = AVURLAsset(url: file)
                guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw MediaFailure.invalid("This file does not contain a readable video track. Download it again; changing its extension will not repair it.")
                }
                guard !(try await asset.load(.hasProtectedContent)) else {
                    throw MediaFailure.invalid("This video is protected and cannot be exported to Photos.")
                }
            }
            func importFile(_ url: URL) async throws {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: isImage ? .photo : .video, fileURL: url, options: nil)
                }
            }
            do {
                try await importFile(file)
            } catch {
                let photosError = error as NSError
                guard !isImage, photosError.domain == PHPhotosErrorDomain, photosError.code == 3302 else { throw error }
                notice = "Preparing a Photos-compatible video…"
                var settings = MediaSettings()
                settings.container = .mp4
                settings.codec = .h264
                try await MediaExporter.convert(file, settings: settings, destination: compatible)
                try await importFile(compatible)
            }
            notice = "Saved to Photos."
        } catch {
            notice = "Could not save to Photos: \(error.localizedDescription) The original remains in Downloads; Share is still available."
        }
    }
}
