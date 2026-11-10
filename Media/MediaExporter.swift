import Foundation
import AVFoundation
import ImageIO
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum MediaExporter {
    /// Local media must contain its own tracks; embedded file or network references are not followed.
    static func localAsset(_ source: URL) throws -> AVURLAsset {
        try MediaLocalFiles.requireFileURL(source)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MediaFailure.invalid("Choose a regular local media file.")
        }
        return AVURLAsset(url: source, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
    }

    static func convert(_ source: URL, settings: MediaSettings, destination: URL) async throws {
        guard source.isFileURL, destination.isFileURL else {
            throw MediaFailure.invalid("Conversion requires local input and output files.")
        }
        try MediaLocalFiles.requireFileURL(destination)
        let folder = destination.deletingLastPathComponent()
        guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw MediaFailure.invalid("Choose a new output file in an existing folder.")
        }
        let asset = try localAsset(source)
        guard try await asset.load(.isExportable), !(try await asset.load(.hasProtectedContent)) else {
            throw MediaFailure.invalid("AVFoundation cannot export this file. The original is retained.")
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
            throw MediaFailure.invalid("The selected codec and container are not supported for this file.")
        }
        let pending = folder.appendingPathComponent(MediaLocalFiles.pendingPrefix + UUID().uuidString + "." + settings.container.rawValue)
        defer {
            try? FileManager.default.removeItem(at: pending)
        }
        try Task.checkCancellation()
        exporter.outputURL = pending
        exporter.outputFileType = type
        await exporter.export()
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw exporter.error ?? MediaFailure.invalid("Media conversion did not complete.")
        }
        try FileManager.default.moveItem(at: pending, to: destination)
    }
}

// Thumbnails are cached separately from the user's files.
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
        guard (try? MediaLocalFiles.requireFileURL(file)) != nil,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return nil
        }
        // Files retain their identity when renamed or moved; replacement files get a new key.
        let keys: [FileAttributeKey] = [.systemNumber, .systemFileNumber, .size, .modificationDate, .creationDate]
        let identity = keys.map {
            String(describing: attributes[$0])
        }.joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    func thumbnail(for file: URL) async -> Data? {
        guard let key = key(for: file) else {
            return nil
        }
        if let cached = memory.object(forKey: key as NSString) {
            return cached as Data
        }
        let target = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: target) {
            memory.setObject(data as NSData, forKey: key as NSString)
            return data
        }
        if let job = jobs[key] {
            return await job.value
        }
        let job = Task {
            await Self.render(file)
        }
        jobs[key] = job
        let data = await job.value
        jobs[key] = nil
        if let data {
            store(data, key: key)
        }
        return data
    }

    func seed(_ data: Data, for file: URL) {
        guard let key = key(for: file) else {
            return
        }
        store(data, key: key)
    }

    private func store(_ data: Data, key: String) {
        memory.countLimit = 100
        memory.setObject(data as NSData, forKey: key as NSString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key + ".jpg"), options: .atomic)
    }

    private static func render(_ file: URL) async -> Data? {
        guard file.isFileURL else {
            return nil
        }
        if isVideo(file) {
            guard let asset = try? MediaExporter.localAsset(file) else {
                return nil
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 240)
            guard let frame = try? await generator.image(at: .zero) else {
                return nil
            }
            return jpeg(frame.image)
        }
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 160, height: 120), scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return jpeg(representation.cgImage)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    nonisolated static func isVideo(_ file: URL) -> Bool {
        file.isFileURL && (UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) == true ||
            ["mp4", "mov", "m4v", "webm", "mkv", "ts"].contains(file.pathExtension.lowercased()))
    }

    nonisolated static func isAudio(_ file: URL) -> Bool {
        file.isFileURL && (UTType(filenameExtension: file.pathExtension)?.conforms(to: .audio) == true ||
            ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "ogg"].contains(file.pathExtension.lowercased()))
    }

    nonisolated static func isPlayable(_ file: URL) -> Bool {
        isVideo(file) || isAudio(file)
    }
}
