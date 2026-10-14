import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject private var browser: BrowserController
    @State private var address = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Website URL", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { browser.navigate(address) }
                Button("Go", systemImage: "arrow.right") { browser.navigate(address) }
                    .labelStyle(.iconOnly)
                Menu {
                    ForEach(browser.tabs) { tab in
                        Button(tab.title) { browser.selected = tab.id }
                    }
                    Button("New tab", systemImage: "plus") { _ = browser.newTab() }
                    if let tab = browser.current {
                        Button("Close current tab", role: .destructive) { browser.close(tab) }
                    }
                } label: {
                    Label("Tabs: \(browser.tabs.count)", systemImage: "square.on.square")
                        .labelStyle(.iconOnly)
                }
            }
            .padding(10)
            if let tab = browser.current {
                BrowserPage(tab: tab)
                    .id(tab.id)
            } else {
                ContentUnavailableView("Open a website", systemImage: "safari")
            }
            HStack {
                Button("Back", systemImage: "chevron.left") { browser.current?.webView.goBack() }
                    .disabled(browser.current?.canBack != true)
                Spacer()
                Button("Forward", systemImage: "chevron.right") { browser.current?.webView.goForward() }
                    .disabled(browser.current?.canForward != true)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") { browser.current?.webView.reload() }
                Spacer()
                Menu {
                    Button("Show console") { browser.command("show") }
                    Button("Hide console") { browser.command("hide") }
                    Toggle("Enable browser tools", isOn: $browser.rules.enabled)
                    NavigationLink("Browser rules") { BrowserRulesView() }
                    if let raw = browser.current?.address, let url = URL(string: raw) {
                        ShareLink(item: url)
                    }
                } label: {
                    Label("DevTools", systemImage: "wrench.and.screwdriver")
                }
            }
            .padding(10)
            .labelStyle(.iconOnly)
        }
        .navigationTitle("Browser")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: browser.current?.address) { _, value in address = value ?? "" }
        .onChange(of: browser.selected) { _, _ in address = browser.current?.address ?? "" }
        .sheet(item: $browser.filePicker) { picker in
            BrowserDocumentPicker(picker: picker)
        }
    }
}

