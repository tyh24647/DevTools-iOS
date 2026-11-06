import Foundation
import AVFoundation
import ImageIO
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// FFmpeg is used only to demux/remux local media. Apple supplies H.264/HEVC encoding.
/// The dependency is pinned, dynamic LGPL, and has no network protocol support.
enum MediaExporter {
    static func localManifest(folder: URL, checkpoint: RecordingCheckpoint) throws -> (URL, String) {
        if checkpoint.rawStreams.count == 1 {
            let name = checkpoint.rawStreams[0]
            try validateName(name)
            return (folder.appendingPathComponent(name), name.hasSuffix(".webm") ? "matroska" : "mov")
        }
        guard checkpoint.streams.filter({ !$0.isEmpty }).count <= 2 else {
            throw MediaFailure.invalid("This capture contains more than two media tracks. Raw tracks are retained for export.")
        }
        if checkpoint.rawStreams.count > 1 && checkpoint.rawStreams.contains(where: { $0.hasSuffix(".webm") }) {
            throw MediaFailure.invalid("Separate WebM tracks cannot be combined as HLS. Raw tracks are retained for export.")
        }
        var playlists: [String] = []
        for (index, records) in checkpoint.streams.filter({ !$0.isEmpty }).enumerated() {
            guard !records.isEmpty else {
                throw MediaFailure.invalid("A selected audio/video track contains no complete segments.")
            }
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(records.map(\.duration).max() ?? 1)))\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            var previousMap: String?
            for record in records {
                try validateName(record.file)
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.file).path) else {
                    throw MediaFailure.invalid("A captured segment is missing. The recording cache is retained.")
                }
                if record.discontinuity {
                    text += "#EXT-X-DISCONTINUITY\n"
                }
                if let map = record.initialization, map != previousMap {
                    try validateName(map)
                    text += "#EXT-X-MAP:URI=\"\(map)\"\n"
                    previousMap = map
                }
                text += "#EXTINF:\(record.duration),\n\(record.file)\n"
            }
            text += "#EXT-X-ENDLIST\n"
            let name = "stream-\(index).m3u8"
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            playlists.append(name)
        }
        guard !playlists.isEmpty else {
            throw MediaFailure.invalid("No complete captured segments are available.")
        }
        if playlists.count == 1 {
            return (folder.appendingPathComponent(playlists[0]), "hls")
        }
        let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(playlists[1])\"\n#EXT-X-STREAM-INF:BANDWIDTH=10000000,AUDIO=\"audio\"\n\(playlists[0])\n"
        let url = folder.appendingPathComponent("master.m3u8")
        try master.write(to: url, atomically: true, encoding: .utf8)
        return (url, "hls")
    }

    static func export(folder: URL, checkpoint: RecordingCheckpoint, destination: URL) async throws {
        let remuxed = folder.appendingPathComponent("remuxed.mp4")
        try? FileManager.default.removeItem(at: remuxed)
        if checkpoint.rawStreams.count > 1 {
            try await stitchRawTracks(folder: folder, checkpoint: checkpoint, destination: remuxed)
        } else {
            let (input, demux) = try localManifest(folder: folder, checkpoint: checkpoint)
            try await remux(input, demux: demux, destination: remuxed)
        }
        try await convert(remuxed, settings: checkpoint.settings, destination: destination)
        var saved = checkpoint
        saved.finalized = true
        try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("checkpoint.json"), options: .atomic)
        // Remove this immutable part only after the final movie has been saved successfully.
        try? FileManager.default.removeItem(at: folder)
    }

    private static func remux(_ input: URL, demux: String, destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            var error = [CChar](repeating: 0, count: 1024)
            let capacity = Int32(error.count)
            let result = input.path.withCString { path in
                demux.withCString { kind in
                    destination.path.withCString { target in
                        DTMediaRemux(path, kind, target, &error, capacity)
                    }
                }
            }
            guard result >= 0 else {
                throw MediaFailure.invalid("Media remux failed: \(String(cString: error)). Captured files are preserved.")
            }
        }.value
    }

    /// Each raw stream already contains its ordered initialization and media chunks.
    /// Remux individual tracks first, then place audio and video on the same timeline.
    private static func stitchRawTracks(folder: URL, checkpoint: RecordingCheckpoint, destination: URL) async throws {
        let composition = AVMutableComposition()
        var temporary: [URL] = []
        defer { for file in temporary { try? FileManager.default.removeItem(at: file) } }
        for (index, name) in checkpoint.rawStreams.enumerated() {
            try validateName(name)
            let normalized = folder.appendingPathComponent("normalized-track-\(index).mp4")
            temporary.append(normalized)
            try? FileManager.default.removeItem(at: normalized)
            try await remux(folder.appendingPathComponent(name), demux: name.hasSuffix(".webm") ? "matroska" : "mov", destination: normalized)
            let asset = AVURLAsset(url: normalized)
            for type in [AVMediaType.video, .audio] {
                for track in try await asset.loadTracks(withMediaType: type) {
                    guard let output = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw MediaFailure.invalid("Could not combine the captured media tracks. Captured files are preserved.")
                    }
                    let range = try await track.load(.timeRange)
                    try output.insertTimeRange(range, of: track, at: .zero)
                    if type == .video { output.preferredTransform = try await track.load(.preferredTransform) }
                }
            }
        }
        guard !composition.tracks.isEmpty,
              let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mp4) else {
            throw MediaFailure.invalid("The captured tracks cannot be combined into MP4. Captured files are preserved.")
        }
        try await exporter.export(to: destination, as: .mp4)
    }

    static func convert(_ source: URL, settings: MediaSettings, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isExportable) else {
            throw MediaFailure.invalid("This codec cannot be exported by AVFoundation. Original capture is retained.")
        }
        let preset: String
        switch settings.codec {
        case .copy:
            preset = AVAssetExportPresetPassthrough
        case .h264:
            preset = AVAssetExportPresetHighestQuality
        case .hevc:
            preset = AVAssetExportPresetHEVCHighestQuality
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaFailure.invalid("The requested encoder is unavailable on this device.")
        }
        let type: AVFileType = settings.container == .mp4 ? .mp4 : .mov
        guard exporter.supportedFileTypes.contains(type) else {
            throw MediaFailure.invalid("The selected codec/container combination is not supported.")
        }
        let pending = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(settings.container.rawValue)")
        defer {
            try? FileManager.default.removeItem(at: pending)
        }
        exporter.outputURL = pending
        exporter.outputFileType = type
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? MediaFailure.invalid("Video conversion did not complete.")
        }
        try FileManager.default.moveItem(at: pending, to: destination)
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\n"), !name.contains("\r"), !name.contains("\"") else {
            throw MediaFailure.invalid("Invalid checkpoint filename.")
        }
    }
}

