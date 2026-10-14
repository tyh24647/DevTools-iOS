import Foundation

/// Performs immediate input validation in the native editor. Safari uses rule-engine.js
/// as the authoritative evaluator; the web popup also offers an exact live-page test.
enum RuleValidator {
    static func validate(_ rule: SiteRule) throws {
        let value = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty && value.count <= 512 else {
            throw StorageError.invalidInput("Enter a pattern between 1 and 512 characters.")
        }
        switch rule.kind {
        case .domain:
            guard !value.contains(where: { " /?#@*".contains($0) }),
                  let url = URL(string: "https://" + value), url.host != nil,
                  url.port == nil else {
                throw StorageError.invalidInput("Enter a hostname without a scheme, port or path.")
            }
        case .url:
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw StorageError.invalidInput("Enter a complete HTTP or HTTPS URL.")
            }
        case .wildcard:
            guard ["https://", "http://", "*://"].contains(where: value.hasPrefix) else {
                throw StorageError.invalidInput("Start wildcards with https://, http:// or *://.")
            }
        case .regex:
            var body = value
            if value.hasPrefix("/"), let end = value.dropFirst().lastIndex(of: "/") {
                body = String(value[value.index(after: value.startIndex)..<end])
                let flags = value[value.index(after: end)...]
                guard flags.allSatisfy({ "imu".contains($0) }), Set(flags).count == flags.count else {
                    throw StorageError.invalidInput("Use only i, m and u regex flags.")
                }
            } else if value.hasPrefix("/") {
                throw StorageError.invalidInput("Close the regular expression with /.")
            }
            let restricted = #"\\[1-9]|\(\?[=!<]|\([^)]*[+*{][^)]*\)[+*{]|\([^)]*\|[^)]*\)[+*{]"#
            guard body.range(of: restricted, options: .regularExpression) == nil else {
                throw StorageError.invalidInput("Backreferences, lookarounds and repeated complex groups are not supported.")
            }
            let repeats = try NSRegularExpression(pattern: #"(?<!\\)[*+]|\{\d+(?:,\d*)?\}"#)
            guard repeats.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body)) <= 4 else {
                throw StorageError.invalidInput("Use no more than four variable-length repetitions.")
            }
            _ = try NSRegularExpression(pattern: body)
        }
    }
}
