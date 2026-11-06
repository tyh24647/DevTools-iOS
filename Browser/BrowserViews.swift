import SwiftUI
import WebKit
import AVKit
import CoreImage
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject private var browser: BrowserController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tabDrag: CGFloat = 0
    @State private var switchingTab = false
    @State private var showingTabs = false
    @State private var address = ""
    @State private var showingSiteMenu = false
    @State private var showingCookies = false
    @State private var pageScrollingUnlocked = true
    @State private var userAgent = ""
    @State private var desktopMode = false
    @State private var zoom = 100.0
    @State private var popupBlocker = true
    @State private var adBlocker = true
    @State private var hideElementMode = false

    var body: some View {
        GeometryReader { geometry in
          ZStack {
            if tabDrag != 0, let neighbor = browser.adjacentTab(direction: tabDrag < 0 ? -1 : 1) {
                BrowserTabPreview(tab: neighbor)
                    .offset(x: tabDrag + (tabDrag < 0 ? geometry.size.width : -geometry.size.width))
                    .allowsHitTesting(false)
            }
            if let tab = browser.current {
                SafariBrowserPage(tab: tab, browser: browser, address: $address,
                    showingSiteMenu: $showingSiteMenu, showingCookies: $showingCookies,
                    pageScrollingUnlocked: $pageScrollingUnlocked, showingTabs: $showingTabs,
                    tabSwipe: AnyGesture(tabSwipe(width: geometry.size.width)), pageOffset: tabDrag)
                    .id(tab.id)
                    .allowsHitTesting(!switchingTab)
                    .task { browser.setPageScrollingUnlocked(pageScrollingUnlocked, tab: tab) }
                    .onChange(of: zoom) { _, value in tab.webView.pageZoom = value / 100 }
            } else {
                ContentUnavailableView("Open a website", systemImage: "safari")
                    .task { if browser.tabs.isEmpty { _ = browser.newTab() } }
            }
          }.clipped()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { browser.current?.capturePreview() }
        }
        .sheet(isPresented: $showingTabs) {
            BrowserTabOverview(browser: browser)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $browser.filePicker) { DocumentPickerWrapper(picker: $0) }
        .sheet(isPresented: $showingSiteMenu) {
            SiteMenuView(showingSiteMenu: $showingSiteMenu, browser: browser,
                userAgent: $userAgent, desktopMode: $desktopMode, zoom: $zoom,
                popupBlocker: $popupBlocker, adBlocker: $adBlocker, hideElementMode: $hideElementMode)
        }
        .sheet(isPresented: $showingCookies) {
            if let tab = browser.current { CookieManagerView(webView: tab.webView) }
        }
        .sheet(item: $browser.playback) { NativeVideoPlayer(source: $0, browser: browser) }
    }
    private func tabSwipe(width: CGFloat) -> some Gesture<DragGesture.Value> {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !switchingTab else { return }
                guard abs(value.translation.width) > abs(value.translation.height),
                      browser.adjacentTab(direction: value.translation.width < 0 ? -1 : 1) != nil else {
                    tabDrag = 0
                    return
                }
                if tabDrag == 0 { browser.current?.capturePreview() }
                tabDrag = max(-width, min(width, value.translation.width))
            }
            .onEnded { value in
                guard !switchingTab else { return }
                let direction = tabDrag < 0 ? -1 : 1
                let dragged = direction == -1 ? -value.translation.width : value.translation.width
                let projected = direction == -1 ? -value.predictedEndTranslation.width : value.predictedEndTranslation.width
                guard abs(tabDrag) > 0,
                      max(dragged, projected) > width * 0.3,
                      let target = browser.adjacentTab(direction: direction) else {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { tabDrag = 0 }
                    return
                }
                switchingTab = true
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25), completionCriteria: .removed) {
                    tabDrag = direction == -1 ? -width : width
                } completion: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        browser.selected = target.id
                        tabDrag = 0
                        switchingTab = false
                    }
                }
            }
    }

}

