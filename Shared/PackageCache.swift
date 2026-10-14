import Foundation
import CryptoKit

struct CachedTool: Codable {
    var id: String
    var version: String
    var sha256: String
    var file: String
}

struct UpdateStatus: Codable {
    var checkedAt: Date?
    var summary = "Bundled tools are ready offline."
    var available: [String: String] = [:]
    var installed: [String: CachedTool] = [:]
}

/// All remote code is excluded from the Release execution path. Debug supports the requested
/// automatic package installation for personal development, with an immutable bundled fallback.
@MainActor enum PackageCache {
    static var remoteAssetsAllowed: Bool {
        #if DEVTOOLS_REMOTE_UPDATES
        return true
        #else
        return false
        #endif
    }

    @MainActor static func directory() throws -> URL {
        let url = try SharedStore.shared.directory().appendingPathComponent("ToolPackages", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor static func status() throws -> UpdateStatus {
        let url = try directory().appendingPathComponent("status.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return UpdateStatus()
        }
        return try JSONDecoder().decode(UpdateStatus.self, from: Data(contentsOf: url))
    }

    @MainActor static func save(_ status: UpdateStatus) throws {
        let url = try directory().appendingPathComponent("status.json")
        try JSONEncoder().encode(status).write(to: url, options: .atomic)
    }

    static func hash(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    /// Build the same local CommonJS scope used by Scripts/vendor.mjs without touching page globals.
    @MainActor static func source(for id: String) throws -> String? {
        guard remoteAssetsAllowed,
              try SharedStore.shared.read().automaticallyInstallUpdates,
              try ToolCatalog.bundled().assets.contains(where: { $0.id == id }),
              let entry = try status().installed[id],
              entry.file == "\(id)-\(entry.version).js" else {
            return nil
        }
        let data = try Data(contentsOf: directory().appendingPathComponent(entry.file))
        guard hash(data) == entry.sha256, let source = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidInput("Cached package failed its integrity check; using the bundled copy.")
        }
        let key = String(data: try JSONEncoder().encode(id), encoding: .utf8)!
        let version = String(data: try JSONEncoder().encode(entry.version), encoding: .utf8)!
        return """
        (function () {
            if (globalThis.__DTExpectedURL !== location.href || globalThis.__DTAssets?.[\(key)]) {
                return;
            }
            var module = { exports: {} };
            var exports = module.exports;
            var define;
            var process = { env: { NODE_ENV: "production" } };
            \(source)
            ;globalThis.__DTAssets = globalThis.__DTAssets || {};
            globalThis.__DTAssets[\(key)] = module.exports.default || module.exports;
            globalThis.__DTVersions = globalThis.__DTVersions || {};
            globalThis.__DTVersions[\(key)] = \(version);
        }).call(globalThis);
        """
    }
}
