import Testing
import Foundation
import AVFoundation
import ImageIO
import CoreVideo
@testable import DownloadsCore

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test @MainActor func renameMoveAndFolderReferences() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MediaLibrary(root: root)
    try library.createFolder("Clips", in: "")
    let file = root.appendingPathComponent("first.mp4")
    try Data("original".utf8).write(to: file)
    let completed = MediaTransfer()
    completed.finished = true
    completed.outputs = [file]
    library.transfers = [completed]
    try library.relocate(file, to: "Clips", name: "renamed.mp4")
    let moved = root.appendingPathComponent("Clips/renamed.mp4")
    #expect(try Data(contentsOf: moved) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(completed.outputs == [moved])
    library.settings.defaultFolder = "Clips"
    try library.relocate(root.appendingPathComponent("Clips"), to: "", name: "Movies")
    #expect(library.settings.defaultFolder == "Movies")
    #expect(completed.outputs.first?.lastPathComponent == "renamed.mp4")
    #expect(completed.outputs.first?.deletingLastPathComponent().lastPathComponent == "Movies")
}

@Test @MainActor func refuseOverwriteEscapeAndActiveFolders() throws {
    let root = try temporaryFolder()
    let outside = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let library = MediaLibrary(root: root)
    try library.createFolder("Clips", in: "")
    try library.createFolder("Nested", in: "Clips")
    let file = root.appendingPathComponent("original.mp4")
    try Data("keep".utf8).write(to: file)
    try Data("existing".utf8).write(to: root.appendingPathComponent("Clips/original.mp4"))
    #expect(throws: (any Error).self) { try library.relocate(file, to: "Clips") }
    #expect(throws: (any Error).self) { try library.relocate(file, to: "", name: "../escape.mp4") }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Outside"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try library.relocate(file, to: "Outside") }
    #expect(throws: (any Error).self) { try library.relocate(root.appendingPathComponent("Clips"), to: "Clips/Nested") }
    let active = MediaTransfer()
    active.settings.defaultFolder = "Clips/Nested"
    library.transfers = [active]
    #expect(throws: (any Error).self) { try library.delete(root.appendingPathComponent("Clips")) }
    #expect(throws: (any Error).self) { try library.relocate(root.appendingPathComponent("Clips"), to: "", name: "Busy") }
    #expect(!library.destinationFolders(excluding: root.appendingPathComponent("Clips")).contains("Clips/Nested"))
    #expect(!library.destinationFolders(excluding: file).contains("Outside"))
    #expect(try Data(contentsOf: file) == Data("keep".utf8))
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

@Test func segmentSnapshotIsIndependentOfCapture() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("init".utf8).write(to: root.appendingPathComponent("init.mp4"))
    try Data("segment".utf8).write(to: root.appendingPathComponent("s0.m4s"))
    let snapshot = try MediaThumbnailCache.stageSegment(folder: root,
        segment: CapturedSegment(file: "s0.m4s", duration: 2, initialization: "init.mp4", discontinuity: false))
    defer { try? FileManager.default.removeItem(at: snapshot) }
    try FileManager.default.removeItem(at: root)
    #expect(try Data(contentsOf: snapshot) == Data("initsegment".utf8))
}