private struct SafariBrowserPage: View {
    @EnvironmentObject private var media: MediaLibrary
    @ObservedObject var tab: BrowserTab
    @ObservedObject var browser: BrowserController
    @Binding var address: String
    @Binding var showingSiteMenu: Bool
    @Binding var showingCookies: Bool
    @Binding var pageScrollingUnlocked: Bool
    @Binding var showingTabs: Bool
    let tabSwipe: AnyGesture<DragGesture.Value>
    let pageOffset: CGFloat
    @FocusState private var editingAddress: Bool
    @State private var showingDetectedMedia = false
    @State private var manualMediaURL = ""

    var body: some View {
        BrowserPage(tab: tab)
            .offset(x: pageOffset)
            .overlay(alignment: .topTrailing) {
                Group {
                    if let transfer = media.transfers.first(where: { $0.source.tabID == tab.id && !$0.finished }) ?? media.transfers.first(where: { $0.source.tabID == tab.id }) {
                        NativeTransferControl(transfer: transfer, media: media) { showingDetectedMedia = true }
                    } else {
                        Button { showingDetectedMedia = true } label: {
                            Image(systemName: "arrow.down").font(.system(size: 22)).frame(width: 48, height: 48)
                        }.accessibilityLabel("Download media or inspect detected media")
                    }
                }
                .modifier(BrowserGlassSurface()).padding(12)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Group {
                    if #available(iOS 26, *) {
                        GlassEffectContainer(spacing: 12) { controls }
                    } else { controls }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .sheet(isPresented: $showingDetectedMedia) {
                NavigationStack {
                    List {
                        Section("Detection status") {
                            if tab.mediaDiagnostics.isEmpty { Text("Waiting for the page observer. Reload the page if this does not update.") }
                            ForEach(tab.mediaDiagnostics.keys.sorted(), id: \.self) { host in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host).font(.headline)
                                    Text(tab.mediaDiagnostics[host] ?? "").font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                        Section("Playlist URL") {
                            TextField("Paste .m3u8 or video URL", text: $manualMediaURL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            Button("Save from URL") {
                                guard let url = URL(string: manualMediaURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                                      ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else {
                                    browser.notice = "Enter an HTTP(S) media URL."; return
                                }
                                browser.media.pending = PageMedia(url: url.absoluteString, page: tab.address, tabID: tab.id,
                                    title: tab.title, hls: url.absoluteString.lowercased().contains(".m3u8"), mime: "video/unknown")
                                showingDetectedMedia = false
                            }.disabled(manualMediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if tab.discoveredMedia.isEmpty { Text("No MP4 or .m3u8 requests observed yet.") }
                        ForEach(tab.discoveredMedia.sorted { left, right in
                            if left.hls != right.hls { return left.hls }
                            return (left.durationHint ?? 0) > (right.durationHint ?? 0)
                        }) { source in
                            Button {
                                browser.media.pending = source
                                showingDetectedMedia = false
                            } label: {
                                DetectedMediaRow(source: source, webView: tab.webView)
                            }
                        }
                    }
                    .navigationTitle("Detected media")
                    .toolbar { Button("Done") { showingDetectedMedia = false } }
                }
            }
            .onReceive(tab.$address) { value in if !editingAddress { address = value } }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { tab.webView.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48)
            }
                .disabled(!tab.canBack).accessibilityLabel("Back")
                .modifier(BrowserRoundGlassSurface())
            HStack(spacing: 8) {
                Menu {
                    Picker("Search engine", selection: $browser.searchEngine) {
                        ForEach(BrowserSearchEngine.allCases) { engine in Text(engine.rawValue).tag(engine) }
                    }
                    Button("Page options") { showingSiteMenu = true }
                    Toggle("Passive media detection (reload page)", isOn: $browser.passiveMediaMode)
                    Button("Show console") { browser.command("show") }.disabled(browser.passiveMediaMode)
                    Button("Hide console") { browser.command("hide") }.disabled(browser.passiveMediaMode)
                    Button("Detected media (\(tab.discoveredMedia.count))") { showingDetectedMedia = true }
                    Toggle("Enable buffer recording (reload page)", isOn: $browser.bufferCaptureEnabled).disabled(browser.passiveMediaMode)
                    Button("Open in video player", systemImage: "play.rectangle") { browser.openVideoPlayer() }
                    Toggle("Enable browser tools", isOn: $browser.rules.enabled)
                    Toggle("Disable page scroll blocking", isOn: $pageScrollingUnlocked)
                        .onChange(of: pageScrollingUnlocked) { _, value in browser.setPageScrollingUnlocked(value) }
                    Button("Manage Cookies") { showingCookies = true }
                } label: { Image(systemName: "textformat").frame(width: 28, height: 44) }
                    .accessibilityLabel("Page and developer tools")
                TextField("Search or enter website", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).focused($editingAddress).font(.callout).lineLimit(1)
                    .onSubmit { editingAddress = false; browser.navigate(address) }
                    .accessibilityIdentifier("browser-address")
                Button {
                    if editingAddress { editingAddress = false; browser.navigate(address) }
                    else if tab.webView.isLoading { tab.webView.stopLoading(); tab.webView.scrollView.refreshControl?.endRefreshing() }
                    else { tab.webView.reload() }
                } label: { Image(systemName: editingAddress ? "arrow.right" : tab.webView.isLoading ? "xmark" : "arrow.clockwise").frame(width: 28, height: 44) }
                    .accessibilityLabel(editingAddress ? "Go" : tab.webView.isLoading ? "Stop loading" : "Reload")
            }
            .padding(.horizontal, 10).frame(minHeight: 48)
            .overlay(alignment: .bottom) {
                if tab.progress > 0 && tab.progress < 1 { ProgressView(value: tab.progress).padding(.horizontal, 16) }
            }
            .modifier(BrowserGlassSurface())
            .highPriorityGesture(tabSwipe, including: editingAddress ? .subviews : .all)
            .accessibilityAction(named: "Previous tab") {
                if let target = browser.adjacentTab(direction: -1) { browser.selected = target.id }
            }
            .accessibilityAction(named: "Next tab") {
                if let target = browser.adjacentTab(direction: 1) { browser.selected = target.id }
            }
            Button {
                tab.capturePreview()
                showingTabs = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
            }
                .accessibilityLabel("Tabs and navigation: \(browser.tabs.count) tabs")
                .accessibilityHint("Opens tab previews. Touch and hold for navigation actions.")
                .modifier(BrowserRoundGlassSurface())
                .contextMenu {
                    Button("Forward", systemImage: "chevron.right") { tab.webView.goForward() }.disabled(!tab.canForward)
                    if let url = tab.webView.url { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
                    Divider()
                    ForEach(browser.tabs) { item in Button(item.title) { browser.selected = item.id } }
                    Button("New tab", systemImage: "plus") { _ = browser.newTab() }
                    Button("Close tab", role: .destructive) { browser.close(tab) }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct BrowserTabPreview: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        GeometryReader { geometry in
            if let image = tab.preview {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
            } else {
                ContentUnavailableView(tab.title, systemImage: "globe", description: Text(tab.address))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.background(Color(uiColor: .systemBackground))
    }
}

private struct BrowserTabOverview: View {
    @ObservedObject var browser: BrowserController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
                    ForEach(browser.tabs) { tab in
                        VStack(spacing: 0) {
                            Button {
                                browser.selected = tab.id
                                dismiss()
                            } label: {
                                BrowserTabPreview(tab: tab).frame(height: 230).clipped()
                            }.buttonStyle(.plain)
                            HStack {
                                Text(tab.title).font(.caption).lineLimit(1)
                                Spacer()
                                Button { browser.close(tab) } label: { Image(systemName: "xmark.circle.fill").padding(8) }
                                    .accessibilityLabel("Close \(tab.title)")
                            }.padding(8)
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tab.id == browser.selected ? Color.accentColor : .clear, lineWidth: 3))
                    }
                }.padding()
            }
            .navigationTitle("Tabs")
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New tab", systemImage: "plus") { _ = browser.newTab(); dismiss() }
                        .disabled(browser.tabs.count >= 12)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct NativeTransferControl: View {
    @ObservedObject var transfer: MediaTransfer
    let media: MediaLibrary
    let showMedia: () -> Void
    private var canStop: Bool { transfer.live && !transfer.captureEnded && transfer.state != "Finishing captured media" }
    private var progress: Double { transfer.finished && transfer.error == nil ? 1 : min(0.99, max(0, transfer.progress ?? 0)) }
    var body: some View {
        Button {
            if canStop { media.stop(transfer) } else { showMedia() }
        } label: {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(transfer.finished && transfer.error == nil ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: canStop ? "stop.fill" : transfer.finished && transfer.error == nil ? "checkmark" : transfer.captureEnded && !transfer.finished ? "hourglass" : "arrow.down")
                    .font(.system(size: 20))
            }.padding(4).frame(width: 48, height: 48)
        }
        .accessibilityLabel(canStop ? "Stop livestream recording" : transfer.finished && transfer.error == nil ? "Video saved; show detected media" : "Show media download status")
        .accessibilityValue(transfer.live ? transfer.state : "\(Int(progress * 100)) percent")
    }
}

private struct BrowserRoundGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular.interactive(), in: .circle) }
        else { content.background(.ultraThinMaterial, in: Circle()) }
    }
}

private struct BrowserGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular.interactive(), in: .capsule) }
        else { content.background(.ultraThinMaterial, in: Capsule()) }
    }
}

