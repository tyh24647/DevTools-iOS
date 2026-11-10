import Foundation
import Combine
import Photos
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class MediaLibrary: ObservableObject {
    @Published var settings: MediaSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                defaults?.set(data, forKey: "media-settings-v2")
            }
        }
    }
    @Published var notice: String?
    @Published var revision = 0
    @Published private(set) var operation: String?
    let root: URL
    var onPreviewRestore: (() -> Void)?
    private let defaults: UserDefaults?

    var isBusy: Bool {
        operation != nil
    }

    init(root: URL? = nil, defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        settings = defaults?.data(forKey: "media-settings-v2").flatMap {
            try? JSONDecoder().decode(MediaSettings.self, from: $0)
        } ?? MediaSettings()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? documents.appendingPathComponent("DevTools Media", isDirectory: true)
        do {
            try MediaLocalFiles.requireFileURL(self.root)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            if (try? directory(settings.defaultFolder)) == nil {
                settings.defaultFolder = ""
            }
        } catch {
            notice = "Could not open Media files: \(error.localizedDescription)"
        }
    }

    func directory(_ relative: String) throws -> URL {
        try MediaLocalFiles.requireFileURL(root)
        var url = root.standardizedFileURL
        if !relative.isEmpty {
            for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
                try MediaLocalFiles.validateName(String(component))
                url.appendPathComponent(String(component), isDirectory: true)
            }
        }
        let library = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = url.resolvingSymlinksInPath()
        guard resolved == library || resolved.path.hasPrefix(library.path + "/"),
              (try resolved.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw MediaFailure.invalid("Choose an existing folder inside Media files.")
        }
        return resolved
    }

    func files(in relative: String) -> [URL] {
        guard let folder = try? directory(relative) else {
            return []
        }
        let options: FileManager.DirectoryEnumerationOptions = settings.showHiddenFiles ? [] : [.skipsHiddenFiles]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: options)) ?? [])
            .filter { file in
                let values = try? file.resourceValues(forKeys: Set(keys))
                return !file.lastPathComponent.hasPrefix(MediaLocalFiles.pendingPrefix) && values?.isSymbolicLink != true &&
                    (values?.isDirectory == true || values?.isRegularFile == true)
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    func createFolder(_ name: String, in relative: String) throws {
        try requireIdle()
        try MediaLocalFiles.validateName(name)
        try FileManager.default.createDirectory(at: directory(relative).appendingPathComponent(name), withIntermediateDirectories: false)
        revision += 1
    }

    func createFile(_ name: String, in relative: String) throws {
        try requireIdle()
        try MediaLocalFiles.validateName(name)
        let file = try directory(relative).appendingPathComponent(name)
        try Data().write(to: file, options: .withoutOverwriting)
        revision += 1
    }

    private func requireIdle() throws {
        guard !isBusy else {
            throw MediaFailure.invalid("Wait for the current file operation to finish.")
        }
    }

    private func checkedLibraryItem(_ file: URL) throws -> URL {
        try requireIdle()
        try MediaLocalFiles.requireFileURL(file)
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        let library = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(library.path + "/"),
              (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw MediaFailure.invalid("Choose a file inside Media files.")
        }
        return resolved
    }

    func delete(_ file: URL) throws {
        let source = try checkedLibraryItem(file)
        let selectedFolder = try? directory(settings.defaultFolder)
        try FileManager.default.removeItem(at: source)
        if let selectedFolder, selectedFolder == source || selectedFolder.path.hasPrefix(source.path + "/") {
            settings.defaultFolder = ""
        }
        revision += 1
    }

    func relocate(_ file: URL, to relative: String, name: String? = nil) throws {
        let source = try checkedLibraryItem(file)
        let filename = name ?? file.lastPathComponent
        try MediaLocalFiles.validateName(filename)
        let folder = try directory(relative)
        guard folder != source, !folder.path.hasPrefix(source.path + "/") else {
            throw MediaFailure.invalid("Choose a destination folder outside this item.")
        }
        let target = folder.appendingPathComponent(filename)
        if target == source {
            return
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MediaFailure.invalid("An item with that name already exists in this folder.")
        }
        let selectedFolder = try? directory(settings.defaultFolder)
        try FileManager.default.moveItem(at: source, to: target)
        if let selectedFolder, selectedFolder == source || selectedFolder.path.hasPrefix(source.path + "/") {
            let suffix = String(selectedFolder.path.dropFirst(source.path.count))
            let library = root.standardizedFileURL.resolvingSymlinksInPath()
            settings.defaultFolder = String((target.path + suffix).dropFirst(library.path.count + 1))
        }
        revision += 1
    }

    func destinationFolders(excluding file: URL? = nil) -> [String] {
        var folders = [""]
        guard let library = try? directory(""),
              let enumerator = FileManager.default.enumerator(at: library,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            return folders
        }
        let excluded = file?.standardizedFileURL.resolvingSymlinksInPath()
        for case let folder as URL in enumerator {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isExcluded = excluded.map { item in
                folder == item || folder.path.hasPrefix(item.path + "/")
            } ?? false
            if values?.isSymbolicLink == true || isExcluded {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                folders.append(String(folder.path.dropFirst(library.path.count + 1)))
            }
        }
        return folders.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func importFiles(_ files: [URL], into relative: String) async {
        do {
            try requireIdle()
            let destination = try directory(relative)
            guard !files.isEmpty else {
                return
            }
            operation = "Importing files…"
            defer {
                operation = nil
            }
            var imported = 0
            var failures: [String] = []
            for file in files {
                operation = "Importing \(file.lastPathComponent)…"
                do {
                    let copy = Task.detached(priority: .userInitiated) {
                        try MediaLocalFiles.importFile(file, into: destination)
                    }
                    _ = try await withTaskCancellationHandler {
                        try await copy.value
                    } onCancel: {
                        copy.cancel()
                    }
                    imported += 1
                    revision += 1
                } catch {
                    failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
                if Task.isCancelled {
                    break
                }
            }
            let summary = imported == 1 ? "Imported 1 file." : "Imported \(imported) files."
            notice = failures.isEmpty ? summary : summary + "\n\n" + failures.prefix(3).joined(separator: "\n")
        } catch {
            notice = error.localizedDescription
        }
    }

    func convert(_ file: URL) async {
        do {
            let source = try checkedLibraryItem(file)
            let outputSettings = settings
            let destination = try directory(outputSettings.defaultFolder)
            let name = source.deletingPathExtension().lastPathComponent + " converted." + outputSettings.container.rawValue
            let target = try MediaLocalFiles.uniqueDestination(named: name, in: destination)
            operation = "Converting \(source.lastPathComponent)…"
            defer {
                operation = nil
            }
            try await MediaExporter.convert(source, settings: outputSettings, destination: target)
            revision += 1
            notice = "Saved \(target.lastPathComponent). The original file is unchanged."
        } catch {
            notice = "Could not convert this file: \(error.localizedDescription) The original file is unchanged."
        }
    }

    func saveToPhotos(_ file: URL) async {
        do {
            let source = try checkedLibraryItem(file)
            let isImage = UTType(filenameExtension: source.pathExtension)?.conforms(to: .image) == true
            guard isImage || MediaThumbnailCache.isVideo(source) else {
                throw MediaFailure.invalid("Choose a local photo or video to save to Photos.")
            }
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else {
                throw MediaFailure.invalid("This file is empty. Import a complete photo or video first.")
            }
            operation = "Saving to Photos…"
            defer {
                operation = nil
            }
            if !isImage {
                let asset = try MediaExporter.localAsset(source)
                guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw MediaFailure.invalid("This file does not contain a readable video track.")
                }
                guard !(try await asset.load(.hasProtectedContent)) else {
                    throw MediaFailure.invalid("This video is protected and cannot be exported to Photos.")
                }
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                notice = "Allow Photos access to save this media. You can still export it through Share."
                return
            }
            let compatible = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer {
                try? FileManager.default.removeItem(at: compatible)
            }
            func importFile(_ url: URL) async throws {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: isImage ? .photo : .video, fileURL: url, options: nil)
                }
            }
            do {
                try await importFile(source)
            } catch {
                let photosError = error as NSError
                guard !isImage, photosError.domain == PHPhotosErrorDomain, photosError.code == 3302 else {
                    throw error
                }
                operation = "Preparing a Photos-compatible video…"
                var outputSettings = MediaSettings()
                outputSettings.container = .mp4
                outputSettings.codec = .h264
                try await MediaExporter.convert(source, settings: outputSettings, destination: compatible)
                try await importFile(compatible)
            }
            notice = "Saved to Photos."
        } catch {
            notice = "Could not save to Photos: \(error.localizedDescription) The original remains in Media files; Share is still available."
        }
    }
}
