import SwiftUI

struct SetupView: View {
    @State private var safariChecked = false
    @State private var shareSheetChecked = false

    // Documentation URLs (replace with your real links)
    private let docsSafariExtensionURL = URL(string: "https://example.com/docs/safari-extension-setup")!
    private let docsShareExtensionURL = URL(string: "https://example.com/docs/share-extension-setup")!

    var body: some View {
        List {
            #if os(iOS)
            Section("Safari Extension") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable the Safari Web Extension to use DevTools in Safari.")
                    checklistRow(title: "Open Settings > Safari > Extensions", binding: $safariChecked)
                    Button("Open Safari Settings") { openSafariSettings() }
                }
            }
            Section("Share Sheet") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable the Share Sheet action to send pages to the app.")
                    checklistRow(title: "Tap Share in any app, scroll to 'Edit Actions…', then enable the app's action.", binding: $shareSheetChecked)
                    Button("Open App Settings") { openAppSettings() }
                }
            }
            #elseif os(macOS)
            Section("Safari Web Extension (macOS)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable the Safari Web Extension in Safari.")
                    checklistRow(title: "Open Safari > Settings… > Extensions", binding: $safariChecked)
                    Text("Check the box next to the extension to enable it.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Share Extension (macOS)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enable the Share extension to send pages to the app.")
                    checklistRow(title: "Open System Settings > Privacy & Security > Extensions > Sharing", binding: $shareSheetChecked)
                    Text("Alternatively, click the Share button in any app, choose 'Edit Extensions…', then enable the app's extension.")
                        .foregroundStyle(.secondary)
                }
            }
            #endif

            Section("Documentation") {
                Link("Safari Extension Setup Guide", destination: docsSafariExtensionURL)
                Link("Share Extension / Share Sheet Guide", destination: docsShareExtensionURL)
            }

            Section("Tips") {
                Text("After enabling, you may need to relaunch Safari for changes to take effect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Setup")
    }

    @ViewBuilder
    private func checklistRow(title: String, binding: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: binding.wrappedValue ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(binding.wrappedValue ? .green : .secondary)
                .imageScale(.large)
                .onTapGesture { binding.wrappedValue.toggle() }
            Text(title)
        }
    }

    private func openAppSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    private func openSafariSettings() {
        #if os(iOS)
        // Direct deep links to Safari Extensions settings are not public; open Settings app.
        if let url = URL(string: "App-Prefs:root=SAFARI") ?? URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

#Preview {
    NavigationStack {
        SetupView()
    }
}
