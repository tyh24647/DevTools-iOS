import Foundation

/// A bounded HLS parser. Remote URLs are resolved before local manifests are authored.
struct HLSPlaylist {
    struct ByteRange: Codable, Equatable {
        var offset: Int64
        var length: Int64
    }
    struct Key: Codable, Equatable {
        var url: URL
        var iv: String?
    }
    struct Initialization: Codable, Equatable {
        var url: URL
        var range: ByteRange?
    }
    struct Segment: Codable, Equatable {
        var url: URL
        var sequence: Int64
        var duration: Double
        var range: ByteRange?
        var initialization: Initialization?
        var key: Key?
        var discontinuity: Bool
    }
    struct Variant: Identifiable {
        var url: URL
        var bandwidth: Int64
        var width: Int
        var height: Int
        var audioGroup: String?
        var id: String { url.absoluteString }
        var label: String { height > 0 ? "\(height)p" : "\(bandwidth / 1000) kbps" }
    }
    var variants: [Variant] = []
    var audio: [String: URL] = [:]
    var segments: [Segment] = []
    var ended = false
    var targetDuration = 6.0

    static func parse(_ source: String, base: URL) throws -> HLSPlaylist {
        guard source.utf8.count <= 2 * 1024 * 1024,
              source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw MediaFailure.invalid("Not a supported HLS playlist.")
        }
        func resolve(_ text: String) throws -> URL {
            guard let url = URL(string: text, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else {
                throw MediaFailure.invalid("Media URLs must be HTTP(S), without embedded credentials.")
            }
            return url
        }
        func attributes(_ line: String) -> [String: String] {
            let expression = try! NSRegularExpression(pattern: "([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)")
            let text = String(line.split(separator: ":", maxSplits: 1).last ?? "") as NSString
            return Dictionary(expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map {
                (text.substring(with: $0.range(at: 1)), text.substring(with: $0.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }, uniquingKeysWith: { _, latest in latest })
        }
        func range(_ text: String?, previous: Int64?) throws -> ByteRange? {
            guard let text else {
                return nil
            }
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 2, let length = Int64(parts[0]), length > 0,
                  let offset = parts.count == 2 ? Int64(parts[1]) : previous,
                  offset >= 0, offset <= Int64.max - length else {
                throw MediaFailure.invalid("Invalid or missing HLS byte-range offset.")
            }
            return ByteRange(offset: offset, length: length)
        }
        var result = HLSPlaylist()
        var variant: [String: String]?
        var sequence: Int64 = 0
        var duration = 0.0
        var rangeText: String?
        var nextOffset: Int64?
        var previousURL: URL?
        var initialization: Initialization?
        var key: Key?
        var discontinuity = false
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(line.split(separator: ":", maxSplits: 1).last ?? "")
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                variant = attributes(line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let values = attributes(line)
                if values["TYPE"] == "AUDIO", let group = values["GROUP-ID"], let uri = values["URI"],
                   values["DEFAULT"] == "YES" || result.audio[group] == nil {
                    result.audio[group] = try resolve(uri)
                }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard let value = Int64(content), value >= 0 else {
                    throw MediaFailure.invalid("Invalid HLS media sequence.")
                }
                sequence = value
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                guard let value = Double(content), value.isFinite, value > 0, value <= 86400 else {
                    throw MediaFailure.invalid("Invalid HLS target duration.")
                }
                result.targetDuration = value
            } else if line.hasPrefix("#EXTINF:") {
                guard let value = Double(content.split(separator: ",").first ?? ""), value.isFinite, value > 0, value <= 86400 else {
                    throw MediaFailure.invalid("Invalid HLS segment duration.")
                }
                duration = value
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                rangeText = content
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let values = attributes(line)
                guard let uri = values["URI"] else {
                    throw MediaFailure.invalid("Missing HLS initialization URL.")
                }
                initialization = Initialization(url: try resolve(uri), range: try range(values["BYTERANGE"], previous: 0))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let values = attributes(line)
                if values["METHOD"] == "NONE" {
                    key = nil
                } else if values["METHOD"] == "AES-128", values["KEYFORMAT"] == nil || values["KEYFORMAT"] == "identity",
                          let uri = values["URI"] {
                    key = Key(url: try resolve(uri), iv: values["IV"])
                } else {
                    throw MediaFailure.invalid("DRM and SAMPLE-AES media are not supported for saving.")
                }
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if line == "#EXT-X-ENDLIST" {
                result.ended = true
            } else if !line.isEmpty && !line.hasPrefix("#") {
                let url = try resolve(line)
                if let values = variant {
                    let dimensions = (values["RESOLUTION"] ?? "").split(separator: "x")
                    result.variants.append(Variant(url: url, bandwidth: Int64(values["AVERAGE-BANDWIDTH"] ?? values["BANDWIDTH"] ?? "0") ?? 0,
                                                   width: dimensions.count == 2 ? min(16384, max(0, Int(dimensions[0]) ?? 0)) : 0,
                                                   height: dimensions.count == 2 ? min(16384, max(0, Int(dimensions[1]) ?? 0)) : 0, audioGroup: values["AUDIO"]))
                    variant = nil
                } else {
                    guard duration > 0, sequence < Int64.max else {
                        throw MediaFailure.invalid("A segment must have a valid duration and sequence.")
                    }
                    let bytes = try range(rangeText, previous: previousURL == url ? nextOffset : nil)
                    result.segments.append(Segment(url: url, sequence: sequence, duration: duration, range: bytes,
                                                   initialization: initialization, key: key, discontinuity: discontinuity))
                    guard result.segments.count <= 100_000 else {
                        throw MediaFailure.invalid("Playlist exceeds the segment limit.")
                    }
                    sequence += 1
                    previousURL = url
                    nextOffset = bytes.map { $0.offset + $0.length }
                    duration = 0
                    rangeText = nil
                    discontinuity = false
                }
            }
        }
        return result
    }
}

enum MediaFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}