private struct NativeVideoPlayer: View {
    let source: BrowserPlayback
    @ObservedObject var browser: BrowserController
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle("Video player").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .task {
                    guard let tab = browser.tabs.first(where: { $0.id == source.tabID }) else { return }
                    let cookies = await tab.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    let asset = AVURLAsset(url: source.url, options: [AVURLAssetHTTPCookiesKey: cookies])
                    player.replaceCurrentItem(with: AVPlayerItem(asset: asset)); player.play()
                }
                .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
        }
    }
}

private struct DocumentPickerWrapper: UIViewControllerRepresentable {
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

// Simple placeholder SiteMenuView as no original implementation present
private struct SiteMenuView: View {
    @Binding var showingSiteMenu: Bool
    @ObservedObject var browser: BrowserController

    @Binding var userAgent: String
    @Binding var desktopMode: Bool
    @Binding var zoom: Double
    @Binding var popupBlocker: Bool
    @Binding var adBlocker: Bool
    @Binding var hideElementMode: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("User Agent") {
                    TextField("User Agent String", text: $userAgent)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    Toggle("Desktop Mode", isOn: $desktopMode)
                }
                Section("Zoom") {
                    Slider(value: $zoom, in: 50...200, step: 10) {
                        Text("Zoom")
                    }
                    Text("\(Int(zoom))%")
                }
                Section("Blocking") {
                    Toggle("Popup Blocker", isOn: $popupBlocker)
                    Toggle("Ad Blocker", isOn: $adBlocker)
                    Toggle("Hide Element Mode", isOn: $hideElementMode)
                }
            }
            .navigationTitle("Site Tools & History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showingSiteMenu = false
                    }
                }
            }
        }
    }
}

