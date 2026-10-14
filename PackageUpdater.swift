import Combine
import Foundation

/// Checks npm dist-tags on each foreground event. Debug builds install version-pinned,
/// SHA-256-checked jsDelivr files; Release only reports versions for a future signed app update.
@MainActor
final class PackageUpdater: ObservableObject {
    @Published private(set) var status = UpdateStatus()
    @Published private(set) var isChecking = false
    @Published private(set) var catalog: ToolCatalog?

    init() {
        catalog = try? ToolCatalog.bundled()
        status = (try? PackageCache.status()) ?? UpdateStatus()
    }

    func check(enabled: Bool, force: Bool = false) async {
        guard (enabled || force) && !isChecking else {
            return
        }
        isChecking = true
        defer {
            isChecking = false
        }
        guard let catalog else {
            status.summary = "Bundled package catalog is missing. Rebuild the app resources."
            return
        }
        var errors: [String] = []
        var available: [String: String] = [:]
        var installed = status.installed
        for asset in catalog.assets {
            do {
                let version = try await latestVersion(of: asset.package)
                available[asset.id] = version
                let current = installed[asset.id]?.version ?? asset.version
                // A latest dist-tag may be rolled back upstream. Do not downgrade silently.
                guard PackageCache.remoteAssetsAllowed,
                      version.compare(current, options: .numeric) == .orderedDescending else {
                    continue
                }
                let metadataURL = URL(string: "https://data.jsdelivr.com/v1/package/npm/\(asset.package)@\(version)/flat")!
                let index = try await json(metadataURL)
                let files = index["files"] as? [[String: Any]] ?? []
                guard let entry = files.first(where: { ($0["name"] as? String) == "/" + asset.path }),
                      let expectedHash = entry["hash"] as? String else {
                    throw StorageError.invalidInput("The published bundle path changed; retaining the installed version.")
                }
                let scriptURL = URL(string: "https://cdn.jsdelivr.net/npm/\(asset.package)@\(version)/\(asset.path)")!
                let data = try await fetch(scriptURL, limit: 24_000_000)
                guard PackageCache.hash(data) == expectedHash,
                      let source = String(data: data, encoding: .utf8),
                      !source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
                    throw StorageError.invalidInput("Package integrity or JavaScript content check failed.")
                }
                let filename = "\(asset.id)-\(version).js"
                try data.write(to: PackageCache.directory().appendingPathComponent(filename), options: .atomic)
                installed[asset.id] = CachedTool(id: asset.id, version: version, sha256: expectedHash, file: filename)
            } catch {
                errors.append("\(asset.package): \(error.localizedDescription)")
            }
        }
        status.checkedAt = Date()
        status.available = available
        status.installed = installed
        if errors.isEmpty {
            status.summary = PackageCache.remoteAssetsAllowed
                ? "Update check complete. Cached updates apply on the next page load; bundled tools remain available offline."
                : "Version check complete. This Release build uses signed, bundled tools; install an app update for newer packages."
        } else {
            status.summary = "Kept working copies. " + errors.joined(separator: "\n")
        }
        do {
            try PackageCache.save(status)
        } catch {
            status.summary += "\nCould not save update status: \(error.localizedDescription)"
        }
    }

    func clearCache() {
        do {
            let directory = try PackageCache.directory()
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if file.pathExtension == "js" {
                    try FileManager.default.removeItem(at: file)
                }
            }
            status.installed = [:]
            status.summary = "Using bundled packages. Reload Safari pages to apply."
            try PackageCache.save(status)
        } catch {
            status.summary = error.localizedDescription
        }
    }

    private func latestVersion(of package: String) async throws -> String {
        let value: String?
        do {
            let metadata = try await json(URL(string: "https://registry.npmjs.org/\(package)/latest")!)
            value = metadata["version"] as? String
        } catch {
            // jsDelivr resolves the same latest npm release when the registry cannot be reached.
            let metadata = try await json(URL(string: "https://data.jsdelivr.com/v1/package/resolve/npm/\(package)@latest")!)
            value = metadata["version"] as? String
        }
        guard let value, value.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw StorageError.invalidInput("The latest tag is not a stable semantic version.")
        }
        return value
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        let data = try await fetch(url, limit: 4_000_000)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorageError.invalidInput("Invalid package metadata.")
        }
        return value
    }

    nonisolated private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let host = response.url?.host, ["registry.npmjs.org", "data.jsdelivr.com", "cdn.jsdelivr.net"].contains(host),
              response.url?.scheme == "https", response.expectedContentLength <= Int64(limit) else {
            throw StorageError.invalidInput("The package server returned an unexpected response.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else {
                throw StorageError.invalidInput("Package exceeds the download limit.")
            }
            data.append(byte)
        }
        return data
    }
}
