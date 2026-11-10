import Testing
import Foundation
import AVFoundation
import ImageIO
import CoreVideo
@testable import DownloadsCore

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

@Test @MainActor func renameMoveAndFolderReferences() throws {
    let root = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let library = MediaLibrary(root: root, defaults: nil)
    try library.createFolder("Clips", in: "")
    try library.createFolder("Nested", in: "Clips")
    let file = root.appendingPathComponent("first.mp4")
    try Data("original".utf8).write(to: file)
    try library.relocate(file, to: "Clips", name: "renamed.mp4")
    let moved = root.appendingPathComponent("Clips/renamed.mp4")
    #expect(try Data(contentsOf: moved) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    library.settings.defaultFolder = "Clips/Nested"
    try library.relocate(root.appendingPathComponent("Clips"), to: "", name: "Movies")
    #expect(library.settings.defaultFolder == "Movies/Nested")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Movies/renamed.mp4").path))
    try library.delete(root.appendingPathComponent("Movies"))
    #expect(library.settings.defaultFolder.isEmpty)
}

@Test @MainActor func refuseOverwriteEscapeAndSymlinks() throws {
    let root = try temporaryFolder()
    let outside = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let library = MediaLibrary(root: root, defaults: nil)
    try library.createFolder("Clips", in: "")
    try library.createFolder("Nested", in: "Clips")
    let file = root.appendingPathComponent("original.mp4")
    try Data("keep".utf8).write(to: file)
    try Data("existing".utf8).write(to: root.appendingPathComponent("Clips/original.mp4"))
    #expect(throws: (any Error).self) {
        try library.relocate(file, to: "Clips")
    }
    #expect(throws: (any Error).self) {
        try library.relocate(file, to: "", name: "../escape.mp4")
    }
    let link = root.appendingPathComponent("Outside")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: (any Error).self) {
        try library.relocate(file, to: "Outside")
    }
    #expect(throws: (any Error).self) {
        try library.createFolder("Escaped", in: "Outside")
    }
    #expect(throws: (any Error).self) {
        try library.createFile("escaped.txt", in: "../")
    }
    #expect(throws: (any Error).self) {
        try library.relocate(root.appendingPathComponent("Clips"), to: "Clips/Nested")
    }
    #expect(throws: (any Error).self) {
        try library.delete(URL(string: "https://example.invalid/original.mp4")!)
    }
    #expect(!library.files(in: "").contains(link))
    #expect(library.files(in: "Outside").isEmpty)
    #expect(!library.destinationFolders(excluding: root.appendingPathComponent("Clips")).contains("Clips/Nested"))
    #expect(!library.destinationFolders(excluding: file).contains("Outside"))
    #expect(try Data(contentsOf: file) == Data("keep".utf8))
}

@Test @MainActor func importedFilesUseCurrentFolderWithoutOverwriting() async throws {
    let root = try temporaryFolder()
    let external = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: external)
    }
    let library = MediaLibrary(root: root, defaults: nil)
    try library.createFolder("Clips", in: "")
    let source = external.appendingPathComponent("clip.mov")
    let content = Data(repeating: 0xA7, count: MediaLocalFiles.chunkSize * 4 + 37)
    try content.write(to: source)
    let existing = root.appendingPathComponent("Clips/clip.mov")
    try Data("existing".utf8).write(to: existing)
    await library.importFiles([source], into: "Clips")
    let imported = try #require(library.files(in: "Clips").first { file in
        file != existing
    })
    #expect(imported.lastPathComponent.hasPrefix("clip-"))
    #expect(imported.pathExtension == "mov")
    #expect(try Data(contentsOf: imported) == content)
    #expect(try Data(contentsOf: source) == content)
    #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    #expect(library.files(in: "Clips").count == 2)
    #expect(library.notice == "Imported 1 file.")
    #expect(!library.isBusy)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: existing.deletingLastPathComponent().path)).contains {
        $0.hasPrefix(MediaLocalFiles.pendingPrefix)
    })
}

@Test @MainActor func importsRejectNetworkSchemesAndContinueWithLocalFiles() async throws {
    let root = try temporaryFolder()
    let external = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: external)
    }
    let source = external.appendingPathComponent("local.wav")
    try Data("local audio fixture".utf8).write(to: source)
    let library = MediaLibrary(root: root, defaults: nil)
    let remote = ["https://example.invalid/video.mp4", "http://example.invalid/audio.mp3",
        "blob:https://example.invalid/id", "data:video/mp4;base64,AA==", "file://example.invalid/video.mp4"]
    await library.importFiles(remote.compactMap(URL.init(string:)) + [source], into: "")
    #expect(library.files(in: "").map(\.lastPathComponent) == ["local.wav"])
    #expect(library.notice?.hasPrefix("Imported 1 file.") == true)
    #expect(library.notice?.contains("Choose a local file using Files.") == true)
    #expect(!library.isBusy)
}

@Test func copyingRefusesFoldersLinksAndInvalidNames() throws {
    let root = try temporaryFolder()
    let external = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: external)
    }
    let source = external.appendingPathComponent("original.mov")
    try Data("keep".utf8).write(to: source)
    let link = external.appendingPathComponent("link.mov")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    for invalid in [external, link, URL(string: "https://example.invalid/movie.mp4")!] {
        #expect(throws: (any Error).self) {
            _ = try MediaLocalFiles.copyFile(invalid, into: root)
        }
    }
    for name in ["../outside.mov", ".", "..", "bad\nname", "bad\u{0}name", MediaLocalFiles.pendingPrefix + "reserved"] {
        #expect(throws: (any Error).self) {
            _ = try MediaLocalFiles.copyFile(source, into: root, name: name)
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    #expect(try Data(contentsOf: source) == Data("keep".utf8))
}

