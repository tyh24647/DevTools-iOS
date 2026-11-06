import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct PluginsView: View {
    @EnvironmentObject private var library: PluginLibrary
    @EnvironmentObject private var browser: BrowserController
    @State private var editing: UserPlugin?
    @State private var importing = false
    @State private var importURL = ""
    @State private var urlSheet = false

    var body: some View {
        List {
            Section {
                Text("Custom Eruda panels and userscripts run only on matching pages in the in-app browser. Edited/imported scripts stay disabled until you enable them.")
                    .font(.caption)
            }
            ForEach(Dictionary(grouping: library.rows, by: \.folder).keys.sorted(), id: \.self) { folder in
                Section(folder.isEmpty ? "Scripts" : folder) {
                    ForEach(library.rows.filter { $0.folder == folder }) { row in
                        VStack(alignment: .leading) {
                            Toggle(isOn: Binding(get: { row.enabled }, set: { value in
                                do {
                                    try library.enable(row.id, value: value)
                                    browser.refreshTools()
                                } catch {
                                    library.error = error.localizedDescription
                                }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(row.name)
                                    Text("\(row.kind) · \(row.tags)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Button("Edit") {
                                    editing = row
                                }
                                ShareLink(item: row.source, subject: Text(row.name), preview: SharePreview(row.name))
                                Spacer()
                                Button("Delete", role: .destructive) {
                                    do {
                                        try library.delete(row.id)
                                        browser.refreshTools()
                                    } catch {
                                        library.error = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Plugins & scripts")
        .toolbar {
            Menu {
                Button("New userscript") {
                    editing = UserPlugin(name: "New userscript", kind: "userscript", source: "// ==UserScript==\n// @name New userscript\n// @match https://example.com/*\n// @grant none\n// @run-at document-end\n// ==/UserScript==\n\n(() => {\n    console.log('DevTools userscript');\n})();\n")
                }
                Button("New Eruda panel") {
                    editing = UserPlugin(name: "My panel", kind: "eruda", source: "module.exports = {\n    name: 'My panel',\n    init($el) {\n        $el.text('Hello from DevTools');\n    }\n};\n")
                }
                Button("Import local JavaScript") {
                    importing = true
                }
                Button("Import JavaScript URL") {
                    urlSheet = true
                }
            } label: {
                Image(systemName: "plus")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 256 * 1024 else {
                    throw MediaFailure.invalid("Script exceeds 256 KB.")
                }
                let source = try String(contentsOf: url, encoding: .utf8)
                editing = UserPlugin(name: url.deletingPathExtension().lastPathComponent,
                                     kind: source.contains("==UserScript==") ? "userscript" : "eruda", source: source)
            } catch {
                library.error = error.localizedDescription
            }
        }
        .alert("Import JavaScript", isPresented: $urlSheet) {
            TextField("https://example.com/script.js", text: $importURL)
            Button("Read for review") {
                Task {
                    do {
                        guard let url = BrowserController.normalizedURL(importURL) else {
                            throw MediaFailure.invalid("Enter an HTTP(S) JavaScript URL.")
                        }
                        let http = MediaHTTP(page: url, cookies: [], limit: 256 * 1024)
                        defer { http.close() }
                        let data = try await http.data(url, maximum: 256 * 1024).0
                        guard let source = String(data: data, encoding: .utf8) else {
                            throw MediaFailure.invalid("Script is not UTF-8 text.")
                        }
                        editing = UserPlugin(name: url.lastPathComponent, kind: source.contains("==UserScript==") ? "userscript" : "eruda", source: source)
                    } catch {
                        library.error = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editing) { row in
            PluginEditor(row: row)
        }
        .alert("Scripts", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") {
                library.error = nil
            }
        } message: {
            Text(library.error ?? "")
        }
    }
}

struct PluginEditor: View {
    @EnvironmentObject private var library: PluginLibrary
    @EnvironmentObject private var browser: BrowserController
    @Environment(\.dismiss) private var dismiss
    @State var row: UserPlugin
    @State private var options: [String: Any] = UserDefaults.standard.dictionary(forKey: "editor-options-v2") ?? ["theme": "dark", "matchBrackets": true, "closeBrackets": true, "wrap": true, "indentSize": 4]
    @State private var optionsSheet = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Script name", text: $row.name)
                    .textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $row.kind) {
                    Text("Userscript").tag("userscript")
                    Text("Eruda panel").tag("eruda")
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("Folder / subfolder", text: $row.folder)
                    TextField("Tags", text: $row.tags)
                }
                .textFieldStyle(.roundedBorder)
                CodeEditor(source: $row.source, error: $error, kind: row.kind, options: options)
                    .frame(minHeight: 300)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Edit script")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        optionsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try library.save(row)
                            browser.refreshTools()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(row.source.utf8.count > 256 * 1024 || row.name.isEmpty)
                }
            }
            .sheet(isPresented: $optionsSheet) {
                NavigationStack {
                    Form {
                        Picker("Theme", selection: option("theme", fallback: "dark")) {
                            Text("Dark").tag("dark")
                            Text("Light").tag("light")
                        }
                        ForEach(["invisibles", "matchBrackets", "closeBrackets", "wrap", "singleQuote", "semicolons"], id: \.self) { key in
                            Toggle(key, isOn: option(key, fallback: key == "wrap" || key == "matchBrackets" || key == "closeBrackets"))
                        }
                        Picker("Indentation", selection: option("indent", fallback: "spaces")) {
                            Text("Spaces").tag("spaces")
                            Text("Tabs").tag("tabs")
                        }
                        Stepper("Indent size: \(options["indentSize"] as? Int ?? 4)", value: option("indentSize", fallback: 4), in: 2...8)
                        Stepper("Font size: \(options["fontSize"] as? Int ?? 14)", value: option("fontSize", fallback: 14), in: 12...24)
                    }
                    .navigationTitle("Editor settings")
                    .toolbar {
                        Button("Done") {
                            UserDefaults.standard.set(options, forKey: "editor-options-v2")
                            optionsSheet = false
                        }
                    }
                }
            }
        }
    }

    private func option<Value>(_ name: String, fallback: Value) -> Binding<Value> {
        Binding(get: { options[name] as? Value ?? fallback }, set: { options[name] = $0 })
    }
}

struct CodeEditor: UIViewRepresentable {
    @Binding var source: String
    @Binding var error: String?
    var kind: String
    var options: [String: Any]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "editorBridge")
        configuration.userContentController.addUserScript(WKUserScript(source: "globalThis.editorBridge={postMessage:(value)=>webkit.messageHandlers.editorBridge.postMessage(value)}", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        let file = Bundle.main.url(forResource: "BrowserResources", withExtension: nil)!.appendingPathComponent("editor/index.html")
        var html = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        html = html.replacingOccurrences(of: "<head>", with: "<head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:\">")
        view.loadHTMLString(html, baseURL: URL(string: "https://editor.devtools.invalid/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.owner = self
        let encoded = PluginLibrary.json(options)
        if context.coordinator.loaded && encoded != context.coordinator.options {
            context.coordinator.initialize()
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "editorBridge")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var owner: CodeEditor
        weak var view: WKWebView?
        var loaded = false
        var options = ""
        init(_ owner: CodeEditor) {
            self.owner = owner
        }
        func initialize() {
            options = PluginLibrary.json(owner.options)
            view?.evaluateJavaScript("DevToolsEditor.init(\(PluginLibrary.json(owner.source)),\(PluginLibrary.json(owner.kind)),\(options))")
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            initialize()
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(["about:blank", "https://editor.devtools.invalid/"].contains(navigationAction.request.url?.absoluteString ?? "") ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let raw = message.body as? String, raw.utf8.count <= 1_600_000,
                  let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["source"] as? String else {
                return
            }
            owner.source = value
            owner.error = object["error"] as? String
        }
    }
}
