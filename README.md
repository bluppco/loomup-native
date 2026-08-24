# Loomup native SDKs

Native client packages for Loomup, preserved in a repository separate from the
server and JavaScript SDK repositories.

- `Package.swift` / `swift/` — Swift Package Manager products `Loomup` and
  `LoomupAppIntegrity` (iOS 16+).
- `kotlin/` — Kotlin/JVM core plus the Android integrity integration.
- `flutter/` — Dart/Flutter client retained for a later integrity rollout.
- `conformance/` — language-neutral client fixtures.

These packages are source-available and continuously tested, but this
repository intentionally has no package-publishing, signing, or deployment
workflow. Releasing requires a separate decision and platform-specific tag
(`swift-v*`, `kotlin-v*`, or `dart-v*`).

Mobile applications must never embed a Loomup service key. User access tokens
remain the authorization principal; app integrity is an additional anti-abuse
signal for projects that opt into it.

## Swift Package Manager

Until a release is intentionally tagged, add this repository as a local Swift
package (or pin a Git revision) and link both products:

```swift
dependencies: [
    .package(path: "../loomup-native")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Loomup", package: "loomup-native"),
            .product(name: "LoomupAppIntegrity", package: "loomup-native"),
        ]
    )
]
```

For an iOS 16+ App Store or TestFlight app, construct the client with the
manifest app identifier, not a backend credential:

```swift
import Loomup
import LoomupAppIntegrity

let loomup = createMobileClient(
    url: URL(string: "https://api.example.com")!,
    appID: "ios_main"
)
```

`createMobileClient` uses App Attest for each mutation, stores only the refresh
token in a `ThisDeviceOnly` Keychain item, and keeps the access token in memory.
The `appID` must match an `[app_integrity.apps.<id>]` entry on the server. Keep
the core `createClient` factory for macOS/server-side tools and tests; it also
has no service-key input.

For Google, Apple, or GitHub sign-in, use the system authentication session
helper. It keeps the one-use verifier in memory and exchanges the deep-link code
through the same integrity-protected client:

```swift
let tokens = try await signInWithOAuth(
    client: loomup,
    provider: .google,
    redirectTo: URL(string: "com.example.app:/auth/callback")!,
    presentationContextProvider: windowProvider
)
```

## Android

The `kotlin/` build contains the JVM core and `:android` library. Android apps
use `createAndroidClient(context, url, appId, cloudProjectNumber)`. It requests
standard Play Integrity tokens bound to the exact mutation and stores only the
refresh token using a non-exportable Android Keystore key. The project number
and `appId` are identifiers, not secrets.

The repository CI builds and tests these packages but intentionally does not
publish Maven, Swift, Dart, CocoaPods, or other artifacts.

Android exposes `signInWithOAuth(client, provider, redirectTo, launcher)` in
the Android library; the app supplies its Custom Tab/deep-link launcher. Flutter
exposes the same authorize/exchange flow with an injected URL launcher so no
browser plugin is forced on applications.
