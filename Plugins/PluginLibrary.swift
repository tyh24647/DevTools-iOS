import Foundation
import Combine
import JavaScriptCore

struct UserPlugin: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var kind: String
    var source: String
    var enabled = false
    var folder = ""
    var tags = ""
}

@MainActor
final class PluginLibrary: ObservableObject {
    @Published private(set) var rows: [UserPlugin] = []
    @Published var error: String?
    private let file: URL

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("plugins-v2.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                rows = try JSONDecoder().decode([UserPlugin].self, from: Data(contentsOf: file))
                guard rows.count <= 20, rows.allSatisfy({ $0.source.utf8.count <= 256 * 1024 }) else {
                    throw MediaFailure.invalid("Stored scripts exceed their limits.")
                }
            } catch {
                self.error = "Scripts could not be read. No stored code will run: \(error.localizedDescription)"
                rows = []
            }
        } else if let url = Bundle.main.url(forResource: "BrowserResources", withExtension: nil)?.appendingPathComponent("css-editor-plugin.js"),
                  let css = try? String(contentsOf: url, encoding: .utf8) {
            rows = [UserPlugin(name: "Page CSS editor", kind: "eruda", source: css, enabled: true, tags: "CSS")]
        }
        // Update only the unmodified bundled CSS editor; preserve user-edited plugins.
        if let url = Bundle.main.url(forResource: "BrowserResources", withExtension: nil)?.appendingPathComponent("css-editor-plugin.js"),
           let css = try? String(contentsOf: url, encoding: .utf8) {
            let legacy = css.replacingOccurrences(of: "\n    root.style.cssText += \";height:100%;overflow:auto;color-scheme:light dark;background:Canvas;color:CanvasText;box-sizing:border-box\";\n    element.hide();", with: "")
            var updated = rows
            var changed = false
            for index in updated.indices where updated[index].kind == "eruda" && updated[index].name == "Page CSS editor" && updated[index].source == legacy {
                updated[index].source = css
                changed = true
            }
            if changed {
                do { try write(updated) }
                catch { self.error = "The bundled CSS editor could not be updated: \(error.localizedDescription)" }
            }
        }
    }

    func save(_ row: UserPlugin) throws {
        guard row.source.utf8.count <= 256 * 1024, !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaFailure.invalid("Name the script and keep its source below 256 KB.")
        }
        var next = rows
        if let index = next.firstIndex(where: { $0.id == row.id }) {
            var edited = row
            if edited.source != next[index].source || edited.kind != next[index].kind {
                edited.enabled = false
            }
            next[index] = edited
        } else {
            guard next.count < 20 else {
                throw MediaFailure.invalid("The script library supports up to 20 scripts.")
            }
            next.append(row)
        }
        try write(next)
    }

    func enable(_ id: String, value: Bool) throws {
        var next = rows
        guard let index = next.firstIndex(where: { $0.id == id }) else {
            return
        }
        if value {
            try validate(next[index])
        }
        next[index].enabled = value
        try write(next)
    }

    func delete(_ id: String) throws {
        try write(rows.filter { $0.id != id })
    }

    /// Compile without executing user source. Metadata validation is the same bounded
    /// userscript implementation shipped by the Android app; unsupported grants fail.
    func validate(_ row: UserPlugin) throws {
        guard row.source.utf8.count <= 256 * 1024 else {
            throw MediaFailure.invalid("Script exceeds 256 KB.")
        }
        let context = JSContext()!
        if row.kind == "userscript" {
            let url = Bundle.main.url(forResource: "BrowserResources", withExtension: nil)!.appendingPathComponent("userscripts.js")
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            context.evaluateScript("__DTUserscripts.metadata(\(Self.json(row.source)))")
            if let exception = context.exception {
                throw MediaFailure.invalid(exception.toString() ?? "Invalid script")
            }
        }
        context.evaluateScript("new Function(\(Self.json(row.source)))")
        if let exception = context.exception {
            throw MediaFailure.invalid(exception.toString() ?? "Invalid script")
        }
    }

    private func write(_ next: [UserPlugin]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        rows = next
        error = nil
    }

    static func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
