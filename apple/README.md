# Cirrus for iOS and macOS (native)

The iOS and macOS app written in Swift and SwiftUI, with the system's
Liquid Glass. It talks to the same Cloudflare API as the Flutter app and
reads the Flutter app's credentials and settings on first launch (it is the
same App Store app, `io.felixbennett.cirrus`).

- `CirrusKit/` — a Swift package with everything that is not UI: the
  Cloudflare API client, credentials (Keychain), Cloudflare OAuth with PKCE,
  settings, and the models behind the screens. It builds and tests on Linux
  too: `swift test --package-path apple/CirrusKit`.
- `Cirrus/` — the SwiftUI app (`App/` state and navigation, `Features/` one
  folder per area, `Support/` shared views, `Resources/` the asset catalog).
- `Support/` — `Info.plist` additions and the macOS entitlements.
- `project.yml` — the Xcode project, generated with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen): `xcodegen generate` in
  this directory, then open `Cirrus.xcodeproj`. Targets `Cirrus-iOS` and
  `Cirrus-macOS`, iOS 26 and macOS 26.

## Builds

`.forgejo/workflows/apple.yml` runs the CirrusKit tests on every push that
touches `apple/`. Run it from the Actions tab to archive the app on the
macOS runner and upload it to App Store Connect (TestFlight); it needs the
App Store Connect secrets listed at the top of the workflow.

The build setting `CIRRUS_STORE` (`appstore` by default) decides whether
Cirrus Pro is sold through StoreKit; any other value builds a fully unlocked
app.

## Status

The first stage covers sign-in (Cloudflare OAuth, API tokens, Global API
Key), accounts and zones, the home screen, domains, zone overview, DNS
(including BIND import/export, DNSSEC and DNS settings), SSL/TLS (Origin CA
keys are generated on the device), caching, zone settings, analytics,
settings, app lock and Cirrus Pro. The other areas of the Flutter app follow.