// BrowserPage is a wrapper for WKWebView for the given tab
private struct BrowserPage: UIViewRepresentable {
    let tab: BrowserTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeUIView(context: Context) -> WKWebView {
        let view = tab.webView
        view.scrollView.alwaysBounceVertical = true
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        view.scrollView.refreshControl = refresh
        context.coordinator.view = view
        let historyPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.edgePan(_:)))
        historyPan.maximumNumberOfTouches = 1
        historyPan.delegate = context.coordinator
        view.scrollView.panGestureRecognizer.require(toFail: historyPan)
        view.addGestureRecognizer(historyPan)
        context.coordinator.historyPan = historyPan
        context.coordinator.loadingObservation = view.observe(\.isLoading, options: [.new]) { [weak coordinator = context.coordinator] webView, _ in
            Task { @MainActor in
                if !webView.isLoading { coordinator?.finishNavigationIfReady() }
            }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.tab?.capturePreview()
        coordinator.clearTransition()
        coordinator.loadingObservation = nil
        if let historyPan = coordinator.historyPan { view.removeGestureRecognizer(historyPan) }
        coordinator.historyPan = nil
        view.scrollView.refreshControl?.endRefreshing()
        view.scrollView.refreshControl = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var tab: BrowserTab?
        weak var view: WKWebView?
        var historyPan: UIPanGestureRecognizer?
        var loadingObservation: NSKeyValueObservation?
        private var transition: UIView?
        private var outgoing: UIView?
        private var incoming: UIView?
        private var direction: CGFloat = 0
        private var navigationCommitted = false
        private var animationFinished = false

        init(tab: BrowserTab) { self.tab = tab }

        @objc func refresh(_ control: UIRefreshControl) {
            guard let view, view.url != nil else { control.endRefreshing(); return }
            view.reload()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let position = pan.location(in: view).x
            let velocity = pan.velocity(in: view)
            let horizontal = abs(velocity.x) > abs(velocity.y)
            let back = position <= 36 && velocity.x > 0 && view.canGoBack
            let forward = position >= view.bounds.width - 36 && velocity.x < 0 && view.canGoForward
            return horizontal && (back || forward)
        }

        @objc func edgePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let tab else { return }
            let sign: CGFloat = direction != 0 ? direction : (recognizer.location(in: view).x <= 36 ? 1 : -1)
            let distance = max(0, min(view.bounds.width, recognizer.translation(in: view).x * sign))
            switch recognizer.state {
            case .began:
                let item = sign > 0 ? view.backForwardList.backItem : view.backForwardList.forwardItem
                guard let item else { return }
                clearTransition()
                let frame = view.bounds
                let canvas = UIView(frame: frame)
                canvas.backgroundColor = .systemBackground
                canvas.isUserInteractionEnabled = false
                canvas.clipsToBounds = true
                let next = UIImageView(frame: frame)
                next.image = tab.historyPreview(for: item.url)
                next.contentMode = .scaleAspectFill
                next.clipsToBounds = true
                next.backgroundColor = .systemBackground
                canvas.addSubview(next)
                let current: UIView
                if let image = tab.historyPreview(for: view.url) ?? tab.preview {
                    let imageView = UIImageView(image: image)
                    imageView.contentMode = .scaleAspectFill
                    imageView.clipsToBounds = true
                    current = imageView
                } else {
                    current = view.snapshotView(afterScreenUpdates: false) ?? UIView()
                    current.backgroundColor = .systemBackground
                }
                current.frame = frame
                current.layer.shadowColor = UIColor.black.cgColor
                current.layer.shadowOpacity = 0.18
                current.layer.shadowRadius = 8
                canvas.addSubview(current)
                view.addSubview(canvas)
                transition = canvas
                incoming = next
                outgoing = current
                direction = sign
                navigationCommitted = false
                animationFinished = false
                updateTransition(distance: distance, width: frame.width)
            case .changed:
                updateTransition(distance: distance, width: view.bounds.width)
            case .ended:
                guard transition != nil else { return }
                let speed = recognizer.velocity(in: view).x * sign
                let commit = distance > view.bounds.width * 0.3 || speed > 650
                guard commit, (sign > 0 ? view.goBack() : view.goForward()) != nil else {
                    animateTransition(to: 0, commit: false)
                    return
                }
                navigationCommitted = true
                animateTransition(to: view.bounds.width, commit: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.clearTransition() }
            case .cancelled, .failed:
                animateTransition(to: 0, commit: false)
            default:
                break
            }
        }

        private func updateTransition(distance: CGFloat, width: CGFloat) {
            guard width > 0 else { return }
            outgoing?.transform = CGAffineTransform(translationX: distance * direction, y: 0)
            incoming?.transform = CGAffineTransform(translationX: (distance - width) * direction * 0.25, y: 0)
        }

        private func animateTransition(to distance: CGFloat, commit: Bool) {
            guard let view else { clearTransition(); return }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.updateTransition(distance: distance, width: view.bounds.width)
            } completion: { _ in
                self.animationFinished = true
                if commit { self.finishNavigationIfReady() }
                else { self.clearTransition() }
            }
        }

        func finishNavigationIfReady() {
            guard navigationCommitted, animationFinished, view?.isLoading == false else { return }
            clearTransition()
        }

        func clearTransition() {
            transition?.removeFromSuperview()
            transition = nil
            outgoing = nil
            incoming = nil
            direction = 0
            navigationCommitted = false
            animationFinished = false
        }
    }
}

