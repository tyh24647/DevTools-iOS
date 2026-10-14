import SwiftUI
import Combine

struct RootView: View {
    @EnvironmentObject private var ads: AdManager
    @State private var selection = 0
    private let adClock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DashboardView()
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AdFooter()
        }
        .onReceive(adClock) { _ in
            ads.tick()
        }
        .onChange(of: selection) { _, _ in
            ads.naturalBreak()
        }
    }
}

struct DashboardView: View {
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
                    Text(model.config.enabled ? "Ready to run on matching pages once Safari permission is granted." : "Automatic injection is paused. Existing visible tabs update within a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section {
                Toggle("Run on every webpage", isOn: model.binding(\.runEverywhere))
                HStack {
                    Label("Active AllowLists", systemImage: "checkmark.shield")
                    Spacer()
                    Text("\(model.config.lists.filter { $0.selected && $0.kind == .allow }.count)")
                        .monospacedDigit()
                }
                HStack {
                    Label("Active blacklists", systemImage: "hand.raised")
                    Spacer()
                    Text("\(model.config.lists.filter { $0.selected && $0.kind == .block }.count)")
                        .monospacedDigit()
                }
            } header: {
                Text("Page access")
            } footer: {
                Text(model.config.runEverywhere ? "Runs on permitted HTTP and HTTPS pages except matches in your selected blacklists." : "Runs only on pages matching a selected AllowList. Blacklists still take priority. An empty selection allows no pages.")
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
                            Text(model.isPro ? "DevTools Pro is active" : "Make DevTools yours")
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

struct SetupView: View {
    var body: some View {
        List {
            Section("Safari permission") {
                Label("Open Settings → Apps → Safari → Extensions.", systemImage: "1.circle.fill")
                Label("Choose ⚙︎ DevTools and turn on Allow Extension.", systemImage: "2.circle.fill")
                Label("Grant website access, including All Websites if you want automatic injection everywhere.", systemImage: "3.circle.fill")
                Label("Reload a page. Tap the floating console button or open Safari’s extension menu.", systemImage: "4.circle.fill")
            }
            Section("Share sheet actions") {
                Text("In Safari, tap Share and scroll to the actions. Use Edit Actions to add the six DevTools actions to Favorites. iOS controls their ordering and may truncate long names.")
                Text("Show opens the current page’s console. Hide hides its panel and floating button. Enable and Disable change the global DevTools switch. Show still respects your lists and Safari permissions.")
                Text("Add to AllowList and Add to Blacklist let you choose a list and match type before saving. Changes apply to Safari as soon as the action closes.")
            }
            Section("What to expect") {
                Text("Safari cannot inject into its own settings pages, reader internals or protected browser pages. Permission can also be limited by website or Safari profile.")
                Text("The extension starts as early as Safari allows. Requests or logs created before it starts may not be captured. The resource waterfall also reads buffered Performance entries.")
                Text("Vue tools work best on development builds with DevTools hooks available. Some production apps remove those hooks; no extension can guarantee inspecting every Vue app.")
            }
        }
        .navigationTitle("Safari setup")
    }
}

struct RulesHelpView: View {
    var body: some View {
        List {
            Section("Priority") {
                Text("1. Disabled means do not run.\n2. A match in any selected blacklist means do not run.\n3. Run on every webpage allows remaining pages.\n4. Otherwise, a selected AllowList must match.")
            }
            Section("Examples") {
                LabeledContent("Domain & subdomains", value: "example.com")
                Text("Matches example.com and api.example.com, but never notexample.com.")
                LabeledContent("Exact URL", value: "https://example.com/debug")
                Text("Matches the full URL including its query string. Fragments are ignored.")
                LabeledContent("Wildcard", value: "*://*.example.com/*")
                Text("* matches any sequence; ? matches one character. A wildcard is anchored to the entire URL and is case sensitive. *.example.com does not include the bare example.com host.")
                LabeledContent("Regular expression", value: #"/^https:\/\/example\.com\/debug/i"#)
                Text("Use JavaScript regex syntax with optional /pattern/imu flags. Matching uses the normalized URL without its fragment. Patterns are limited to 512 characters, URLs to 4096. Backreferences, lookarounds, repeated complex groups and more than four variable-length repetitions are rejected.")
            }
            Section("Lists") {
                Text("Select several lists to combine them. Unselected lists do not affect matching. An invalid active rule stops injection and is reported in the Safari popup.")
            }
        }
        .textSelection(.enabled)
        .navigationTitle("Matching guide")
    }
}
