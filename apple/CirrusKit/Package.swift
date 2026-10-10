// swift-tools-version: 6.2
// The platform-independent part of the native Apple app: Cloudflare API
// client, credentials and OAuth, settings, and the data behind the screens.
// Builds and tests on Linux too (`swift test`), so it is checked in CI
// without a Mac.
import PackageDescription

let package = Package(
    name: "CirrusKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "CirrusKit", targets: ["CirrusKit"])
    ],
    targets: [
        .target(
            name: "CirrusKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CirrusKitTests",
            dependencies: ["CirrusKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