private struct CookieManagerView: View {
    @Environment(\.dismiss) private var dismiss

    let webView: WKWebView

    @State private var cookies: [HTTPCookie] = []
    @State private var loading = true
    @State private var error: String?

    // For editing/adding cookies
    @State private var editingCookie: EditableCookie?
    @State private var showingAddCookie = false

    private let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    ProgressView("Loading cookies...")
                } else if let error {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    if cookies.isEmpty {
                        Text("No cookies for this site")
                            .foregroundColor(.secondary)
                    } else {
                        List {
                            ForEach(cookies, id: \.self) { cookie in
                                Button(action: {
                                    editingCookie = EditableCookie(from: cookie)
                                }) {
                                    VStack(alignment: .leading) {
                                        Text(cookie.name)
                                            .font(.headline)
                                        Text(cookie.value)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        HStack {
                                            Text(cookie.domain)
                                            Text(cookie.path)
                                            if let expires = cookie.expiresDate {
                                                Text("Expires: \(expires, formatter: dateFormatter)")
                                            } else {
                                                Text("Session")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .onDelete(perform: deleteCookies)
                        }
                    }
                }
            }
            .navigationTitle("Manage Cookies")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        showingAddCookie = true
                    }
                }
            }
            .onAppear {
                loadCookies()
            }
            .sheet(item: $editingCookie) { cookie in
                CookieEditView(cookie: cookie) { updatedCookie in
                    saveCookie(updatedCookie)
                    editingCookie = nil
                } onCancel: {
                    editingCookie = nil
                }
            }
            .sheet(isPresented: $showingAddCookie) {
                CookieAddView { newCookie in
                    saveCookie(newCookie)
                    showingAddCookie = false
                } onCancel: {
                    showingAddCookie = false
                }
            }
        }
    }

    private func loadCookies() {
        loading = true
        error = nil
        cookies.removeAll()

        guard let url = webView.url else {
            error = "No URL loaded in the current tab."
            loading = false
            return
        }

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { allCookies in
            DispatchQueue.main.async {
                self.cookies = allCookies.filter { cookie in
                    self.cookieMatches(url: url, cookie: cookie)
                }
                self.loading = false
            }
        }
    }

    private func cookieMatches(url: URL, cookie: HTTPCookie) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let cookieDomain = cookie.domain.lowercased()

        if cookieDomain.hasPrefix(".") {
            return host == String(cookieDomain.dropFirst()) || host.hasSuffix(cookieDomain)
        } else {
            return host == cookieDomain
        }
    }

    private func deleteCookies(at offsets: IndexSet) {
        for index in offsets {
            let cookie = cookies[index]
            WKWebsiteDataStore.default().httpCookieStore.delete(cookie)
        }
        cookies.remove(atOffsets: offsets)
    }

    private func saveCookie(_ cookie: EditableCookie) {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path,
            .secure: cookie.secure
        ]
        if let expires = cookie.expiresDate {
            properties[.expires] = expires
        }
        // Removed .httpOnly as HTTPCookiePropertyKey.httpOnly does not exist

        guard let httpCookie = HTTPCookie(properties: properties) else {
            return
        }

        WKWebsiteDataStore.default().httpCookieStore.setCookie(httpCookie) {
            DispatchQueue.main.async {
                loadCookies()
            }
        }
    }
}

