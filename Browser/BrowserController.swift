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
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    let id = UUID()
    let webView: WKWebView
    weak var owner: BrowserController?
    @Published var title = "New tab"
    @Published var address = ""
    @Published var progress = 0.0
    @Published var canBack = false
    @Published var canForward = false
    @Published var discoveredMedia: [PageMedia] = []
    @Published var mediaDiagnostics: [String: String] = [:]
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
        // Popup configurations inherit the opener's controller and its message handlers.
        // Keep the supplied configuration for window.opener, but own this tab's bridge.
        configuration.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .world(name: "DevToolsBridge"), name: "dtMedia")
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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        if let body = message.body as? [String: Any], body["type"] as? String == "media-diagnostics",
           ["http", "https"].contains(message.frameInfo.securityOrigin.protocol), let summary = body["summary"] as? String {
            mediaDiagnostics[message.frameInfo.securityOrigin.host] = String(summary.prefix(2000))
            replyHandler(true, nil)
            return
        }
        if let body = message.body as? [String: Any], body["type"] as? String == "media-discovery" {
            guard ["http", "https"].contains(message.frameInfo.securityOrigin.protocol),
                  let text = body["url"] as? String, text.utf8.count <= 8192,
                  let resource = URL(string: text), ["http", "https"].contains(resource.scheme ?? ""),
                  resource.user == nil, resource.password == nil,
                  let page = message.frameInfo.request.url ?? webView.url else { replyHandler(nil, "Invalid media discovery"); return }
            let source = PageMedia(url: text, page: page.absoluteString, tabID: id,
                title: String((body["title"] as? String ?? title).prefix(160)), hls: body["hls"] as? Bool ?? false, mime: "video/unknown", durationHint: body["duration"] as? Double)
            if let index = discoveredMedia.firstIndex(where: { $0.discoveryKey == source.discoveryKey }) {
                if discoveredMedia[index] != source { discoveredMedia[index] = source }
            } else if discoveredMedia.count < 200 { discoveredMedia.append(source) }
            webView.evaluateJavaScript("globalThis.__DTMedia?.add(\(PluginLibrary.json(text)),true,\(source.hls),'video/unknown')")
            replyHandler(true, nil)
            return
        }
        guard message.frameInfo.isMainFrame, let url = webView.url,
              ["http", "https"].contains(url.scheme ?? ""),
              let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "Untrusted media request.")
            return
        }
        if type == "download-button-position-get" {
            replyHandler(UserDefaults.standard.dictionary(forKey: "download-button-position-v1") ?? [:], nil)
            return
        }
        if type == "download-button-position-save" {
            guard let x = body["x"] as? Double, let y = body["y"] as? Double,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                replyHandler(nil, "Invalid download button position.")
                return
            }
            UserDefaults.standard.set(["x": x, "y": y], forKey: "download-button-position-v1")
            replyHandler(true, nil)
            return
        }
        do {
            if type == "media-unavailable" {
                owner?.notice = String((body["reason"] as? String ?? "No supported media source is available.").prefix(300))
            } else if type.hasPrefix("blob-") {
                try owner?.media.blobMessage(body, tabID: id)
            } else if type == "leave" {
                owner?.media.leave(tabID: id, reason: "Page route changed")
            } else if let resource = body["url"] as? String, resource.utf8.count <= 4096 {
                if type == "stop" || type == "unload" {
                    if type == "stop", let transfer = owner?.media.transfers.first(where: { $0.source.tabID == id && $0.source.url == resource && !$0.finished }) {
                        owner?.media.stop(transfer)
                    } else {
                        owner?.media.leave(tabID: id, url: resource, reason: "Video source unloaded")
                    }
                } else if type == "save" {
                    guard resource.hasPrefix("blob:") || BrowserController.normalizedURL(resource) != nil else {
                        throw MediaFailure.invalid("Unsupported media resource URL.")
                    }
                    owner?.media.pending = PageMedia(url: resource, page: url.absoluteString, tabID: id,
                                                     title: String((body["title"] as? String ?? title).prefix(160)),
                                                     hls: body["hls"] as? Bool ?? false, mime: String((body["mime"] as? String ?? "").prefix(120)))
                } else if type == "share" {
                    owner?.notice = "Media URL: \(resource)"
                }
            }
            replyHandler(true, nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "devtools" {
            owner?.handle(url)
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
            Task {
                await owner?.prepareToLeave(self, reason: "Navigated to another page")
                decisionHandler(.allow)
            }
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        discoveredMedia = []
        mediaDiagnostics = [:]
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
        owner?.media.leave(tabID: id, reason: "Web content process ended")
        owner?.forceCloseBlobs(tabID: id, reason: "Web content process ended")
        owner?.notice = "The webpage process ended. Captured media is retained. Reload to restore the page."
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dtMedia", contentWorld: .world(name: "DevToolsBridge"))
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

struct BrowserPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let tabID: UUID
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
    @Published var playback: BrowserPlayback?
    @Published var bufferCaptureEnabled = false { didSet { refreshTools() } }
    @Published var passiveMediaMode = true { didSet { refreshTools() } }
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

    let media: MediaLibrary
    let plugins: PluginLibrary
    private var config: [String: Any] = [:]
    private var ready = false
    private var sourceCache: [String: String] = [:]
    private var adBlockingRules: WKContentRuleList?
    var current: BrowserTab? {
        tabs.first { $0.id == selected }
    }

    init(media: MediaLibrary, plugins: PluginLibrary) {
        self.media = media
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

        media.onBlobStart = { [weak self] transfer in
            guard let tab = self?.tabs.first(where: { $0.id == transfer.source.tabID }) else {
                self?.media.finishBlob(transfer, reason: "Source tab unavailable")
                return
            }
            Task {
                do {
                    _ = try await tab.webView.callAsyncJavaScript("if (!globalThis.__DTMSE) throw new Error('Enable buffer recording in Page tools, then reload the source page. HLS recording does not require buffer hooks.'); return await globalThis.__DTMSE.start(url,id);", arguments: ["url": transfer.source.url, "id": transfer.id.uuidString], in: nil, contentWorld: .page)
                } catch {
                    self?.media.finishBlob(transfer, reason: error.localizedDescription)
                }
            }
        }
        media.onBlobStop = { [weak self] transfer in
            Task {
                await self?.flushBlob(transfer)
            }
        }
        media.onStatus = { [weak self] transfer in
            guard let tab = self?.tabs.first(where: { $0.id == transfer.source.tabID }) else {
                return
            }
            let code = "globalThis.__DTMedia?.status(\(PluginLibrary.json(transfer.source.url)),\(PluginLibrary.json(transfer.state)),\(transfer.progress.map { String($0) } ?? "null"),\(!transfer.finished),\(transfer.live),\(!transfer.captureEnded && transfer.state != "Finishing captured media"))"
            tab.webView.evaluateJavaScript(code)
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
            media.recoverInterrupted()
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

    func openVideoPlayer() {
        guard let tab = current else { return }
        Task {
            do {
                let raw = try await tab.webView.evaluateJavaScript("globalThis.__DTMedia?.playableURL?.() || null") as? String
                guard let raw, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else {
                    notice = "This page has not exposed an MP4 or HLS URL for the native player. Buffer, WebRTC, and protected streams stay in the webpage player."
                    return
                }
                playback = BrowserPlayback(url: url, tabID: tab.id)
            } catch { notice = error.localizedDescription }
        }
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
        Task {
            await prepareToLeave(tab, reason: "Tab closed")
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
    }

    func prepareToLeave(_ tab: BrowserTab, reason: String) async {
        tab.capturePreview()
        media.leave(tabID: tab.id, reason: reason)
        for transfer in media.transfers where transfer.source.tabID == tab.id && transfer.source.isBlob && !transfer.ingressClosed {
            await flushBlob(transfer)
        }
    }

    private func flushBlob(_ transfer: MediaTransfer) async {
        if let tab = tabs.first(where: { $0.id == transfer.source.tabID }) {
            // A document can't hold navigation indefinitely. Native checkpoints remain valid
            // if the WebKit promise cannot flush before the timeout/page process loss.
            await withCheckedContinuation { continuation in
                let gate = BrowserFlushGate(continuation)
                let timeout = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    gate.finish()
                }
                tab.webView.callAsyncJavaScript("return await globalThis.__DTMSE?.stop(id);", arguments: ["id": transfer.id.uuidString], in: nil, in: .page, completionHandler: { _ in
                    Task { @MainActor in
                        timeout.cancel()
                        gate.finish()
                    }
                })
            }
        }
        media.finishBlob(transfer, reason: "Source stopped")
    }

    func forceCloseBlobs(tabID: UUID, reason: String) {
        for transfer in media.transfers where transfer.source.tabID == tabID && transfer.source.isBlob {
            media.finishBlob(transfer, reason: reason)
        }
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
        controller.addUserScript(WKUserScript(source: asset("media-discovery.js"), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .world(name: "DevToolsBridge")))
        if passiveMediaMode { return }
        controller.addUserScript(WKUserScript(source: asset("native-bridge.js"), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .world(name: "DevToolsBridge")))
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
            ("__MSE__", bufferCaptureEnabled ? asset("mse-capture.js") : ""), ("__RULES__", asset("rule-engine.js")),
            ("__USER_SCRIPTS__", asset("userscripts.js")), ("__RUNTIME__", asset("page-runtime.js")),
            ("__RULE_SOURCE__", PluginLibrary.json(asset("rule-engine.js"))), ("__ASSETS__", libraries),
            ("__SOURCE_FORMAT__", asset("source-formatting.js")), ("__MEDIA__", asset("media-resources.js")),
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

    func handle(_ url: URL) {
        guard url.scheme == "devtools", let host = url.host,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            notice = "Unsupported DevTools link."
            return
        }
        switch host {
        case "record":
            guard let resource = parts.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = Self.normalizedURL(resource) else {
                notice = "Unsupported DevTools recording link."
                return
            }
            let tab = newTab(url: target)
            if let tab {
                media.pending = PageMedia(url: target.absoluteString, page: target.absoluteString, tabID: tab.id, title: "Safari media", hls: target.pathExtension.lowercased() == "m3u8", mime: "video/mp4")
            }
        case "download":
            handleDownloadLink(parts)
        default:
            notice = "Unsupported DevTools link."
        }
    }

    private func handleDownloadLink(_ parts: URLComponents) {
        guard let rawResource = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let resource = Self.normalizedURL(rawResource),
              let resourceScheme = resource.scheme?.lowercased(),
              resourceScheme == "http" || resourceScheme == "https" else {
            notice = "Unsupported DevTools download link."
            return
        }
        let page = parts.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Self.normalizedURL).flatMap { pageURL in
            guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return pageURL
        } ?? resource
        let title = String(parts.queryItems?.first(where: { $0.name == "title" })?.value ?? "Downloaded media").prefix(160)
        let extensionName = resource.pathExtension.lowercased()
        let mime: String
        switch extensionName {
        case "m3u8": mime = "application/vnd.apple.mpegurl"
        case "webm": mime = "video/webm"
        case "mov": mime = "video/quicktime"
        case "mp4", "m4v": mime = "video/mp4"
        default: mime = "video/unknown"
        }
        media.pending = PageMedia(url: resource.absoluteString, page: page.absoluteString,
                                  tabID: current?.id ?? UUID(), title: String(title),
                                  hls: extensionName == "m3u8", mime: mime)
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

/// Navigation resumes once, even when a destroyed page never resolves its promise.
@MainActor
private final class BrowserFlushGate {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