@Test func failedPublishCleansStagedCopyAndPreservesExistingFile() throws {
    let root = try temporaryFolder()
    let external = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: external)
    }
    let name = "clip." + String(repeating: "x", count: 240)
    let source = external.appendingPathComponent(name)
    let existing = root.appendingPathComponent(name)
    try Data(repeating: 0x41, count: MediaLocalFiles.chunkSize + 1).write(to: source)
    try Data("existing".utf8).write(to: existing)
    // This collision cannot be given a unique suffix within the filesystem's name limit.
    #expect(throws: (any Error).self) {
        _ = try MediaLocalFiles.copyFile(source, into: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [name])
    #expect(try Data(contentsOf: existing) == Data("existing".utf8))
}

@Test @MainActor func creatingFilesDoesNotOverwriteAndHiddenFilesStayOptional() throws {
    let root = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let library = MediaLibrary(root: root, defaults: nil)
    try library.createFile("empty.txt", in: "")
    try library.createFile(".hidden.txt", in: "")
    let empty = root.appendingPathComponent("empty.txt")
    try Data("keep".utf8).write(to: empty)
    #expect(throws: (any Error).self) {
        try library.createFile("empty.txt", in: "")
    }
    #expect(try Data(contentsOf: empty) == Data("keep".utf8))
    #expect(library.files(in: "").map(\.lastPathComponent) == ["empty.txt"])
    library.settings.showHiddenFiles = true
    #expect(library.files(in: "").count == 2)
}

@Test func conversionRejectsRemoteInputAndOutput() async throws {
    let root = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let remote = URL(string: "https://example.invalid/video.mp4")!
    let local = root.appendingPathComponent("output.mp4")
    await #expect(throws: (any Error).self) {
        try await MediaExporter.convert(remote, settings: MediaSettings(), destination: local)
    }
    await #expect(throws: (any Error).self) {
        try await MediaExporter.convert(local, settings: MediaSettings(), destination: remote)
    }
    #expect(throws: (any Error).self) {
        _ = try MediaExporter.localAsset(remote)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func localConversionKeepsOriginalAndRestrictsExternalReferences() async throws {
    let root = try temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let original = root.appendingPathComponent("original.mov")
    let converted = root.appendingPathComponent("converted.mp4")
    try await makeVideo(original)
    let originalData = try Data(contentsOf: original)
    let asset = try MediaExporter.localAsset(original)
    #expect(asset.referenceRestrictions == .forbidAll)
    try await MediaExporter.convert(original, settings: MediaSettings(), destination: converted)
    #expect(try Data(contentsOf: original) == originalData)
    let output = try MediaExporter.localAsset(converted)
    #expect(!(try await output.loadTracks(withMediaType: .video)).isEmpty)
    let duration = try await output.load(.duration)
    #expect(duration.seconds > 0)
    let convertedData = try Data(contentsOf: converted)
    await #expect(throws: (any Error).self) {
        try await MediaExporter.convert(original, settings: MediaSettings(), destination: converted)
    }
    #expect(try Data(contentsOf: converted) == convertedData)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains {
        $0.hasPrefix(MediaLocalFiles.pendingPrefix)
    })
}

@Test func localAudioVideoAndRemoteClassification() {
    #expect(MediaThumbnailCache.isAudio(URL(fileURLWithPath: "/tmp/sound.m4a")))
    #expect(MediaThumbnailCache.isPlayable(URL(fileURLWithPath: "/tmp/sound.wav")))
    #expect(MediaThumbnailCache.isVideo(URL(fileURLWithPath: "/tmp/movie.mov")))
    #expect(!MediaThumbnailCache.isPlayable(URL(string: "https://example.invalid/movie.mp4")!))
}

private func makeVideo(_ file: URL) async throws {
    let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 640, AVVideoHeightKey: 360])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32ARGB, nil, &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let address = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<360 {
        for x in 0..<640 {
            let offset = y * stride + x * 4
            address[offset] = 255; address[offset + 1] = 230; address[offset + 2] = 30; address[offset + 3] = 20
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for frame in 0..<30 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

@Test func compressedFirstFrameAndPersistentCacheSurviveRename() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("fixture.mov")
    try await makeVideo(movie)
    let cacheFolder = root.appendingPathComponent("Cache")
    let cache = MediaThumbnailCache(directory: cacheFolder)
    let data = try #require(await cache.thumbnail(for: movie))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width <= 320 && image.height <= 240)
    #expect(data.count < 50_000)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    #expect(pixel[0] > 180 && pixel[1] < 80 && pixel[2] < 80, "thumbnail must contain the decoded red frame")
    let renamed = root.appendingPathComponent("renamed.mov")
    try FileManager.default.moveItem(at: movie, to: renamed)
    #expect(await cache.thumbnail(for: renamed) == data)
    let reopened = MediaThumbnailCache(directory: cacheFolder)
    #expect(await reopened.thumbnail(for: renamed) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheFolder.path).count == 1)
    let folder = root.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let moved = folder.appendingPathComponent("renamed.mov")
    try FileManager.default.moveItem(at: renamed, to: moved)
    #expect(await reopened.thumbnail(for: moved) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheFolder.path).count == 1)
    let exported = root.appendingPathComponent("exported.mov")
    try FileManager.default.copyItem(at: moved, to: exported)
    await reopened.seed(data, for: exported)
    #expect(await reopened.thumbnail(for: exported) == data)
    // Replacing the media at the same path must not return an obsolete thumbnail.
    try FileManager.default.removeItem(at: moved)
    try Data("not a video".utf8).write(to: moved)
    #expect(await reopened.thumbnail(for: moved) == nil)
}