private struct EditableCookie: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresDate: Date?
    var secure: Bool = false
    var httpOnly: Bool = false // kept for UI but not saved as property

    init(name: String, value: String, domain: String, path: String, expiresDate: Date?, secure: Bool = false, httpOnly: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresDate = expiresDate
        self.secure = secure
        self.httpOnly = httpOnly
    }

    init(from cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path
        self.expiresDate = cookie.expiresDate
        self.secure = cookie.isSecure
        self.httpOnly = cookie.isHTTPOnly
    }
}

private struct CookieEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var cookie: EditableCookie
    var onSave: (EditableCookie) -> Void
    var onCancel: () -> Void

    @State private var expiresInFuture: Bool

    private let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    init(cookie: EditableCookie, onSave: @escaping (EditableCookie) -> Void, onCancel: @escaping () -> Void) {
        self._cookie = State(initialValue: cookie)
        self.onSave = onSave
        self.onCancel = onCancel
        self._expiresInFuture = State(initialValue: cookie.expiresDate != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cookie Info") {
                    TextField("Name", text: $cookie.name)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("Value", text: $cookie.value)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("Domain", text: $cookie.domain)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("Path", text: $cookie.path)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                }
                Section("Options") {
                    Toggle("Secure", isOn: $cookie.secure)
                    Toggle("HTTP Only", isOn: $cookie.httpOnly)
                }
                Section("Expiration") {
                    Toggle("Set Expiration", isOn: $expiresInFuture.animation())
                    if expiresInFuture {
                        DatePicker("Expires", selection: Binding<Date>(
                            get: {
                                cookie.expiresDate ?? Date().addingTimeInterval(86400)
                            },
                            set: {
                                cookie.expiresDate = $0
                            }),
                                   displayedComponents: [.date, .hourAndMinute])
                    } else {
                        Text("Session cookie (no expiration)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Cookie")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !expiresInFuture {
                            cookie.expiresDate = nil
                        }
                        onSave(cookie)
                        dismiss()
                    }
                    .disabled(cookie.name.isEmpty || cookie.domain.isEmpty || cookie.path.isEmpty)
                }
            }
        }
    }
}

