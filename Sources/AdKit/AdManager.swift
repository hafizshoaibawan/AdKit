//
//  AdManager.swift
//  AdKit - shared AdMob + Firebase setup for all apps
//
//  In your app:
//      import AdKit
//
//      AdManager.shared.configure(
//          banner: "ca-app-pub-xxx/xxx",
//          interstitial: "ca-app-pub-xxx/xxx",
//          rewarded: "ca-app-pub-xxx/xxx",
//          appOpen: "ca-app-pub-xxx/xxx"
//      )
//      await AdManager.shared.start()
//
//  Banner:        AdBanner()
//  Interstitial:  AdManager.shared.showInterstitial { /* continue */ }
//  Rewarded:      AdManager.shared.showRewarded { /* give reward */ }
//  App open:      AdManager.shared.showAppOpenIfAvailable()   (on scenePhase == .active)
//  Remove ads:    AdManager.shared.adsRemoved = true          (after a purchase)
//

import SwiftUI
import GoogleMobileAds
import UserMessagingPlatform
import AppTrackingTransparency
import FirebaseCore

// MARK: - Ad unit IDs

public struct AdUnitIDs {
    public var banner: String?
    public var interstitial: String?
    public var rewarded: String?
    public var appOpen: String?

    public init(banner: String? = nil, interstitial: String? = nil,
                rewarded: String? = nil, appOpen: String? = nil) {
        self.banner = banner
        self.interstitial = interstitial
        self.rewarded = rewarded
        self.appOpen = appOpen
    }

    /// Google's official test IDs. Used automatically in DEBUG builds.
    public static let test = AdUnitIDs(
        banner:       "ca-app-pub-3940256099942544/2435281174",
        interstitial: "ca-app-pub-3940256099942544/4411468910",
        rewarded:     "ca-app-pub-3940256099942544/1712485313",
        appOpen:      "ca-app-pub-3940256099942544/5575463023"
    )
}

// MARK: - AdManager

@MainActor
public final class AdManager: NSObject, ObservableObject {

    public static let shared = AdManager()

    // Settings (change before calling start() if you want)
    /// Minimum seconds between two interstitials.
    public var interstitialCooldown: TimeInterval = 60
    /// Use Google's test IDs in DEBUG builds even after configure(). Keep true to avoid account bans.
    public var useTestIDsInDebug = true

    /// True once consent is gathered and the SDK is started.
    @Published public private(set) var canRequestAds = false
    @Published public private(set) var isInterstitialReady = false
    @Published public private(set) var isRewardedReady = false

    /// Set to true after a "Remove Ads" purchase. Saved automatically.
    @Published public var adsRemoved: Bool = UserDefaults.standard.bool(forKey: "AdKit.adsRemoved") {
        didSet { UserDefaults.standard.set(adsRemoved, forKey: "AdKit.adsRemoved") }
    }

    /// Banners, interstitials and app open ads follow this. Rewarded ads don't (the user chooses them).
    public var shouldShowAds: Bool { canRequestAds && !adsRemoved }

    private var releaseIDs = AdUnitIDs()
    var ids: AdUnitIDs {
        #if DEBUG
        if useTestIDsInDebug { return .test }
        #endif
        return releaseIDs
    }

    private var interstitial: InterstitialAd?
    private var rewarded: RewardedAd?
    private var appOpen: AppOpenAd?
    private var appOpenLoadDate: Date?
    private var lastInterstitialDate: Date?
    private var isStarted = false
    private var isShowingFullScreen = false
    private var onDismiss: (() -> Void)?
    private let appOpenExpiry: TimeInterval = 4 * 3600

    private override init() { super.init() }

    // MARK: Setup

    /// Set this app's real ad unit IDs and start Firebase. Call once, as early as possible
    /// (App init or AppDelegate). Leave an ID nil to turn that ad type off.
    public func configure(banner: String? = nil,
                          interstitial: String? = nil,
                          rewarded: String? = nil,
                          appOpen: String? = nil) {
        releaseIDs = AdUnitIDs(banner: banner, interstitial: interstitial,
                               rewarded: rewarded, appOpen: appOpen)
        Self.configureFirebaseIfPossible()
    }

