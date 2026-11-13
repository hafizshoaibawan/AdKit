// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AdKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AdKit", targets: ["AdKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/googleads/swift-package-manager-google-mobile-ads", from: "12.0.0"),
        .package(url: "https://github.com/googleads/swift-package-manager-google-user-messaging-platform", from: "3.0.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.0.0"),
    ],
    targets: [
        .target(
            name: "AdKit",
            dependencies: [
                .product(name: "GoogleMobileAds", package: "swift-package-manager-google-mobile-ads"),
                .product(name: "UserMessagingPlatform", package: "swift-package-manager-google-user-messaging-platform"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
            ]
        )
    ]
)