private struct CookieAddView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = EditableCookie(name: "", value: "", domain: "", path: "/", expiresDate: nil)
    @State private var expiresInFuture = false

    var onSave: (EditableCookie) -> Void
    var onCancel: () -> Void

    private let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Cookie Info") {
                    TextField("Name", text: $cookie.name)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("Value", text: $cookie.value)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("Domain", text: $cookie.domain)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("Path", text: $cookie.path)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                }
                Section("Options") {
                    Toggle("Secure", isOn: $cookie.secure)
                    Toggle("HTTP Only", isOn: $cookie.httpOnly)
                }
                Section("Expiration") {
                    Toggle("Set Expiration", isOn: $expiresInFuture.animation())
                    if expiresInFuture {
                        DatePicker("Expires", selection: Binding<Date>(
                            get: {
                                cookie.expiresDate ?? Date().addingTimeInterval(86400)
                            },
                            set: {
                                cookie.expiresDate = $0
                            }),
                                   displayedComponents: [.date, .hourAndMinute])
                    } else {
                        Text("Session cookie (no expiration)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Add Cookie")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if !expiresInFuture {
                            cookie.expiresDate = nil
                        }
                        onSave(cookie)
                        dismiss()
                    }
                    .disabled(cookie.name.isEmpty || cookie.domain.isEmpty || cookie.path.isEmpty)
                }
            }
        }
    }
}

// Other structs and extensions remain unchanged...


