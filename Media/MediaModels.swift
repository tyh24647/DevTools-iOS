import Foundation
import Combine

struct MediaSettings: Codable, Equatable {
    enum Container: String, Codable, CaseIterable {
        case mp4, mov
    }
    enum Codec: String, Codable, CaseIterable {
        case copy, h264, hevc
    }
    var container = Container.mp4
    var codec = Codec.copy
    var partLimitMB = 2048
    var splitAndContinue = false
    var stopOnSourceLeave = true
    var showQuality = false
    var showHiddenFiles = false
    var defaultFolder = ""
}

struct PageMedia: Identifiable, Equatable {
    var url: String
    var page: String
    var tabID: UUID
    var title: String
    var hls: Bool
    var mime: String
    var id: String { "\(tabID.uuidString):\(url)" }
    var isBlob: Bool { url.hasPrefix("blob:") }
}

struct MediaChoice: Identifiable {
    var video: URL
    var audio: URL?
    var live: Bool
    var label: String
    var id: String { video.absoluteString }
}

/// Checkpoint files reference only generated basenames inside their own recording directory.
struct CapturedSegment: Codable {
    var file: String
    var duration: Double
    var initialization: String?
    var discontinuity: Bool
}

struct RecordingCheckpoint: Codable {
    var id: UUID
    var title: String
    var settings: MediaSettings
    var folder: String
    var streams: [[CapturedSegment]]
    var rawStreams: [String]
    var rawKinds: [String]? = nil
    var finalized = false
    var reason = ""
}

@MainActor
final class MediaTransfer: ObservableObject, Identifiable {
    let id: UUID
    let startedAt = Date()
    let source: PageMedia
    let settings: MediaSettings
    @Published var live = false
    @Published var state = "Queued"
    @Published var bytes: Int64 = 0
    @Published var duration: Double = 0
    @Published var progress: Double?
    @Published var outputs: [URL] = []
    @Published var error: String?
    @Published var finished = false
    var pendingExports = 0
    var captureEnded = false
    var recorder: HLSRecorder?
    var task: Task<Void, Never>?
    var exportTail: Task<Void, Never>?
    var ingressClosed = false
    var blobFolder: URL?
    var blobFiles: [Int: URL] = [:]
    var blobKinds: [Int: String] = [:]
    var blobHandles: [Int: FileHandle] = [:]
    var blobSequences: [Int: Int] = [:]

    init(source: PageMedia, settings: MediaSettings, id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.settings = settings
    }
}
