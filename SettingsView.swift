import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ads: AdManager

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: model.binding(\.appearance)) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Accent", selection: model.binding(\.accent)) {
                    ForEach(["blue", "purple", "mint", "pink", "orange"], id: \.self) { name in
                        Text(name.capitalized).tag(name)
                    }
                }
            }
            Section("DevTools") {
                NavigationLink("Packages & automatic updates") {
                    PackagesView()
                }
                NavigationLink(model.isPro ? "Manage DevTools Pro" : "Unlock DevTools Pro") {
                    ProView()
                }
                NavigationLink("Safari & share sheet setup") {
                    SetupView()
                }
            }
            Section("Privacy & advertising") {
                NavigationLink("Privacy information") {
                    PrivacyView()
                }
                if ads.privacyOptionsRequired {
                    Button("Advertising privacy options") {
                        Task {
                            await ads.showPrivacyOptions()
                        }
                    }
                }
                Link("Report an inappropriate ad", destination: URL(string: "https://support.google.com/ads/answer/2535140")!)
                Text("Ads appear only in this app. Your Safari URLs, lists and console data are never sent to the advertising SDK by DevTools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "⚙︎ DevTools 1.0.0")
                LabeledContent("Developer", value: "Tyler Hostager")
                Link("Developer website", destination: URL(string: "https://tylero056.com")!)
                Link("Developer GitHub", destination: URL(string: "https://github.com/tyh24647")!)
                NavigationLink("Acknowledgements & licenses") {
                    LicensesView()
                }
            }
        }
        .navigationTitle("Settings")
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section("On your device") {
                Text("Lists, preferences, verified purchase access and downloaded development packages are stored in this app’s shared container. Console output and inspected page content stay inside the Safari page. DevTools has no analytics or browsing-history server.")
                Text("Eruda executes within the webpage. Page scripts can observe or interfere with developer tools. Treat data shown in a web console as part of that page, not as a private vault.")
            }
            Section("Network services") {
                Text("When update checks are enabled, the app contacts npm and jsDelivr for package metadata. Development builds may download packages. These services receive ordinary network metadata such as your IP address, but DevTools does not send them your lists or visited pages.")
                Text("Purchases are handled by Apple. The free containing app uses Google Mobile Ads and User Messaging Platform. Ad requests use the non-personalized setting; Google may process device, network and ad-interaction data. Consent controls are shown when required. Pro disables advertising.")
                Link("Google privacy policy", destination: URL(string: "https://policies.google.com/privacy")!)
            }
            Section("Controls") {
                Text("Disable the Safari extension or revoke its website access in Settings to stop injection. Disable automatic updates to stop package checks. Remove the app to remove its locally stored data. Eruda may remember console settings in each website’s local storage; Safari’s website-data controls can remove them.")
            }
        }
        .navigationTitle("Privacy")
    }
}

struct LicensesView: View {
    @State private var licenses = ""

    var body: some View {
        ScrollView {
            Text(licenses)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Acknowledgements")
        .task {
            if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt") {
                licenses = (try? String(contentsOf: url, encoding: .utf8)) ?? "Unable to load bundled notices."
            }
        }
    }
}
