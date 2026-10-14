import Foundation
import Darwin

/// Serializes read/modify/write operations across the containing app and extension processes.
/// Atomic replacement prevents readers from observing a partly written configuration.
@MainActor
final class SharedStore {
    static let shared = SharedStore()
    private let lock = NSRecursiveLock()

    static var groupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "DevToolsAppGroup") as? String ?? "group.com.tyh24647.DevTools"
    }

    func directory() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupIdentifier) else {
            throw StorageError.missingAppGroup
        }
        return url
    }

    func read() throws -> AppConfiguration {
        try coordinated {
            try readUnlocked()
        }
    }

    @discardableResult
    func update(_ mutation: (inout AppConfiguration) throws -> Void) throws -> AppConfiguration {
        try coordinated {
            var value = try readUnlocked()
            try mutation(&value)
            value.commands.removeAll {
                Date().timeIntervalSince1970 - $0.createdAt > 120
            }
            value.revision = UUID().uuidString
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = try directory().appendingPathComponent("configuration.json")
            try encoder.encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return value
        }
    }

    func command(id: String, url: String) throws -> PageCommand? {
        let snapshot = try read()
        return snapshot.commands.last {
            $0.id == id && $0.url == url && Date().timeIntervalSince1970 - $0.createdAt < 120
        }
    }

    private func readUnlocked() throws -> AppConfiguration {
        let url = try directory().appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfiguration()
        }
        // A corrupt file must produce an error, not silently restore "run everywhere".
        return try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
    }

    private func coordinated<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        let lockURL = try directory().appendingPathComponent("configuration.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw StorageError.fileLock
        }
        defer {
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw StorageError.fileLock
        }
        defer {
            flock(descriptor, LOCK_UN)
        }
        return try body()
    }
}

