import Foundation
import SwiftUI
import WebKit
import Combine

struct NativeBrowserRules: Codable {
    var enabled = true
    var runEverywhere = true
    var lists = [RuleList(name: "Development sites", kind: .allow), RuleList(name: "Excluded sites", kind: .block)]
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
    private var observers: [NSKeyValueObservation] = []

    init(owner: BrowserController, configuration: WKWebViewConfiguration) {
        self.owner = owner
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .world(name: "DevToolsBridge"), name: "dtMedia")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
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
        guard message.frameInfo.isMainFrame, let url = webView.url,
              ["http", "https"].contains(url.scheme ?? ""),
              let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "Untrusted media request.")
            return
        }
        do {
            if type.hasPrefix("blob-") {
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
        guard BrowserController.normalizedURL(url.absoluteString) != nil || url.absoluteString == "about:blank" else {
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.persistTabs()
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

@MainActor
final class BrowserController: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selected: UUID?
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
    let media: MediaLibrary
    let plugins: PluginLibrary
    private var config: [String: Any] = [:]
    private var ready = false
    private var sourceCache: [String: String] = [:]
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
        media.onBlobStart = { [weak self] transfer in
            guard let tab = self?.tabs.first(where: { $0.id == transfer.source.tabID }) else {
                self?.media.finishBlob(transfer, reason: "Source tab unavailable")
                return
            }
            Task {
                do {
                    _ = try await tab.webView.callAsyncJavaScript("return await globalThis.__DTMSE.start(url,id);", arguments: ["url": transfer.source.url, "id": transfer.id.uuidString], in: nil, contentWorld: .page)
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
            let code = "globalThis.__DTMedia?.status(\(PluginLibrary.json(transfer.source.url)),\(PluginLibrary.json(transfer.state)),\(transfer.progress.map { String($0) } ?? "null"),\(!transfer.finished),\(transfer.live))"
            tab.webView.evaluateJavaScript(code)
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
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        let tab = BrowserTab(owner: self, configuration: configuration)
        install(tab)
        tabs.append(tab)
        selected = tab.id
        if let url {
            tab.webView.load(URLRequest(url: url))
        }
        return tab
    }

    func navigate(_ text: String) {
        guard let url = Self.normalizedURL(text) else {
            notice = "Enter a valid HTTP(S) URL without embedded credentials."
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
            ("__MSE__", asset("mse-capture.js")), ("__RULES__", asset("rule-engine.js")),
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

    func handle(_ url: URL) {
        guard url.scheme == "devtools", url.host == "record", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let resource = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = Self.normalizedURL(resource) else {
            notice = "Unsupported DevTools link."
            return
        }
        let tab = newTab(url: target)
        if let tab {
            media.pending = PageMedia(url: target.absoluteString, page: target.absoluteString, tabID: tab.id, title: "Safari media", hls: target.pathExtension.lowercased() == "m3u8", mime: "video/mp4")
        }
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
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
