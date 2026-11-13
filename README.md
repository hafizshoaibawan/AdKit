# AdKit

Shared AdMob + Firebase setup for my iOS apps. Adding this one package brings in:

- Google Mobile Ads (AdMob)
- User Messaging Platform (GDPR consent form)
- Firebase Core, Analytics and Crashlytics
- `AdManager`: banner, interstitial, rewarded and app open ads, consent, tracking permission and "remove ads" support

Requires iOS 16+.

---

## Setup steps (for Claude in Xcode, or by hand)

Do every step in the app that is currently open. Keep all existing code and styling.

### 1. Add the package
Add this package to the app target: `https://github.com/hafizshoaibawan/AdKit`, product **AdKit**.
(Manual: File > Add Package Dependencies > paste the URL.)

### 2. Info.plist
Add these keys:
- `GADApplicationIdentifier` = `ca-app-pub-3940256099942544~1458002511`
  (Google's test App ID. Replace it with the real AdMob App ID before release.)
- `NSUserTrackingUsageDescription` = `This lets us show you more relevant ads and keep the app free.`
- `SKAdNetworkItems`: an array of dictionaries, each with a `SKAdNetworkIdentifier` string. At minimum add `cstr6suwn9.skadnetwork`, plus the rest of the list in Google's AdMob iOS "Update your Info.plist" guide.

### 3. App entry point
In the `@main` App struct:

```swift
import SwiftUI
import AdKit

@main
struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AdManager.shared.configure(
            banner: "YOUR_BANNER_ID",
            interstitial: "YOUR_INTERSTITIAL_ID",
            rewarded: "YOUR_REWARDED_ID",
            appOpen: "YOUR_APP_OPEN_ID"   // or nil to turn app open ads off
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await AdManager.shared.start() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { AdManager.shared.showAppOpenIfAvailable() }
        }
    }
}
```

`configure()` also starts Firebase if `GoogleService-Info.plist` is in the app.
Debug builds always use Google's test ad IDs, so it's safe to tap ads while testing.

### 4. Show ads
- **Banner:** add `AdBanner()` at the bottom of the main screen, e.g. `.safeAreaInset(edge: .bottom) { AdBanner() }`.
- **Interstitial:** call `AdManager.shared.showInterstitial()` at one natural "task finished" moment (after saving, after a result, when closing a detail screen). Not on launch and not mid-task.
- **Rewarded:** gate premium actions (export, unlock, remove watermark):
  ```swift
  AdManager.shared.showRewarded {
      unlockFeature()
  } onUnavailable: {
      // show "Ad not ready, try again"
  }
  ```
- **Remove ads purchase:** set `AdManager.shared.adsRemoved = true`.
- **Privacy options (EU):** in Settings, if `AdManager.shared.isPrivacyOptionsRequired`, show a button that calls `await AdManager.shared.presentPrivacyOptions()`.

### 5. Build
Build the project and fix any errors.

---

## Still to do by hand for each app
1. Create the app in the Firebase console, download `GoogleService-Info.plist` and drag it into the project.
2. Create the app and ad units in AdMob, then put the real IDs in `configure(...)` and the real App ID in Info.plist.
3. Optional: add Crashlytics' dSYM upload run script (see Firebase Crashlytics docs).

## Updating
After changing this repo, push a new tag (e.g. `1.0.1`). In each app: File > Packages > Update to Latest Package Versions.