private struct BrowserPage: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        VStack(spacing: 0) {
            if tab.progress < 1 && tab.progress > 0 {
                ProgressView(value: tab.progress)
            }
            BrowserWebView(webView: tab.webView)
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct BrowserDocumentPicker: UIViewControllerRepresentable {
    let picker: BrowserFilePicker
    func makeCoordinator() -> Coordinator { Coordinator(picker) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let view = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        view.allowsMultipleSelection = picker.multiple
        view.delegate = context.coordinator
        return view
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picker: BrowserFilePicker
        private var completed = false
        init(_ picker: BrowserFilePicker) { self.picker = picker }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
        private func finish(_ urls: [URL]?) {
            guard !completed else { return }
            completed = true
            picker.completion(urls)
        }
        deinit {
            if !completed { picker.completion(nil) }
        }
    }
}

/// Browser rules are independent of Safari's profile and use the same validated matcher.
struct BrowserRulesView: View {
    @EnvironmentObject private var browser: BrowserController
    @State private var name = ""
    @State private var kind = ListKind.allow
    var body: some View {
        Form {
            Section("Native browser") {
                Toggle("Enable tools", isOn: $browser.rules.enabled)
                Toggle("Run everywhere except blacklists", isOn: $browser.rules.runEverywhere)
                Text("Safari uses its own lists in Settings. Selected blacklists always take priority.")
                    .font(.caption)
            }
            ForEach(browser.rules.lists) { list in
                Section(list.name) {
                    Toggle("Apply this list", isOn: Binding(get: {
                        browser.rules.lists.first { $0.id == list.id }?.selected ?? false
                    }, set: { value in
                        if let i = browser.rules.lists.firstIndex(where: { $0.id == list.id }) {
                            browser.rules.lists[i].selected = value
                        }
                    }))
                    NavigationLink("Edit \(list.kind.title) rules (\(list.rules.count))") {
                        BrowserRuleDetail(listID: list.id)
                    }
                    Button("Delete list", role: .destructive) {
                        browser.rules.lists.removeAll { $0.id == list.id }
                    }
                }
            }
            Section("New list") {
                TextField("List name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(ListKind.allCases) { Text($0.title).tag($0) }
                }
                Button("Create") {
                    browser.rules.lists.append(RuleList(name: name, kind: kind))
                    name = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
            }
        }
        .navigationTitle("Browser rules")
    }
}

private struct BrowserRuleDetail: View {
    @EnvironmentObject private var browser: BrowserController
    let listID: String
    @State private var pattern = ""
    @State private var kind = RuleKind.domain
    @State private var error: String?
    private var list: RuleList? { browser.rules.lists.first { $0.id == listID } }
    var body: some View {
        Form {
            if let list {
                Section("Name") {
                    TextField("List name", text: Binding(get: { self.list?.name ?? "" }, set: { value in
                        if !value.isEmpty && value.count <= 80, let i = browser.rules.lists.firstIndex(where: { $0.id == listID }) {
                            browser.rules.lists[i].name = value
                        }
                    }))
                }
                Section("Rules") {
                    ForEach(list.rules) { rule in
                        Toggle(rule.pattern, isOn: Binding(get: {
                            self.list?.rules.first { $0.id == rule.id }?.enabled ?? false
                        }, set: { value in
                            if let i = browser.rules.lists.firstIndex(where: { $0.id == listID }),
                               let j = browser.rules.lists[i].rules.firstIndex(where: { $0.id == rule.id }) {
                                browser.rules.lists[i].rules[j].enabled = value
                            }
                        }))
                    }
                    .onDelete { offsets in
                        if let i = browser.rules.lists.firstIndex(where: { $0.id == listID }) {
                            browser.rules.lists[i].rules.remove(atOffsets: offsets)
                        }
                    }
                }
                Section("Add rule") {
                    Picker("Type", selection: $kind) {
                        ForEach(RuleKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Domain, URL, wildcard or regex", text: $pattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("Add") {
                        do {
                            let rule = SiteRule(kind: kind, pattern: pattern)
                            try RuleValidator.validate(rule)
                            if let i = browser.rules.lists.firstIndex(where: { $0.id == listID }) {
                                browser.rules.lists[i].rules.append(rule)
                            }
                            pattern = ""
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    NavigationLink("Matching guide") { RulesHelpView() }
                }
            }
        }
        .navigationTitle(list?.name ?? "Deleted list")
    }
}

struct SaveMediaView: View {
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var browser: BrowserController
    @Environment(\.dismiss) private var dismiss
    let source: PageMedia
    @State private var choices: [MediaChoice] = []
    @State private var selected = ""
    @State private var cookies: [HTTPCookie] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(source.title) {
                    Text(source.url).font(.caption).textSelection(.enabled)
                    if loading { ProgressView("Inspecting media") }
                    if let error { Text(error).foregroundStyle(.red) }
                    if media.settings.showQuality && choices.count > 1 {
                        Picker("Quality", selection: $selected) {
                            ForEach(choices) { Text($0.label).tag($0.id) }
                        }
                    }
                    if source.isBlob {
                        Text("Captures supported MP4/WebM buffers from this tab. Keep the source playing. Stop or close the source to finalize the movie. Opaque WebSocket protocols and protected media are unsupported.")
                    } else if choices.first(where: { $0.id == selected })?.live == true {
                        Text("Records new live segments until Stop, source close/navigation, or the file-size limit. Completed segments are kept if conversion fails.")
                    }
                    LabeledContent("Output", value: "\(media.settings.container.rawValue.uppercased()) · \(media.settings.codec.rawValue.uppercased())")
                    LabeledContent("Folder", value: media.settings.defaultFolder.isEmpty ? "Media root" : media.settings.defaultFolder)
                    Text("Safari cookies are not transferred. For a signed-in stream, open its website and sign in inside this browser first.")
                        .font(.caption)
                }
                NavigationLink("Recording settings") { MediaSettingsView() }
            }
            .navigationTitle("Save media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        media.start(source, choice: choices.first { $0.id == selected }, cookies: cookies)
                        dismiss()
                    }
                    .disabled(loading || error != nil || (!source.isBlob && choices.isEmpty))
                }
            }
            .task {
                cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                do {
                    choices = try await media.choices(source, cookies: cookies)
                    selected = choices.first?.id ?? ""
                } catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}
