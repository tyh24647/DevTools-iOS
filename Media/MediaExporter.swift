import Foundation
import AVFoundation

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
        let (input, demux) = try localManifest(folder: folder, checkpoint: checkpoint)
        let remuxed = folder.appendingPathComponent("remuxed.mp4")
        try? FileManager.default.removeItem(at: remuxed)
        try await Task.detached(priority: .utility) {
            var error = [CChar](repeating: 0, count: 1024)
            let capacity = Int32(error.count)
            let result = input.path.withCString { path in
                demux.withCString { kind in
                    remuxed.path.withCString { target in
                        DTMediaRemux(path, kind, target, &error, capacity)
                    }
                }
            }
            guard result >= 0 else {
                throw MediaFailure.invalid("Media remux failed: \(String(cString: error)). Captured files are preserved.")
            }
        }.value
        try await convert(remuxed, settings: checkpoint.settings, destination: destination)
        var saved = checkpoint
        saved.finalized = true
        try JSONEncoder().encode(saved).write(to: folder.appendingPathComponent("checkpoint.json"), options: .atomic)
        // Remove this immutable part only after the final movie has been saved successfully.
        try? FileManager.default.removeItem(at: folder)
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
