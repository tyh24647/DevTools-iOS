import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config = AppConfiguration()
    @Published var error: String?

    init() {
        reload()
    }

    var isPro: Bool {
        config.entitlement.isPro
    }

    var accent: Color {
        switch config.accent {
        case "purple":
            return .purple
        case "mint":
            return .mint
        case "pink":
            return .pink
        case "orange":
            return .orange
        default:
            return .blue
        }
    }

    var colorScheme: ColorScheme? {
        config.appearance == "dark" ? .dark : config.appearance == "light" ? .light : nil
    }

    func reload() {
        do {
            config = try SharedStore.shared.read()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Merge one mutation into the newest disk snapshot so extension edits cannot be overwritten
    /// by an older copy held in a SwiftUI view.
    func change(_ mutation: (inout AppConfiguration) throws -> Void) {
        error = nil
        do {
            config = try SharedStore.shared.update(mutation)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AppConfiguration, Value>) -> Binding<Value> {
        Binding(get: {
            self.config[keyPath: keyPath]
        }, set: { value in
            self.change {
                $0[keyPath: keyPath] = value
            }
        })
    }

    func consoleBinding<Value>(_ keyPath: WritableKeyPath<ConsoleOptions, Value>) -> Binding<Value> {
        Binding(get: {
            self.config.console[keyPath: keyPath]
        }, set: { value in
            guard self.isPro else {
                return
            }
            self.change {
                $0.console[keyPath: keyPath] = value
            }
        })
    }
}
