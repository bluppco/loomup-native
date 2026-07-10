# Litebase Kotlin SDK

Kotlin client for [Litebase Realtime](../../README.md) — auth, REST CRUD, and WebSocket subscriptions.

Requires **JVM 11+** (usable from Android apps and JVM tools). Built with coroutines, kotlinx.serialization, and OkHttp.

## Install

### Local path (monorepo)

```kotlin
// settings.gradle.kts
includeBuild("../path/to/base/sdk/kotlin") // or publishToMavenLocal

// build.gradle.kts
dependencies {
    implementation("com.litebase:client:0.1.0")
}
```

Publish locally from this directory:

```bash
./gradlew publishToMavenLocal
```

### Maven (after publish)

```kotlin
dependencies {
    implementation("com.litebase:client:0.1.0")
}
```

## Quick start

```kotlin
import com.litebase.client.createClient
import com.litebase.client.JsonValue
import com.litebase.client.WhereValue

val client = createClient(url = "http://127.0.0.1:3000")

val tokens = client.auth.signUp(email = "a@b.com", password = "secret12")

val list = client.from("todos").select(
    where = mapOf("completed" to WhereValue.Bool(false)),
    limit = 20,
)

val unsub = client.from("todos").subscribeReady { event ->
    println("${event.op} ${event.data}")
}
// Prefer subscribeReady when the next line mutates data.
unsub()
client.closeRealtime()
```

## Tokens

- `setToken(...)` re-authenticates an open WebSocket and re-sends all active subscriptions.
- Automatic 401 retry uses `refreshToken` when set.
- RESYNC catch-up events use Unix **seconds** for `ts`.

## Realtime reconnect

On unexpected close the SDK reconnects with **exponential backoff + full jitter** (base 1s, cap 30s), re-subscribes, then **refetches current authorized state** as `op: "RESYNC"` events. Set primary keys for custom PK tables:

```kotlin
client.setTablePrimaryKey("keys", "slug")
```

Subscribe callbacks may run on background threads (OkHttp). Hop to the main/UI thread if updating UI.

## Testing / injectables

REST uses `HttpTransport` (default OkHttp). Realtime uses `WebSocketFactory` (default OkHttp WebSocket). Inject fakes in unit tests — same role as TypeScript’s `WebSocketImpl` and Swift’s transports.

```bash
cd sdk/kotlin && ./gradlew test
```

## API surface

| Area | Methods |
|------|---------|
| Auth | `signUp` / `register`, `signIn` / `login`, `signOut` / `logout`, `me`, `refresh` |
| CRUD | `from(table).select/get/insert/update/delete` |
| Realtime | `subscribe`, `subscribeReady`, `onControl`, `closeRealtime` |

Row payloads use `JsonValue` (dynamic tables; Kotlin codegen is a future enhancement).
