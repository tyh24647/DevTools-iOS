import Foundation
import CommonCrypto

/// Segment downloads commit atomically. Capture and conversion run separately so HEVC
/// encoding of a finished part does not make a live playlist expire while recording.
actor HLSRecorder {
    private let http: MediaHTTP
    private let choice: MediaChoice
    private let settings: MediaSettings
    private let root: URL
    private let title: String
    private let id: UUID
    private var stopped: String?
    private var part = 0
    private var bytes: Int64 = 0
    private var captured = 0.0
    private var clocks: [Double]
    private var streams: [[CapturedSegment]]
    private var seen: [Int64?]
    private var folder: URL!
    private var initialized: [String: String] = [:]
    private var keys: [URL: Data] = [:]
    private var thumbnailScheduled = false

    init(http: MediaHTTP, choice: MediaChoice, settings: MediaSettings, root: URL, title: String, id: UUID) {
        self.http = http
        self.choice = choice
        self.settings = settings
        self.root = root
        self.title = title
        self.id = id
        streams = Array(repeating: [], count: choice.audio == nil ? 1 : 2)
        seen = Array(repeating: nil, count: choice.audio == nil ? 1 : 2)
        clocks = Array(repeating: 0, count: choice.audio == nil ? 1 : 2)
    }

    func stop(_ reason: String) {
        stopped = reason
    }

    func capture(progress: @escaping @Sendable (Int64, Double, Double?) async -> Void,
                 ready: @escaping @Sendable (URL, RecordingCheckpoint) async -> Void,
                 thumbnail: @escaping @Sendable (Data) async -> Void = { _ in }) async throws {
        defer { http.close() }
        try beginPart()
        let urls = [choice.video] + (choice.audio.map { [$0] } ?? [])
        var idle = 0
        var pendingError: Error?
        do {
            while stopped == nil {
                try Task.checkCancellation()
                var added = false
                var ended = true
                var interval = 3.0
                var playlists: [HLSPlaylist] = []
                var batches: [[HLSPlaylist.Segment]] = []
                for (stream, url) in urls.enumerated() {
                    let playlist = try await http.playlist(url)
                    playlists.append(playlist)
                    ended = ended && playlist.ended
                    interval = max(1, min(10, playlist.targetDuration / 2))
                    let initial = choice.live && seen[stream] == nil ? Array(playlist.segments.suffix(3)) : playlist.segments
                    batches.append(initial.filter { seen[stream] == nil || $0.sequence > seen[stream]! })
                }
                if choice.live && seen.allSatisfy({ $0 == nil }), batches.count > 1 {
                    let window = batches[0].reduce(0) { $0 + $1.duration }
                    var duration = 0.0
                    var audio: [HLSPlaylist.Segment] = []
                    for segment in playlists[1].segments.reversed() {
                        audio.insert(segment, at: 0)
                        duration += segment.duration
                        if duration >= window { break }
                    }
                    batches[1] = audio
                }
                // Balance track durations, rather than counts: video and audio segment
                // lengths frequently differ. Seal only after audio catches the video.
                var positions = Array(repeating: 0, count: batches.count)
                while stopped == nil {
                    let available = batches.indices.filter { positions[$0] < batches[$0].count }
                    guard let stream = available.min(by: { clocks[$0] < clocks[$1] }) else { break }
                    let segment = batches[stream][positions[stream]]
                    positions[stream] += 1
                    if let previous = seen[stream], segment.sequence != previous + 1 {
                        throw MediaFailure.invalid("A live segment expired or its sequence reset. Captured media is preserved.")
                    }
                    try ensureSpace()
                    streams[stream].append(try await fetch(segment, stream: stream))
                    if stream == 0 && !thumbnailScheduled, let first = streams[stream].first,
                       let snapshot = try? MediaThumbnailCache.stageSegment(folder: folder, segment: first) {
                        thumbnailScheduled = true
                        Task {
                            if let data = await MediaThumbnailCache.shared.segmentThumbnail(snapshot) {
                                await thumbnail(data)
                            }
                        }
                    }
                    seen[stream] = segment.sequence
                    clocks[stream] += segment.duration
                    if stream == 0 { captured += segment.duration }
                    try checkpoint()
                    added = true
                    await progress(bytes, captured, choice.live ? nil : min(1, captured / max(1, playlists[0].segments.reduce(0) { $0 + $1.duration })))
                    let balanced = clocks.count == 1 || clocks[1] >= clocks[0]
                    if bytes >= Int64(settings.partLimitMB) * 1024 * 1024 && balanced && !streams[0].isEmpty {
                        if choice.live && settings.splitAndContinue && stopped == nil {
                            let completed = try seal(reason: "File-size rollover")
                            await ready(folder, completed)
                            try beginPart()
                        } else {
                            stopped = "File-size limit reached"
                        }
                    }
                }
                if stopped == nil && (!choice.live || ended) {
                    stopped = "Stream ended"
                }
                if stopped != nil {
                    break
                }
                idle = added ? 0 : idle + 1
                guard idle < 30 else {
                    throw MediaFailure.invalid("The stream stopped publishing. Captured media will be finalized.")
                }
                // Stop requests can interrupt this wait without cancelling a partially downloaded segment.
                for _ in 0..<Int(interval * 10) {
                    if stopped != nil {
                        break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        } catch {
            pendingError = error
        }
        if streams.first?.isEmpty == false {
            let completed = try seal(reason: stopped ?? pendingError?.localizedDescription ?? "Stopped")
            await ready(folder, completed)
        }
        if let pendingError {
            throw pendingError
        }
    }

    private func beginPart() throws {
        part += 1
        folder = root.appendingPathComponent("\(id.uuidString)-part-\(part)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        streams = Array(repeating: [], count: streams.count)
        initialized = [:]
        bytes = 0
        try checkpoint()
    }

    private func ensureSpace() throws {
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= 512 * 1024 * 1024 else {
            throw MediaFailure.invalid("Storage reserve reached. Saved segments are retained for finalization.")
        }
    }

    private func fetch(_ segment: HLSPlaylist.Segment, stream: Int) async throws -> CapturedSegment {
        var mapName: String?
        if let initialization = segment.initialization {
            let identity = "\(initialization.url.absoluteString):\(String(describing: initialization.range))"
            if let name = initialized[identity] {
                mapName = name
            } else {
                let name = "init-\(initialized.count).mp4"
                let url = folder.appendingPathComponent(name)
                _ = try await http.download(initialization.url, to: url, range: initialization.range)
                if let key = segment.key {
                    guard key.iv != nil else {
                        throw MediaFailure.invalid("Encrypted fMP4 initialization requires an explicit IV.")
                    }
                    try await decrypt(url, key: key, sequence: segment.sequence)
                }
                bytes += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                initialized[identity] = name
                mapName = name
            }
        }
        let name = "s\(stream)-\(segment.sequence).\(mapName == nil ? "ts" : "m4s")"
        let temporary = folder.appendingPathComponent(name + ".pending")
        let final = folder.appendingPathComponent(name)
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        _ = try await http.download(segment.url, to: temporary, range: segment.range)
        if let key = segment.key {
            try await decrypt(temporary, key: key, sequence: segment.sequence)
        }
        try FileManager.default.moveItem(at: temporary, to: final)
        bytes += Int64(try final.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return CapturedSegment(file: name, duration: segment.duration, initialization: mapName, discontinuity: segment.discontinuity)
    }

    private func decrypt(_ file: URL, key: HLSPlaylist.Key, sequence: Int64) async throws {
        let keyData: Data
        if let cached = keys[key.url] {
            keyData = cached
        } else {
            keyData = try await http.data(key.url, maximum: 32).0
            guard keyData.count == 16 else {
                throw MediaFailure.invalid("Invalid AES-128 key.")
            }
            keys[key.url] = keyData
        }
        var iv = [UInt8](repeating: 0, count: 16)
        if let value = key.iv {
            let hex = value.lowercased().replacingOccurrences(of: "0x", with: "")
            guard hex.count <= 32, !hex.isEmpty else {
                throw MediaFailure.invalid("Invalid AES IV.")
            }
            let padded = String(repeating: "0", count: 32 - hex.count) + hex
            for index in 0..<16 {
                let start = padded.index(padded.startIndex, offsetBy: index * 2)
                let end = padded.index(start, offsetBy: 2)
                guard let byte = UInt8(padded[start..<end], radix: 16) else {
                    throw MediaFailure.invalid("Invalid AES IV.")
                }
                iv[index] = byte
            }
        } else {
            var value = UInt64(sequence).bigEndian
            withUnsafeBytes(of: &value) {
                iv.replaceSubrange(8..<16, with: $0)
            }
        }
        let encrypted = try Data(contentsOf: file)
        var output = Data(count: encrypted.count + kCCBlockSizeAES128)
        var length = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            encrypted.withUnsafeBytes { input in
                keyData.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, keyData.count, ivBytes.baseAddress, input.baseAddress, encrypted.count,
                                out.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw MediaFailure.invalid("AES segment decryption failed.")
        }
        output.count = length
        try output.write(to: file, options: .atomic)
    }

    private func checkpoint() throws {
        let record = RecordingCheckpoint(id: id, title: title, settings: settings, folder: settings.defaultFolder,
                                         streams: streams, rawStreams: [])
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("checkpoint.json"), options: .atomic)
    }

    private func seal(reason: String) throws -> RecordingCheckpoint {
        let record = RecordingCheckpoint(id: id, title: title, settings: settings, folder: settings.defaultFolder,
                                         streams: streams, rawStreams: [], reason: reason)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("checkpoint.json"), options: .atomic)
        return record
    }
}