/// Row-local work is cancelled when the media sheet disappears; only small images are cached.
private struct DetectedMediaRow: View {
    let source: PageMedia
    let webView: WKWebView
    @State private var thumbnail: UIImage?
    @State private var resolution = "Checking resolution…"
    @State private var loading = true
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.12))
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else if loading {
                    ProgressView()
                } else {
                    Image(systemName: "video").foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(thumbnail == nil ? "Preview unavailable" : "Video preview")
            VStack(alignment: .leading, spacing: 4) {
                Text(source.hls ? "HLS playlist (.m3u8)" : "Video resource")
                Text(resolution).font(.caption).foregroundStyle(.secondary)
                if let duration = source.durationHint, duration.isFinite, duration > 0 {
                    Text("\(Int(duration)) seconds").font(.caption)
                }
                Text(URL(string: source.url)?.host ?? "Media").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: source.url) { await loadPreview() }
    }

    @MainActor
    private func loadPreview() async {
        loading = true
        resolution = "Checking resolution…"
        thumbnail = Self.images.object(forKey: source.id as NSString)
        defer { loading = false }
        guard let url = URL(string: source.url), ["http", "https"].contains(url.scheme ?? ""),
              let page = URL(string: source.page) else { resolution = "Resolution unavailable"; return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard !Task.isCancelled else { return }
        let userAgent = webView.customUserAgent
        var previewURL = url
        // A master playlist can advertise several resolutions. Show all of them before selection.
        if source.hls {
            let http = MediaHTTP(page: page, cookies: cookies, userAgent: userAgent)
            defer { http.close() }
            if let playlist = try? await http.playlist(url) {
                let variants = playlist.variants.sorted { $0.height > $1.height }
                let sizes = Set(variants.filter { $0.width > 0 && $0.height > 0 }.map { "\($0.width)×\($0.height)" })
                if !sizes.isEmpty {
                    resolution = variants.map { "\($0.width)×\($0.height)" }
                        .filter { sizes.contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
                }
                previewURL = variants.first?.url ?? url
            }
        }
        guard !Task.isCancelled else { return }
        let asset = AVURLAsset(url: previewURL, options: [AVURLAssetHTTPCookiesKey: cookies])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 288, height: 162)
        // A bounded lifetime also covers servers which accept a connection but never serve media.
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { generator.cancelAllCGImageGeneration(); asset.cancelLoading() }
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            if resolution == "Checking resolution…",
               let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let display = size.applying(transform)
                if display.width.isFinite && display.height.isFinite && abs(display.width) > 0 && abs(display.height) > 0 {
                    resolution = "\(Int(abs(display.width)))×\(Int(abs(display.height)))"
                }
            }
            if resolution == "Checking resolution…" { resolution = "Resolution unavailable" }
            guard thumbnail == nil, !Task.isCancelled else { return }
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let seconds = duration.isFinite && duration > 0 ? min(30, duration * 0.1) : 0
            for time in [seconds, 0] {
                guard !Task.isCancelled else { return }
                if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                    let image = UIImage(cgImage: frame.image)
                    thumbnail = image
                    Self.images.setObject(image, forKey: source.id as NSString, cost: frame.image.bytesPerRow * frame.image.height)
                    break
                }
            }
            // Many HLS streams have no I-frame playlist for AVAssetImageGenerator.
            // Decode a muted opening frame instead, without adding a visible player.
            if thumbnail == nil, source.hls, !Task.isCancelled {
                let item = AVPlayerItem(asset: asset)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                item.add(output)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.play()
                defer { player.pause(); player.replaceCurrentItem(with: nil); item.remove(output) }
                for _ in 0..<80 {
                    guard !Task.isCancelled else { return }
                    if let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
                        let frame = CIImage(cvPixelBuffer: buffer)
                        let scale = min(288 / frame.extent.width, 162 / frame.extent.height, 1)
                        let small = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        if let cgImage = CIContext().createCGImage(small, from: small.extent) {
                            let image = UIImage(cgImage: cgImage)
                            thumbnail = image
                            Self.images.setObject(image, forKey: source.id as NSString, cost: cgImage.bytesPerRow * cgImage.height)
                            if resolution == "Resolution unavailable" {
                                let size = item.presentationSize
                                if size.width > 0 && size.height > 0 {
                                    resolution = "\(Int(size.width))×\(Int(size.height))"
                                }
                            }
                            break
                        }
                    }
                    if item.status == .failed { break }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
            asset.cancelLoading()
        }
    }
}
