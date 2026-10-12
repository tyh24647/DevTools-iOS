import SwiftUI
import Combine

struct MainView: View {
    @State private var selection = 0
    private let adClock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Overview", systemImage: "terminal.fill")
            }
            .tag(0)
            NavigationStack {
                ListsView()
            }
            .tabItem {
                Label("Lists", systemImage: "line.3.horizontal.decrease.circle.fill")
            }
            .tag(1)
            NavigationStack {
                ToolsView()
            }
            .tabItem {
                Label("Tools", systemImage: "wrench.and.screwdriver.fill")
            }
            .tag(2)
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(3)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: PackageUpdater

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image("BrandIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("⚙︎ DevTools")
                                .font(.largeTitle.bold())
                                .minimumScaleFactor(0.75)
                            Text("Your web console. Everywhere you need it.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Pill(text: model.isPro ? "Pro unlocked" : "Free edition", symbol: model.isPro ? "sparkles" : "terminal")
                        Pill(text: "Safari extension", symbol: "safari")
                    }
                    Toggle("Enable DevTools", isOn: model.binding(\.enabled))
                        .font(.headline)
                    let statusMessage: String = {
                        if model.config.enabled {
                            return "Ready to run on matching pages once Safari permission is granted."
                        } else {
                            return "Automatic injection is paused. Existing visible tabs update within a few seconds."
                        }
                    }()
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section {
                Toggle("Run on every webpage", isOn: model.binding(\.runEverywhere))
                let activeAllowCount = model.config.lists.filter { $0.selected && $0.kind == .allow }.count
                HStack {
                    Label("Active AllowLists", systemImage: "checkmark.shield")
                    Spacer()
                    Text("\(activeAllowCount)")
                        .monospacedDigit()
                }
                let activeBlockCount = model.config.lists.filter { $0.selected && $0.kind == .block }.count
                HStack {
                    Label("Active blacklists", systemImage: "hand.raised")
                    Spacer()
                    Text("\(activeBlockCount)")
                        .monospacedDigit()
                }
            } header: {
                Text("Page access")
            } footer: {
                let accessFooter: String = model.config.runEverywhere ? "Runs on permitted HTTP and HTTPS pages except matches in your selected blacklists." : "Runs only on pages matching a selected AllowList. Blacklists still take priority. An empty selection allows no pages."
                Text(accessFooter)
            }
            Section("Get started") {
                NavigationLink {
                    SetupView()
                } label: {
                    Label("Enable in Safari", systemImage: "safari.fill")
                }
                NavigationLink {
                    RulesHelpView()
                } label: {
                    Label("How matching works", systemImage: "line.3.horizontal.decrease.circle")
                }
                NavigationLink {
                    PackagesView()
                } label: {
                    Label("Installed packages", systemImage: "shippingbox.fill")
                }
            }
            Section {
                NavigationLink {
                    ProView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 4) {
                            let proHeadline = model.isPro ? "DevTools Pro is active" : "Make DevTools yours"
                            Text(proHeadline)
                                .font(.headline)
                            Text("Vue inspector, resource waterfall, themes and more. No ads.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("DevTools")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.reload()
        }
    }
}
