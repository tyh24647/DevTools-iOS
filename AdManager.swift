import SwiftUI
import UIKit
import GoogleMobileAds
import UserMessagingPlatform

/// Ads are linked only to the containing app. Safari and action extensions never display ads
/// or pass visited URLs, rules, console logs, or resource timing data to an ad provider.
@MainActor
final class AdManager: NSObject, ObservableObject, FullScreenContentDelegate {
    @Published private(set) var canRequestAds = false
    @Published private(set) var privacyOptionsRequired = false
    @Published private(set) var bannerRevision = 0
    @Published var error: String?
    var isPro = false
    var isEditing = false
    private var interstitial: InterstitialAd?
    private var appOpen: AppOpenAd?
    private var interstitialLoadedAt: Date?
    private var appOpenLoadedAt: Date?
    private var started = false
    private var gatheringConsent = false
    private var presenting = false
    private var pendingBreak = false
    private var lastPresented = Date.distantPast
    private var lastEligibility = Date()

    static func setting(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }

    static func request() -> Request {
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    func prepare() async {
        guard !isPro && !gatheringConsent else {
            return
        }
        gatheringConsent = true
        defer {
            gatheringConsent = false
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
        } catch {
            self.error = error.localizedDescription
        }
        canRequestAds = ConsentInformation.shared.canRequestAds && !isPro
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        if canRequestAds && !started {
            started = true
            await MobileAds.shared.start()
            await loadAds()
        }
    }

    func setPro(_ value: Bool) {
        isPro = value
        if value {
            canRequestAds = false
            interstitial = nil
            appOpen = nil
            pendingBreak = false
        } else if started {
            canRequestAds = ConsentInformation.shared.canRequestAds
            Task {
                await loadAds()
            }
        }
    }

    /// Use an app-open ad for an actual foreground transition, not when returning from an ad
    /// click or system purchase sheet. Skip the first cold launch while consent is being gathered.
    func foregrounded() {
        guard eligible, Date().timeIntervalSince(lastPresented) > 30,
              let appOpen, let loaded = appOpenLoadedAt,
              Date().timeIntervalSince(loaded) < 4 * 3600 else {
            return
        }
        presenting = true
        lastPresented = Date()
        lastEligibility = Date()
        appOpen.present(from: nil)
    }

    /// Three minutes makes an interstitial eligible; a completed navigation or list edit is
    /// the presentation boundary. A timer never interrupts typing or an in-flight purchase.
    func tick() {
        if !isPro && Date().timeIntervalSince(lastEligibility) >= 180 {
            pendingBreak = true
        }
    }

    func listEntryAdded() {
        bannerRevision += 1
        pendingBreak = true
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            naturalBreak()
        }
    }

    func naturalBreak() {
        guard pendingBreak, eligible,
              Date().timeIntervalSince(lastPresented) > 30,
              let interstitial, let loaded = interstitialLoadedAt,
              Date().timeIntervalSince(loaded) < 3600 else {
            return
        }
        pendingBreak = false
        presenting = true
        lastPresented = Date()
        lastEligibility = Date()
        interstitial.present(from: nil)
    }

    func showPrivacyOptions() async {
        do {
            try await ConsentForm.presentPrivacyOptionsForm(from: nil)
            canRequestAds = ConsentInformation.shared.canRequestAds && !isPro
            bannerRevision += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var eligible: Bool {
        !isPro && canRequestAds && !presenting && !isEditing && UIApplication.shared.applicationState == .active && rootController?.presentedViewController == nil
    }

    private var rootController: UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
    }

    private func loadAds() async {
        guard canRequestAds && !isPro else {
            return
        }
        do {
            interstitial = try await InterstitialAd.load(with: Self.setting("DevToolsInterstitialAdID"), request: Self.request())
            interstitial?.fullScreenContentDelegate = self
            interstitialLoadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
        do {
            appOpen = try await AppOpenAd.load(with: Self.setting("DevToolsAppOpenAdID"), request: Self.request())
            appOpen?.fullScreenContentDelegate = self
            appOpenLoadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
        if isPro {
            interstitial = nil
            appOpen = nil
        }
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        presenting = false
        interstitial = nil
        appOpen = nil
        lastPresented = Date()
        Task {
            await loadAds()
        }
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        self.error = error.localizedDescription
        adDidDismissFullScreenContent(ad)
    }
}

struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = AdManager.setting("DevToolsBannerAdID")
        banner.load(AdManager.request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
    }
}

struct AdFooter: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ads: AdManager

    var body: some View {
        if !model.isPro && ads.canRequestAds {
            VStack(spacing: 2) {
                Text("Advertisement")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                BannerAdView()
                    .id(ads.bannerRevision)
                    .frame(width: 320, height: 50)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }
}

