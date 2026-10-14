import Foundation
import UIKit

/// Rules are persisted once in the App Group and shared by the app and all seven extensions.
enum ListKind: String, Codable, CaseIterable, Identifiable {
    case allow
    case block

    var id: String {
        rawValue
    }

    var title: String {
        self == .allow ? "AllowList" : "Blacklist"
    }
}

enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case domain
    case url
    case wildcard
    case regex

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .domain:
            return "Domain & subdomains"
        case .url:
            return "Exact URL"
        case .wildcard:
            return "Wildcard"
        case .regex:
            return "Regular expression"
        }
    }
}

struct SiteRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: RuleKind = .domain
    var pattern: String
    var enabled = true
}

struct RuleList: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var kind: ListKind
    var selected = true
    var rules: [SiteRule] = []
}

struct ConsoleOptions: Codable, Equatable {
    var displaySize = 55.0
    var transparency = 0.98
    var theme = "Material Palenight"
    var rememberPosition = true
    var positionX = 263.807642
    var positionY = 0.0
    var backend = "eruda"
    var vueAdapter = "modern"
    var vue = true
    var resourceTiming = true
    var code = true
    var dom = true
    var fps = false
    var timing = true
    var features = false
}

/// Cached only from verified StoreKit transactions; never accepted from JavaScript messages.
struct EntitlementSnapshot: Codable, Equatable {
    // Persisted properties
    var lifetime: Bool
    var subscriptionExpiresAt: Double?
    var verifiedAt: Double?

    // Derived, not persisted
    var isPro: Bool {
        lifetime || (subscriptionExpiresAt ?? 0) > Date().timeIntervalSince1970
    }

    /*
    // Stable default initializer (no UIKit dependencies)
    init(lifetime: Bool = false, subscriptionExpiresAt: Double? = nil, verifiedAt: Double? = nil) {
        self.lifetime = lifetime
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.verifiedAt = verifiedAt
    }
     */
    
    // Stable default initializer (no UIKit dependencies)
    init(lifetime: Bool = false, subscriptionExpiresAt: Double? = nil, verifiedAt: Double? = nil) {
        self.lifetime = lifetime
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.verifiedAt = verifiedAt
    }
    

    // Codable
    private enum CodingKeys: String, CodingKey {
        case lifetime
        case subscriptionExpiresAt
        case verifiedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lifetime = try c.decodeIfPresent(Bool.self, forKey: .lifetime) ?? false
        self.subscriptionExpiresAt = try c.decodeIfPresent(Double.self, forKey: .subscriptionExpiresAt)
        self.verifiedAt = try c.decodeIfPresent(Double.self, forKey: .verifiedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lifetime, forKey: .lifetime)
        try c.encodeIfPresent(subscriptionExpiresAt, forKey: .subscriptionExpiresAt)
        try c.encodeIfPresent(verifiedAt, forKey: .verifiedAt)
    }
}

struct PageCommand: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var url: String
    var action: String
    var createdAt = Date().timeIntervalSince1970
}

struct AppConfiguration: Codable, Equatable {
    var schema = 1
    var revision = UUID().uuidString
    var enabled = true
    var runEverywhere = true
    var automaticallyInstallUpdates = true
    var appearance = "system"
    var accent = "blue"
    var console = ConsoleOptions()
    var entitlement = EntitlementSnapshot(lifetime: true)
    var lists: [RuleList] = [
        RuleList(id: "default-allow", name: "My development sites", kind: .allow),
        RuleList(id: "default-block", name: "Excluded sites", kind: .block)
    ]
    var commands: [PageCommand] = []

    /// JavaScript receives only settings it needs; it cannot replace this configuration.
    func bridgeObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        var object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        object["pro"] = entitlement.isPro
        object.removeValue(forKey: "entitlement")
        object.removeValue(forKey: "commands")
        return object
    }
}

struct ToolAsset: Codable, Identifiable {
    var id: String
    var package: String
    var version: String
    var path: String
    var file: String
    var global: String
    var sha256: String
    var license: String
}

struct ToolCatalog: Codable {
    var generatedAt: String
    var assets: [ToolAsset]

    static func bundled() throws -> ToolCatalog {
        guard let url = Bundle.main.url(forResource: "tool-catalog", withExtension: "json") else {
            throw StorageError.missingResource("tool-catalog.json")
        }
        return try JSONDecoder().decode(ToolCatalog.self, from: Data(contentsOf: url))
    }
}

enum StorageError: LocalizedError {
    case missingAppGroup
    case missingResource(String)
    case invalidInput(String)
    case fileLock

    var errorDescription: String? {
        switch self {
        case .missingAppGroup:
            return "The shared App Group is unavailable. Check signing and the App Group entitlement for every target."
        case .missingResource(let name):
            return "A bundled resource is missing: \(name)."
        case .invalidInput(let message):
            return message
        case .fileLock:
            return "Could not lock the shared settings file. Try again."
        }
    }
}
