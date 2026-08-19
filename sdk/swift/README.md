# Loomup Swift SDK

Swift client for [Loomup Realtime](../../README.md) — auth, REST CRUD, and WebSocket subscriptions.

Requires **Swift 5.7+** and **iOS 15 / macOS 12** (or later).

## Install (Swift Package Manager)

### Local path (monorepo)

In your app’s `Package.swift`:

```swift
dependencies: [
    .package(path: "../path/to/base/sdk/swift"),
]
```

Or in Xcode: **File → Add Package Dependencies…** → **Add Local…** → select `sdk/swift`.

Published Swift package coordinates will be listed at [tryloomup.com/docs](https://tryloomup.com/docs). For monorepo layouts, the package lives at `sdk/swift` (this directory is the SPM root).

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
- RESYNC catch-up events use Unix **seconds** for `ts`.

## Realtime reconnect

On unexpected close the SDK reconnects with **exponential backoff + full jitter** (base 1s, cap 30s), re-subscribes, then **refetches current authorized state** as `op: "RESYNC"` events. Set primary keys for custom PK tables:

```swift
client.setTablePrimaryKey(table: "keys", pk: "slug")
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
| Realtime | `subscribe`, `subscribeReady`, `onControl`, `closeRealtime` |
| Offline | `offline`, `find/get/create/update/remove`, `statusStream`, `sync`, `setOnline` |

Row payloads use `JSONValue` (dynamic tables; Swift codegen is a future enhancement).
