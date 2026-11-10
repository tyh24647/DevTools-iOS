import Foundation
import SwiftUI
import WebKit
import Combine

public struct HistoryEntry: Identifiable, Codable, Equatable {
    public let id: UUID
    public let url: String
    public let title: String
    public let date: Date

    public init(id: UUID = UUID(), url: String, title: String, date: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.date = date
    }
}

struct NativeBrowserRules: Codable {
    var enabled = true
    var runEverywhere = true
    var lists = [RuleList(name: "Development sites", kind: .allow), RuleList(name: "Excluded sites", kind: .block)]
}

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google = "Google", duckDuckGo = "DuckDuckGo", bing = "Bing", brave = "Brave"
    var id: String { rawValue }
    func searchURL(_ query: String) -> URL? {
        let endpoint: String
        switch self {
        case .google: endpoint = "https://www.google.com/search"
        case .duckDuckGo: endpoint = "https://duckduckgo.com/"
        case .bing: endpoint = "https://www.bing.com/search"
        case .brave: endpoint = "https://search.brave.com/search"
        }
        var parts = URLComponents(string: endpoint)
        parts?.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts?.url
    }
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    weak var owner: BrowserController?
    @Published var title = "New tab"
    @Published var address = ""
    @Published var progress = 0.0
    @Published var canBack = false
    @Published var canForward = false
    @Published private(set) var preview: UIImage?
    private var takingPreview = false
    private var historyPreviews: [String: UIImage] = [:]
    private var historyPreviewOrder: [String] = []
    private var disposed = false
    private var observers: [NSKeyValueObservation] = []

    func historyPreview(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return historyPreviews[url.absoluteString]
    }

    // Bounded, memory-only viewport images; never persist page pixels to disk.
    func capturePreview() {
        guard !disposed, !takingPreview, webView.window != nil,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        takingPreview = true
        let url = webView.url
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 480
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            self.takingPreview = false
            guard !self.disposed, self.webView.url == url, let image else { return }
            let size = CGSize(width: 480, height: min(1200, 480 * image.size.height / max(1, image.size.width)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let snapshot = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            self.preview = snapshot
            if let key = url?.absoluteString {
                self.historyPreviews[key] = snapshot
                self.historyPreviewOrder.removeAll { $0 == key }
                self.historyPreviewOrder.append(key)
                if self.historyPreviewOrder.count > 4 {
                    let oldest = self.historyPreviewOrder.removeFirst()
                    self.historyPreviews.removeValue(forKey: oldest)
                }
            }
        }
    }

    init(owner: BrowserController, configuration: WKWebViewConfiguration) {
        self.owner = owner
        // Keep popup configuration compatibility while giving each tab its own scripts.
        configuration.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // BrowserPage owns edge history gestures so their preview and commit stay in sync.
        webView.allowsBackForwardNavigationGestures = false
        observers = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canForward = view.canGoForward }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    self?.title = view.title ?? "New tab"
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    self?.address = view.url?.absoluteString ?? ""
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    self?.progress = view.estimatedProgress
                    self?.canBack = view.canGoBack
                    self?.canForward = view.canGoForward
                }
            }
        ]
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Cross-origin HTTP(S) redirects and login callbacks stay in the browser.
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss", "file", "javascript"].contains(scheme)
            || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, let previous = webView.url,
           previous.absoluteString != url.absoluteString {
            owner?.prepareToLeave(self)
            decisionHandler(.allow)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        capturePreview()
        owner?.persistTabs()
        guard let owner = owner, let url = webView.url else {
            return
        }
        owner.setPageScrollingUnlocked(owner.pageScrollingUnlocked, tab: self)
        let title = self.title
        // Append history entry if not duplicate consecutive for this tab and url
        if let lastEntry = owner.history.last, lastEntry.url == url.absoluteString, lastEntry.title == title {
            // do nothing, avoid duplicate consecutive entries
        } else {
            let entry = HistoryEntry(
                url: url.absoluteString,
                title: title,
                date: Date()
            )
            owner.history.append(entry)
            owner.persistHistory()
        }
        owner.persistTabs()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.notice = "The webpage process ended. Reload to restore the page."
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, (owner?.tabs.count ?? 12) < 12 else {
            return nil
        }
        return owner?.newTab(configuration: configuration)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.close(self)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        owner?.filePicker = BrowserFilePicker(completion: completionHandler, multiple: parameters.allowsMultipleSelection)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // WebKit presents site consent, then iOS applies camera/microphone permissions.
        decisionHandler(origin.protocol == "https" && frame.isMainFrame ? .prompt : .deny)
    }

    func dispose() {
        disposed = true
        preview = nil
        observers = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}

struct BrowserFilePicker: Identifiable {
    let id = UUID()
    let completion: ([URL]?) -> Void
    let multiple: Bool
}

