import SafariServices
import Foundation

/// Receives messages only through Safari's native-messaging extension boundary.
/// The JavaScript background authenticates the UI sender before forwarding mutations.
final class SafariWebExtensionHandler: NSObject, @MainActor NSExtensionRequestHandling {
    @MainActor func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = (item?.userInfo?[SFExtensionMessageKey] as? [String: Any]) ?? [:]
        let result: [String: Any]
        do {
            result = try handle(message)
        } catch {
            result = ["error": error.localizedDescription]
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: result]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    @MainActor private func handle(_ message: [String: Any]) throws -> [String: Any] {
        switch message["operation"] as? String {
        case "snapshot":
            let config = try SharedStore.shared.read()
            var response: [String: Any] = [
                "config": try config.bridgeObject(),
                "remoteAssetsAllowed": PackageCache.remoteAssetsAllowed
            ]
            if let ticket = message["ticket"] as? String,
               let url = message["url"] as? String,
               let command = try SharedStore.shared.command(id: ticket, url: url) {
                response["command"] = ["id": command.id, "action": command.action]
            }
            return response
        case "setEnabled":
            guard let value = message["value"] as? Bool else {
                throw StorageError.invalidInput("Expected a Boolean setting.")
            }
            try SharedStore.shared.update {
                $0.enabled = value
            }
            return ["ok": true]
        case "addRule":
            guard let listID = message["listID"] as? String,
                  let kindValue = message["kind"] as? String,
                  let kind = RuleKind(rawValue: kindValue),
                  let pattern = message["pattern"] as? String else {
                throw StorageError.invalidInput("Incomplete rule.")
            }
            let rule = SiteRule(kind: kind, pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines))
            try RuleValidator.validate(rule)
            try SharedStore.shared.update { config in
                guard let index = config.lists.firstIndex(where: { $0.id == listID }) else {
                    throw StorageError.invalidInput("The selected list no longer exists.")
                }
                guard !config.lists[index].rules.contains(where: { $0.kind == rule.kind && $0.pattern == rule.pattern }) else {
                    return
                }
                config.lists[index].rules.append(rule)
            }
            return ["ok": true]
        case "asset":
            guard let id = message["id"] as? String else {
                throw StorageError.invalidInput("Missing package identifier.")
            }
            return ["source": try PackageCache.source(for: id) ?? ""]
        default:
            throw StorageError.invalidInput("Unsupported native operation.")
        }
    }
}
