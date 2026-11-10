import Foundation

struct MediaSettings: Codable, Equatable {
    enum Container: String, Codable, CaseIterable {
        case mp4, mov
    }

    enum Codec: String, Codable, CaseIterable {
        case copy, h264, hevc
    }

    var container = Container.mp4
    var codec = Codec.copy
    var showHiddenFiles = false
    var defaultFolder = ""
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

/// File-only operations shared by importing, file management, and conversion.
enum MediaLocalFiles {
    static let chunkSize = 256 * 1024
    static let pendingPrefix = ".devtools-pending-"

    static func requireFileURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw MediaFailure.invalid("Choose a local file using Files.")
        }
    }

    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil, name.utf8.count <= 255,
              !name.hasPrefix(pendingPrefix) else {
            throw MediaFailure.invalid("Choose a valid file or folder name.")
        }
    }

    static func uniqueDestination(named name: String, in folder: URL) throws -> URL {
        try requireFileURL(folder)
        try validateName(name)
        guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw MediaFailure.invalid("Choose an existing destination folder.")
        }
        let original = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: original.path) {
            return original
        }
        let ext = original.pathExtension
        var stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let suffix = "-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        guard suffix.utf8.count < 255 else {
            throw MediaFailure.invalid("The file extension is too long to create a separate copy.")
        }
        while stem.utf8.count + suffix.utf8.count > 255 {
            stem.removeLast()
        }
        let unique = stem + suffix
        try validateName(unique)
        return folder.appendingPathComponent(unique)
    }

    /// The security scope stays open for the entire coordinated read, including cloud file providers.
    static func importFile(_ source: URL, into folder: URL) throws -> URL {
        try requireFileURL(source)
        try requireFileURL(folder)
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result {
                try copyFile(coordinatedURL, into: folder, name: source.lastPathComponent)
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw MediaFailure.invalid("The selected file could not be opened.")
        }
        return try result.get()
    }

    /// Copy bounded chunks, then publish one complete file without overwriting another item.
    static func copyFile(_ source: URL, into folder: URL, name: String? = nil) throws -> URL {
        try requireFileURL(source)
        try requireFileURL(folder)
        let filename = name ?? source.lastPathComponent
        try validateName(filename)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MediaFailure.invalid("Import a regular file, rather than a folder or link.")
        }
        guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw MediaFailure.invalid("Choose an existing destination folder.")
        }
        try Task.checkCancellation()
        let pending = folder.appendingPathComponent(pendingPrefix + UUID().uuidString + ".partial")
        defer {
            try? FileManager.default.removeItem(at: pending)
        }
        try Data().write(to: pending, options: .withoutOverwriting)
        let input = try FileHandle(forReadingFrom: source)
        defer {
            try? input.close()
        }
        let output = try FileHandle(forWritingTo: pending)
        defer {
            try? output.close()
        }
        var bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let copied = try autoreleasepool { () throws -> Int in
                guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return 0
                }
                try output.write(contentsOf: chunk)
                return chunk.count
            }
            if copied == 0 {
                break
            }
            bytes += Int64(copied)
        }
        if let expected = values.fileSize, Int64(expected) != bytes {
            throw MediaFailure.invalid("The selected file changed while it was being imported. Try again.")
        }
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        let destination = try uniqueDestination(named: filename, in: folder)
        try FileManager.default.moveItem(at: pending, to: destination)
        return destination
    }
}