@MainActor
final class BrowserController: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selected: UUID? {
        willSet { if newValue != selected { current?.capturePreview() } }
    }
    @Published var searchEngine = BrowserSearchEngine(rawValue: UserDefaults.standard.string(forKey: "browser-search-engine") ?? "") ?? .google {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "browser-search-engine") }
    }
    @Published var notice: String?
    @Published var filePicker: BrowserFilePicker?
    @Published var rules: NativeBrowserRules {
        didSet {
            if let data = try? JSONEncoder().encode(rules) {
                UserDefaults.standard.set(data, forKey: "native-browser-rules-v2")
            }
            refreshTools()
        }
    }
    @Published var history: [HistoryEntry] = [] {
        didSet {
            persistHistory()
        }
    }

    let plugins: PluginLibrary
    private var config: [String: Any] = [:]
    private var ready = false
    private var sourceCache: [String: String] = [:]
    private var adBlockingRules: WKContentRuleList?
    var current: BrowserTab? {
        tabs.first { $0.id == selected }
    }

    init(plugins: PluginLibrary) {
        self.plugins = plugins
        if let data = UserDefaults.standard.data(forKey: "native-browser-rules-v2") {
            do {
                rules = try JSONDecoder().decode(NativeBrowserRules.self, from: data)
            } catch {
                var disabled = NativeBrowserRules()
                disabled.enabled = false
                rules = disabled
                notice = "Native browser rules could not be read. Injection is disabled; repair or reset them before enabling."
            }
        } else {
            rules = NativeBrowserRules()
        }
        // Load history
        if let historyData = UserDefaults.standard.data(forKey: "browser-history-v1") {
            do {
                let decoded = try JSONDecoder().decode([HistoryEntry].self, from: historyData)
                history = decoded
            } catch {
                history = []
                notice = "Failed to load browser history; starting fresh."
            }
        } else {
            history = []
        }

        loadAdBlockingRules()
    }

    private func loadAdBlockingRules() {
        guard let folder = Bundle.main.url(forResource: "BrowserResources", withExtension: nil),
              let json = try? String(contentsOf: folder.appendingPathComponent("ad-blocking.json"), encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "DevTools-AdBlocking-v1", encodedContentRuleList: json) { [weak self] rules, _ in
            Task { @MainActor in
                guard let self, let rules else { return }
                self.adBlockingRules = rules
                for tab in self.tabs { tab.webView.configuration.userContentController.add(rules) }
            }
        }
    }

    func configure(_ model: AppModel) {
        do {
            config = try model.config.bridgeObject()
            ready = true
            if tabs.isEmpty {
                let saved = UserDefaults.standard.stringArray(forKey: "native-tabs-v2") ?? []
                if saved.isEmpty {
                    _ = newTab()
                } else {
                    for raw in saved.prefix(12) {
                        _ = newTab(url: Self.normalizedURL(raw))
                    }
                }
            }
            refreshTools()
        } catch {
            notice = error.localizedDescription
        }
    }

    @discardableResult
    func newTab(url: URL? = nil, configuration supplied: WKWebViewConfiguration? = nil) -> BrowserTab? {
        guard tabs.count < 12 else {
            notice = "Close a tab first (twelve-tab limit)."
            return nil
        }
        let configuration = supplied ?? WKWebViewConfiguration()
        // Keep login cookies across normal tabs while preserving WebKit popup configurations.
        if supplied == nil { configuration.websiteDataStore = .default() }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let tab = BrowserTab(owner: self, configuration: configuration)
        if let adBlockingRules { tab.webView.configuration.userContentController.add(adBlockingRules) }
        install(tab)
        tabs.append(tab)
        selected = tab.id
        if let url {
            tab.webView.load(URLRequest(url: url))
        }
        return tab
    }

    var pageScrollingUnlocked = true

    func setPageScrollingUnlocked(_ enabled: Bool, tab: BrowserTab? = nil) {
        pageScrollingUnlocked = enabled
        let target = tab ?? current
        target?.webView.scrollView.isScrollEnabled = true
        let script = """
        if (!globalThis.__DTScrollUnlock) {
            const changed = new Set();
            const release = () => document.querySelectorAll('.m-prevent-scrolling').forEach(node => {
                changed.add(node); node.classList.remove('m-prevent-scrolling');
            });
            const observer = new MutationObserver(release);
            globalThis.__DTScrollUnlock = {changed, release, observer};
        }
        const state = globalThis.__DTScrollUnlock;
        state.observer.disconnect();
        if (\(enabled ? "true" : "false")) {
            state.release();
            state.observer.observe(document.documentElement, {subtree:true, childList:true, attributes:true, attributeFilter:['class']});
        } else {
            for (const node of state.changed) if(node.isConnected)node.classList.add('m-prevent-scrolling');
            state.changed.clear();
        }
        """
        target?.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .world(name: "DevToolsBridge"), completionHandler: { _ in })
    }

    func navigate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("javascript:") {
            guard let script = String(trimmed.dropFirst("javascript:".count)).removingPercentEncoding else {
                notice = "Invalid JavaScript input."
                return
            }
            current?.webView.evaluateJavaScript(script) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.notice = "JavaScript error: \(error.localizedDescription)"
                    } else if let result = result {
                        self?.notice = "JavaScript result: \(String(describing: result))"
                    } else {
                        self?.notice = "JavaScript executed."
                    }
                }
            }
            return
        }
        guard let url = Self.addressURL(trimmed, engine: searchEngine) else {
            notice = "Enter a website or search terms."
            return
        }
        current?.webView.load(URLRequest(url: url))
    }

    func command(_ value: String) {
        current?.webView.evaluateJavaScript("globalThis.__DTNativeUpdate?.(\(PluginLibrary.json(bridge())),\(PluginLibrary.json(value)))")
    }

    func close(_ tab: BrowserTab) {
        prepareToLeave(tab)
        tab.dispose()
        tabs.removeAll { $0.id == tab.id }
        if selected == tab.id {
            selected = tabs.last?.id
        }
        if tabs.isEmpty {
            _ = newTab()
        }
        persistTabs()
    }

    func prepareToLeave(_ tab: BrowserTab) {
        tab.capturePreview()
    }

    func refreshTools() {
        guard ready else {
            return
        }
        for tab in tabs {
            install(tab)
            tab.webView.evaluateJavaScript("globalThis.__DTNativeUpdate?.(\(PluginLibrary.json(bridge())), '')")
        }
    }

    private func bridge() -> [String: Any] {
        var object = config
        object["enabled"] = rules.enabled
        object["runEverywhere"] = rules.runEverywhere
        object["lists"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(rules.lists))) ?? []
        object["plugins"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(plugins.rows))) ?? []
        return object
    }

    private func asset(_ name: String) -> String {
        if name.hasPrefix("vendor/"), name.hasSuffix(".js") {
            let id = String(name.dropFirst(7).dropLast(3))
            if let source = try? PackageCache.source(for: id) {
                return source
            }
        }
        if let cached = sourceCache[name] {
            return cached
        }
        guard let folder = Bundle.main.url(forResource: "BrowserResources", withExtension: nil),
              let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
            return ""
        }
        sourceCache[name] = text
        return text
    }

    private func install(_ tab: BrowserTab) {
        let controller = tab.webView.configuration.userContentController
        controller.removeAllUserScripts()
        let options = config["console"] as? [String: Any] ?? [:]
        var ids = ["eruda"]
        if config["pro"] as? Bool == true {
            if options["backend"] as? String == "vconsole" {
                ids += ["vconsole", "vueVConsole"]
            } else {
                ids += [options["vueAdapter"] as? String == "legacy" ? "vueLegacy" : "vue", "code", "dom", "timing", "fps", "features"]
            }
        }
        let libraries = ids.map { asset("vendor/\($0).js") }.joined(separator: "\n") + asset("resource-timing.js") + asset("console-ui.js")
        var script = asset("native-bootstrap.js")
        for (token, replacement) in [
            ("__RULES__", asset("rule-engine.js")),
            ("__USER_SCRIPTS__", asset("userscripts.js")), ("__RUNTIME__", asset("page-runtime.js")),
            ("__RULE_SOURCE__", PluginLibrary.json(asset("rule-engine.js"))), ("__ASSETS__", libraries),
            ("__SOURCE_FORMAT__", asset("source-formatting.js")),
            ("__CONFIG__", PluginLibrary.json(bridge()))
        ] {
            script = script.replacingOccurrences(of: token, with: replacement)
        }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    func persistTabs() {
        UserDefaults.standard.set(tabs.compactMap { $0.webView.url?.absoluteString }, forKey: "native-tabs-v2")
    }

    func persistHistory() {
        do {
            let data = try JSONEncoder().encode(history)
            UserDefaults.standard.set(data, forKey: "browser-history-v1")
        } catch {
            notice = "Failed to save browser history."
        }
    }

    func removeHistoryEntry(id: UUID) {
        if let index = history.firstIndex(where: { $0.id == id }) {
            history.remove(at: index)
        }
    }

    func clearHistory() {
        history.removeAll()
    }

    static func addressURL(_ raw: String, engine: BrowserSearchEngine) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096 else { return nil }
        if text.contains("://") { return normalizedURL(text) }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let hostname = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        let isAddress = !text.contains(where: { $0.isWhitespace }) &&
            (hostname.contains(".") || hostname == "localhost" || host.hasPrefix("["))
        return isAddress ? normalizedURL(text) : engine.searchURL(text)
    }

    func adjacentTab(direction: Int) -> BrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == selected }),
              tabs.indices.contains(index + direction) else { return nil }
        return tabs[index + direction]
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss", "file", "javascript"].contains(scheme),
              scheme != "javascript" || url.host == nil, // allow javascript: with no host
              (scheme != "file" || url.path.count > 0), // file URLs should have a path
              // For http/https/ws/wss/file: host must be non-empty (except file scheme does not have host)
              (scheme == "file" || (url.host != nil && !url.host!.isEmpty)),
              url.user == nil, url.password == nil else {
            return nil
        }
        return url
    }
}