    /// Starts Firebase only if GoogleService-Info.plist is in the app, so a missing file doesn't crash.
    public static func configureFirebaseIfPossible() {
        guard FirebaseApp.app() == nil else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            print("[AdKit] GoogleService-Info.plist not found - Firebase not started.")
            return
        }
        FirebaseApp.configure()
    }

    /// Call once when the first screen appears. Shows the consent form (EU), asks for
    /// tracking permission, starts the Mobile Ads SDK and preloads ads.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true

        await gatherConsent()
        await requestTrackingPermission()

        guard ConsentInformation.shared.canRequestAds else { return }

        _ = await MobileAds.shared.start()
        canRequestAds = true
        loadInterstitial()
        loadRewarded()
        loadAppOpen()
    }

    private func gatherConsent() async {
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
        } catch {
            print("[AdKit] Consent error: \(error.localizedDescription)")
        }
    }

    private func requestTrackingPermission() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }

    /// Show a "Privacy options" button in Settings when this is true (required for EU users).
    public var isPrivacyOptionsRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    public func presentPrivacyOptions() async {
        try? await ConsentForm.presentPrivacyOptionsForm(from: nil)
    }

    // MARK: Interstitial

    public func loadInterstitial() {
        guard shouldShowAds, interstitial == nil, let id = ids.interstitial else { return }
        Task {
            do {
                let ad = try await InterstitialAd.load(with: id, request: Request())
                ad.fullScreenContentDelegate = self
                interstitial = ad
                isInterstitialReady = true
            } catch {
                print("[AdKit] Interstitial failed: \(error.localizedDescription)")
            }
        }
    }

    /// Shows an interstitial if one is ready and the cooldown has passed.
    /// `completion` always runs (right away if no ad is shown), so you can continue after it.
    public func showInterstitial(completion: (() -> Void)? = nil) {
        let cooledDown = lastInterstitialDate.map { Date().timeIntervalSince($0) >= interstitialCooldown } ?? true

        guard shouldShowAds, cooledDown, !isShowingFullScreen, let ad = interstitial else {
            completion?()
            loadInterstitial()
            return
        }
        onDismiss = completion
        lastInterstitialDate = Date()
        isShowingFullScreen = true
        ad.present(from: nil)
    }

    // MARK: Rewarded

    public func loadRewarded() {
        guard canRequestAds, rewarded == nil, let id = ids.rewarded else { return }
        Task {
            do {
                let ad = try await RewardedAd.load(with: id, request: Request())
                ad.fullScreenContentDelegate = self
                rewarded = ad
                isRewardedReady = true
            } catch {
                print("[AdKit] Rewarded failed: \(error.localizedDescription)")
            }
        }
    }

    /// Shows a rewarded ad. Users who removed ads get the reward right away.
    public func showRewarded(onReward: @escaping () -> Void, onUnavailable: (() -> Void)? = nil) {
        if adsRemoved { onReward(); return }

        guard canRequestAds, !isShowingFullScreen, let ad = rewarded else {
            onUnavailable?()
            loadRewarded()
            return
        }
        isShowingFullScreen = true
        ad.present(from: nil) {
            onReward()
        }
    }

    // MARK: App Open

    public func loadAppOpen() {
        guard shouldShowAds, appOpen == nil, let id = ids.appOpen else { return }
        Task {
            do {
                let ad = try await AppOpenAd.load(with: id, request: Request())
                ad.fullScreenContentDelegate = self
                appOpen = ad
                appOpenLoadDate = Date()
            } catch {
                print("[AdKit] App open failed: \(error.localizedDescription)")
            }
        }
    }

    /// Call when the app becomes active (scenePhase == .active).
    public func showAppOpenIfAvailable() {
        guard shouldShowAds, !isShowingFullScreen else { return }

        if let date = appOpenLoadDate, Date().timeIntervalSince(date) > appOpenExpiry {
            appOpen = nil
        }
        guard let ad = appOpen else {
            loadAppOpen()
            return
        }
        isShowingFullScreen = true
        ad.present(from: nil)
    }

    // MARK: Dismiss handling

    fileprivate enum Kind { case interstitial, rewarded, appOpen, other }

    fileprivate func handleClosed(_ kind: Kind) {
        isShowingFullScreen = false
        switch kind {
        case .interstitial:
            interstitial = nil
            isInterstitialReady = false
            loadInterstitial()
        case .rewarded:
            rewarded = nil
            isRewardedReady = false
            loadRewarded()
        case .appOpen:
            appOpen = nil
            loadAppOpen()
        case .other:
            break
        }
        let completion = onDismiss
        onDismiss = nil
        completion?()
    }
}

// MARK: - FullScreenContentDelegate

extension AdManager: FullScreenContentDelegate {

    nonisolated private static func kind(of ad: FullScreenPresentingAd) -> Kind {
        switch ad {
        case is InterstitialAd: return .interstitial
        case is RewardedAd:     return .rewarded
        case is AppOpenAd:      return .appOpen
        default:                return .other
        }
    }

    nonisolated public func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        let kind = Self.kind(of: ad)
        Task { @MainActor in self.handleClosed(kind) }
    }

    nonisolated public func ad(_ ad: FullScreenPresentingAd,
                               didFailToPresentFullScreenContentWithError error: Error) {
        let kind = Self.kind(of: ad)
        print("[AdKit] Failed to present: \(error.localizedDescription)")
        Task { @MainActor in self.handleClosed(kind) }
    }
}

// MARK: - Banner (SwiftUI)

/// Drop-in adaptive banner. Hides itself when ads are removed, consent isn't given,
/// or no banner ID is set.
public struct AdBanner: View {
    @ObservedObject private var ads = AdManager.shared
    @State private var width: CGFloat = 320

    public init() {}

    public var body: some View {
        if ads.shouldShowAds, let id = ads.ids.banner {
            let adSize = currentOrientationAnchoredAdaptiveBanner(width: width)
            BannerAdView(adUnitID: id, adSize: adSize)
                .frame(width: adSize.size.width, height: adSize.size.height)
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { width = geo.size.width }
                            .onChange(of: geo.size.width) { newWidth in width = newWidth }
                    }
                )
        }
    }
}

private struct BannerAdView: UIViewRepresentable {
    let adUnitID: String
    let adSize: AdSize

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: adSize)
        banner.adUnitID = adUnitID
        banner.load(Request())
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {
        if banner.adSize.size != adSize.size {
            banner.adSize = adSize
            banner.load(Request())
        }
    }
}
