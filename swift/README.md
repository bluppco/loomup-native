# Loomup Swift SDK

Swift client for [Loomup Realtime](../../README.md) — auth, REST CRUD, and WebSocket subscriptions.

Requires **Swift 5.9+** and **iOS 16 / macOS 12** (or later).

## Install (Swift Package Manager)

Use the repository's semantic-versioned Git release:

```swift
dependencies: [
    .package(
        url: "https://github.com/bluppco/loomup-native.git",
        from: "0.1.6"
    )
]
```

The repository root is the published Swift Package Manager package. It exposes
the `Loomup` and `LoomupAppIntegrity` products. Use an exact `0.1.6` requirement
when automatic patch updates are not desired.

### Local path

In your app’s `Package.swift`:

```swift
dependencies: [
    .package(path: "../loomup-native"),
]
```

Or in Xcode: **File → Add Package Dependencies…** → **Add Local…** →
select the `loomup-native` repository root.

## Quick start

```swift
import Loomup

let client = createClient(url: URL(string: "http://127.0.0.1:3000")!)

let tokens = try await client.auth.signUp(email: "a@b.com", password: "secret12")

let list = try await client.from("todos").select(
    where: ["completed": false],
    limit: 20
)

let unsub = try await client.from("todos").subscribeReady { event in
    print(event.op, event.data as Any)
}
// Prefer subscribeReady when the next line mutates data.
unsub()
client.closeRealtime()
```

## Offline SQLite

```swift
let storage = try SQLiteSyncStorage(url: localDatabaseURL)
let offline = try await client.offline(resources: ["todos"], storage: storage)

try await offline.create("todos", data: ["title": "Queued locally"])
for await status in await offline.statusStream() {
    print(status.phase, status.pending)
}
```

The SDK owns its small internal SQLite state table, mutation queue, cursors, reset recovery, and realtime invalidation. Your app does not write SQL or run a migration. Use `MemorySyncStorage` in tests and call `await offline.close()` when finished.

## Tokens

- `setToken(_:)` re-authenticates an open WebSocket and re-sends all active subscriptions.
- Automatic 401 retry uses `refreshToken` when set.
- Refresh failures retain their own status and code, so transient outages are not reported as sign-out.
- RESYNC catch-up events use Unix **seconds** for `ts`.

Hosted cookie-mode projects can bridge HttpOnly token responses into the native
JSON envelope with response-cookie precedence:

```swift
let client = createClient(
    url: hostedProjectURL,
    refreshTokenStore: refreshTokenStore,
    http: CookieAuthHTTPTransport()
)
```

## Realtime reconnect

On unexpected close the SDK reconnects with **exponential backoff + full jitter** (base 1s, cap 30s), re-subscribes, then **refetches current authorized state** as `op: "RESYNC"` events. Set primary keys for custom PK tables:

```swift
client.setTablePrimaryKey(table: "keys", pk: "slug")
```

On iOS and tvOS the client also observes the app becoming active and replaces
the possibly stale socket immediately without dropping subscriptions. Other
hosts can call `resumeRealtime()` from their foreground lifecycle callback.

While a socket is open and at least one subscription is active, the client
sends an application heartbeat through the normal WebSocket text path:

```json
{"type":"ping","requestId":"hb_<unique-id>","sentAt":1787814926000}
```

Only a `pong` with the same `requestId` acknowledges that probe. If it does not
arrive within the response timeout, the client retires the old socket even when
it still reports `OPEN`, reconnects with the existing jitter policy, restores
authentication and subscriptions, and refetches current authorized state.
WebSocket protocol Ping/Pong remains enabled independently.

The defaults are a 25-second interval and 12-second response timeout. Tests or
deployments with different proxy limits can override them without changing the
rest of the public API:

```swift
let client = createClient(
    url: URL(string: "https://api.example.com")!,
    realtimeHeartbeat: RealtimeHeartbeatOptions(
        intervalMs: 20_000,
        responseTimeoutMs: 10_000
    )
)
```

## Testing

```bash
cd sdk/swift && swift test
```

## API surface

| Area | Methods |
|------|---------|
| Auth | `signUp` / `register`, `signIn` / `login`, `signOut` / `logout`, `me`, `refresh` |
| CRUD | `from(table).select/get/insert/update/delete` |
| Realtime | `subscribe`, `subscribeReady`, `onControl`, `resumeRealtime`, `closeRealtime` |
| Offline | `offline`, `find/get/create/update/remove`, `statusStream`, `sync`, `setOnline` |

Row payloads use `JSONValue` (dynamic tables; Swift codegen is a future enhancement).
