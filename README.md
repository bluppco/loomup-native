# Loomup native SDKs

Native client packages for Loomup, preserved in a repository separate from the
server and JavaScript SDK repositories.

- `Package.swift` / `swift/` — Swift Package Manager products `Loomup` and
  `LoomupAppIntegrity` (iOS 16+).
- `kotlin/` — Kotlin/JVM core plus the Android integrity integration.
- `flutter/` — Dart/Flutter client retained for a later integrity rollout.
- `conformance/` — language-neutral client fixtures.

These packages are source-available and continuously tested. Swift is released
from the root package through semantic-version Git tags; the current release is
`0.1.3`. The release workflow verifies tagged Swift source but does not publish
to Swift Package Index or a Swift package-registry server. Kotlin and Dart do
not yet have Maven Central or pub.dev releases.

Mobile applications must never embed a Loomup service key. User access tokens
remain the authorization principal; app integrity is an additional anti-abuse
signal for projects that opt into it.

## Swift Package Manager

Add the released package from its Git URL and link both products:

```swift
dependencies: [
    .package(
        url: "https://github.com/bluppco/loomup-native.git",
        from: "0.1.3"
    )
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

Use an exact `0.1.3` requirement when automatic patch updates are not desired.
For local development, replace the URL dependency with
`.package(path: "../loomup-native")`.

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

The repository CI builds and tests all native packages. Swift releases use Git
tags consumable by Swift Package Manager; they are not separately listed or
uploaded to Swift Package Index, a Swift package-registry server, or CocoaPods.
Kotlin and Dart are not published to Maven Central or pub.dev.

Android exposes `signInWithOAuth(client, provider, redirectTo, launcher)` in
the Android library; the app supplies its Custom Tab/deep-link launcher. Flutter
exposes the same authorize/exchange flow with an injected URL launcher so no
browser plugin is forced on applications.

Swift and Android mobile constructors reconnect realtime automatically when
the app returns to the foreground. Flutter apps call `resumeRealtime()` from
their `AppLifecycleState.resumed` handler so active subscriptions are preserved,
re-subscribed, and resynchronized after a background suspension.
