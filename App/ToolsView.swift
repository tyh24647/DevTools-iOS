import SwiftUI

struct ToolsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Included for everyone") {
                Label("JavaScript console & error capture", systemImage: "terminal")
                Label("Elements, network, resources & sources", systemImage: "network")
                Label("Multiple AllowLists and blacklists", systemImage: "line.3.horizontal.decrease.circle")
            }
            if !model.isPro {
                Section {
                    NavigationLink {
                        ProView()
                    } label: {
                        HStack {
                            Text("Unlock additional tools")
                            Spacer()
                            ProBadge()
                        }
                    }
                }
            }
            Section {
                Picker("Console", selection: model.consoleBinding(\.backend)) {
                    Text("Eruda").tag("eruda")
                    Text("vConsole + Vue").tag("vconsole")
                }
                Toggle("Vue DevTools", isOn: model.consoleBinding(\.vue))
                if model.config.console.backend == "eruda" {
                    Picker("Vue adapter", selection: model.consoleBinding(\.vueAdapter)) {
                        Text("eruda-vue (current)").tag("modern")
                        Text("eruda-vue-devtools (legacy)").tag("legacy")
                    }
                    Toggle("Resource timing waterfall", isOn: model.consoleBinding(\.resourceTiming))
                    Toggle("Navigation timing", isOn: model.consoleBinding(\.timing))
                    Toggle("Code editor", isOn: model.consoleBinding(\.code))
                    Toggle("DOM explorer", isOn: model.consoleBinding(\.dom))
                    Toggle("Frame-rate monitor", isOn: model.consoleBinding(\.fps))
                    Toggle("Browser feature detection", isOn: model.consoleBinding(\.features))
                }
            } header: {
                HStack {
                    Text("Pro plugins")
                    ProBadge()
                }
            } footer: {
                Text("Choose one console and one Vue adapter to avoid competing hooks. Eruda plugins are available with the Eruda console. Vue introspection depends on the page’s Vue build and DevTools hooks.")
            }
            .disabled(!model.isPro)
            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Panel height", value: "\(Int(model.config.console.displaySize))%")
                    Slider(value: model.consoleBinding(\.displaySize), in: 40...100, step: 1)
                }
                VStack(alignment: .leading) {
                    LabeledContent("Opacity", value: "\(Int(model.config.console.transparency * 100))%")
                    Slider(value: model.consoleBinding(\.transparency), in: 0.2...1, step: 0.01)
                }
                Picker("Theme", selection: model.consoleBinding(\.theme)) {
                    ForEach(["Material Palenight", "Dark", "Light", "System preference", "Monokai Pro", "Dracula", "Solarized Dark"], id: \.self) { theme in
                        Text(theme).tag(theme)
                    }
                }
                Toggle("Remember icon position", isOn: model.consoleBinding(\.rememberPosition))
                Text("The initial icon position is x: 263.807642, y: 0, clamped to the visible page. Drag the button to remember a new position for that website.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restore requested console defaults") {
                    model.change {
                        $0.console = ConsoleOptions()
                    }
                }
            } header: {
                HStack {
                    Text("Eruda appearance")
                    ProBadge()
                }
            } footer: {
                Text("Your requested defaults are applied in the free edition. Pro also enables Eruda’s own settings panel. Plugin or appearance changes may restart the console and clear its current logs; reload the page for a fresh capture.")
            }
            .disabled(!model.isPro)
            Section {
                NavigationLink("Installed packages & updates") {
                    PackagesView()
                }
            }
        }
        .navigationTitle("Tools")
    }
}

struct PackagesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: PackageUpdater

    var body: some View {
        List {
            Section {
                Toggle("Automatically install updates", isOn: model.binding(\.automaticallyInstallUpdates))
                Button {
                    Task {
                        await updater.check(enabled: true, force: true)
                    }
                } label: {
                    HStack {
                        Text(updater.isChecking ? "Checking packages…" : "Check now")
                        Spacer()
                        if updater.isChecking {
                            ProgressView()
                        }
                    }
                }
                .disabled(updater.isChecking)
                if let date = updater.status.checkedAt {
                    LabeledContent("Last checked") {
                        Text(date, style: .relative)
                    }
                }
                Text(updater.status.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } footer: {
                Text(PackageCache.remoteAssetsAllowed
                     ? "Checks at every app foreground. New package files are downloaded from version-pinned jsDelivr URLs and checked against their SHA-256 metadata. Safari uses bundled files if a cached update cannot run under the page’s security policy."
                     : "This Release build checks for updates but executes only bundled packages. New executable versions arrive through signed app updates. iOS does not run npm; npm is used to prepare the Xcode project.")
            }
            Section("Bundled and cached versions") {
                ForEach(updater.catalog?.assets ?? []) { asset in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(asset.package)
                            .font(.system(.headline, design: .monospaced))
                        Text("Bundled \(asset.version)" + (updater.status.installed[asset.id].map { " · Cached \($0.version)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let latest = updater.status.available[asset.id], latest != asset.version {
                            Text("Latest published: \(latest)")
                                .font(.caption)
                        }
                    }
                }
            }
            Section {
                Button("Clear downloaded packages", role: .destructive) {
                    updater.clearCache()
                }
                .disabled(updater.isChecking || updater.status.installed.isEmpty)
            } footer: {
                Text("The actual version running on the current page appears in Safari’s DevTools popup. A cached package may be newer than the version a page can load.")
            }
        }
        .navigationTitle("Packages")
    }
}