// Thumbnails live outside Downloads, so they never appear as user media or sidecar files.
// An actor keeps disk IO, decoding, and JPEG compression off the main actor.
actor MediaThumbnailCache {
    static let shared = MediaThumbnailCache()
    private var jobs: [String: Task<Data?, Never>] = [:]
    private let memory = NSCache<NSString, NSData>()
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaThumbnails", isDirectory: true)
    }

    private func key(for file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        // Files retain their identity when renamed or moved; replacement files get a new key.
        let keys: [FileAttributeKey] = [.systemNumber, .systemFileNumber, .size, .modificationDate, .creationDate]
        let identity = keys.map { String(describing: attributes[$0]) }.joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func thumbnail(for file: URL) async -> Data? {
        guard let key = key(for: file) else { return nil }
        if let cached = memory.object(forKey: key as NSString) { return cached as Data }
        let target = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: target) {
            memory.setObject(data as NSData, forKey: key as NSString)
            return data
        }
        if let job = jobs[key] { return await job.value }
        let job = Task { await Self.render(file) }
        jobs[key] = job
        let data = await job.value
        jobs[key] = nil
        if let data { store(data, key: key) }
        return data
    }

    func seed(_ data: Data, for file: URL) {
        guard let key = key(for: file) else { return }
        store(data, key: key)
    }

    private func store(_ data: Data, key: String) {
        memory.countLimit = 100
        memory.setObject(data as NSData, forKey: key as NSString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key + ".jpg"), options: .atomic)
    }

    private static func render(_ file: URL) async -> Data? {
        if isVideo(file) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 240)
            guard let frame = try? await generator.image(at: .zero) else { return nil }
            return jpeg(frame.image)
        }
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 160, height: 120), scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return jpeg(representation.cgImage)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated static func isVideo(_ file: URL) -> Bool {
        UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) == true ||
            ["mp4", "mov", "m4v", "webm", "mkv", "ts"].contains(file.pathExtension.lowercased())
    }

    // Snapshot a complete first segment before export can remove the recording folder.
    // Only this small immutable copy is decoded; the live recording is never opened or changed.
    nonisolated static func stageSegment(folder: URL, segment: CapturedSegment) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (segment.initialization == nil ? ".ts" : ".mp4"))
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        do {
            for name in [segment.initialization, segment.file].compactMap({ $0 }) {
                try MediaExporter.validateName(name)
                let input = try FileHandle(forReadingFrom: folder.appendingPathComponent(name))
                defer { try? input.close() }
                while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
                    try output.write(contentsOf: data)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return target
    }

    func segmentThumbnail(_ snapshot: URL) async -> Data? {
        let movie = snapshot.deletingPathExtension().appendingPathExtension("preview.mp4")
        defer {
            try? FileManager.default.removeItem(at: snapshot)
            try? FileManager.default.removeItem(at: movie)
        }
        var error = [CChar](repeating: 0, count: 1024)
        let capacity = Int32(error.count)
        let result = DTMediaRemux(snapshot.path, snapshot.pathExtension == "ts" ? "mpegts" : "mov", movie.path, &error, capacity)
        guard result >= 0 else { return nil }
        return await Self.render(movie)
    }
}
