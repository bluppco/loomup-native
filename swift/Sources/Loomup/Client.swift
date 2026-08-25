import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Options for constructing a client.
public struct LoomupClientOptions: Sendable {
    public var url: URL
    public var token: String?
    public var refreshToken: String?
    /// Legacy non-authorizing project identifier. This is not a secret and is
    /// never a substitute for user authentication or app integrity.
    public var publishableKey: String?
    public var appIntegrityProvider: (any AppIntegrityProvider)?
    public var refreshTokenStore: (any RefreshTokenStore)?
    public var http: HTTPTransport
    public var webSocketFactory: WebSocketFactory?

    public init(
        url: URL,
        token: String? = nil,
        refreshToken: String? = nil,
        publishableKey: String? = nil,
        appIntegrityProvider: (any AppIntegrityProvider)? = nil,
        refreshTokenStore: (any RefreshTokenStore)? = nil,
        http: HTTPTransport = URLSessionHTTPTransport(),
        webSocketFactory: WebSocketFactory? = nil
    ) {
        self.url = url
        self.token = token
        self.refreshToken = refreshToken
        self.publishableKey = publishableKey
        self.appIntegrityProvider = appIntegrityProvider
        self.refreshTokenStore = refreshTokenStore
        self.http = http
        self.webSocketFactory = webSocketFactory
    }
}

/// Create a Loomup client (TypeScript `createClient` equivalent).
public func createClient(
    url: URL,
    token: String? = nil,
    refreshToken: String? = nil,
    publishableKey: String? = nil,
    appIntegrityProvider: (any AppIntegrityProvider)? = nil,
    refreshTokenStore: (any RefreshTokenStore)? = nil,
    http: HTTPTransport = URLSessionHTTPTransport(),
    webSocketFactory: WebSocketFactory? = nil
) -> LoomupClient {
    LoomupClient(
        options: LoomupClientOptions(
            url: url,
            token: token,
            refreshToken: refreshToken,
            publishableKey: publishableKey,
            appIntegrityProvider: appIntegrityProvider,
            refreshTokenStore: refreshTokenStore,
            http: http,
            webSocketFactory: webSocketFactory
        )
    )
}

/// Loomup Realtime client: REST + WebSocket subscriptions.
public final class LoomupClient: @unchecked Sendable {
    public let url: URL

    private let http: HTTPTransport
    private let webSocketFactory: WebSocketFactory
    private let lock = NSLock()

    private var token: String?
    private var refreshToken: String?
    private let publishableKey: String?
    private let appIntegrityProvider: (any AppIntegrityProvider)?
    private let refreshTokenStore: (any RefreshTokenStore)?

    // Realtime state
    private var ws: WebSocketConnecting?
    private var subs: [String: [UUID: SubscribeHandler]] = [:]
    private var controlHandlers: [UUID: ControlHandler] = [:]
    private var pendingSubscribeAcks: [String: PendingAck] = [:]
    private var reconnectWorkItem: DispatchWorkItem?
    private var intentionalClose = false
    private var hasOpenedOnce = false
    private var reconnectAttempt = 0
    private var tablePrimaryKeys: [String: String] = [:]
    private var refreshingTask: Task<AuthTokens, Error>?

    #if canImport(UIKit)
    private var foregroundObserver: NSObjectProtocol?
    #endif

    private struct PendingAck {
        let continuation: CheckedContinuation<Void, Error>
        let workItem: DispatchWorkItem
    }

    public init(options: LoomupClientOptions) {
        var base = options.url
        if base.absoluteString.hasSuffix("/") {
            let s = String(base.absoluteString.dropLast())
            base = URL(string: s) ?? options.url
        }
        self.url = base
        self.token = options.token
        self.refreshToken = options.refreshToken ?? (try? options.refreshTokenStore?.loadRefreshToken())
        self.publishableKey = options.publishableKey
        self.appIntegrityProvider = options.appIntegrityProvider
        self.refreshTokenStore = options.refreshTokenStore
        self.http = options.http
        self.webSocketFactory = options.webSocketFactory ?? {
            URLSessionWebSocketConnection()
        }

        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resumeRealtime()
        }
        #endif
    }

    deinit {
        #if canImport(UIKit)
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        #endif
    }

    public convenience init(
        url: URL,
        token: String? = nil,
        refreshToken: String? = nil,
        publishableKey: String? = nil,
        appIntegrityProvider: (any AppIntegrityProvider)? = nil,
        refreshTokenStore: (any RefreshTokenStore)? = nil,
        http: HTTPTransport = URLSessionHTTPTransport(),
        webSocketFactory: WebSocketFactory? = nil
    ) {
        self.init(
            options: LoomupClientOptions(
                url: url,
                token: token,
                refreshToken: refreshToken,
                publishableKey: publishableKey,
                appIntegrityProvider: appIntegrityProvider,
                refreshTokenStore: refreshTokenStore,
                http: http,
                webSocketFactory: webSocketFactory
            )
        )
    }

    // MARK: - Tokens

    public var accessToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func setToken(_ token: String?) {
        lock.lock()
        self.token = token
        lock.unlock()
        reauthAndResubscribe()
    }

    public func setRefreshToken(_ token: String?) {
        lock.lock()
        self.refreshToken = token
        lock.unlock()
        try? refreshTokenStore?.saveRefreshToken(token)
    }

    public func setTablePrimaryKey(table: String, pk: String) {
        lock.lock()
        tablePrimaryKeys[table] = pk
        lock.unlock()
    }

    public var reconnectEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !intentionalClose
    }

    // MARK: - Auth surface

    public var auth: AuthAPI { AuthAPI(client: self) }
    public var push: PushAPI { PushAPI(client: self) }
    public var storage: StorageAPI { StorageAPI(client: self) }

    /// Object storage (`/storage/v1`).
    public struct StorageAPI: Sendable {
        fileprivate weak var client: LoomupClient?

        public func listBuckets() async throws -> [StorageBucketInfo] {
            try await client!.listStorageBuckets()
        }

        public func from(_ bucket: String) -> StorageBucket {
            StorageBucket(client: client!, bucket: bucket)
        }
    }

    public final class StorageBucket: @unchecked Sendable {
        private weak var client: LoomupClient?
        public let bucket: String

        init(client: LoomupClient, bucket: String) {
            self.client = client
            self.bucket = bucket
        }

        private func objectPath(_ path: String) -> String {
            let encoded = path
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { segment in
                    segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
                }
                .joined(separator: "/")
            let b = bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bucket
            return "/storage/v1/\(b)/object/\(encoded)"
        }

        public func upload(
            path: String,
            data: Data,
            contentType: String? = "application/octet-stream",
            upsert: Bool = false
        ) async throws -> StorageObject {
            var headers: [String: String] = [:]
            if let contentType { headers["Content-Type"] = contentType }
            if upsert { headers["x-loomup-upsert"] = "true" }
            let env: DataEnvelope<StorageObject> = try await client!.requestJSON(
                method: "POST",
                path: objectPath(path),
                body: data,
                contentType: contentType,
                extraHeaders: headers,
                skipRetry: false
            )
            return env.data
        }

        public func download(path: String) async throws -> Data {
            try await client!.request(
                method: "GET",
                path: objectPath(path),
                body: nil,
                contentType: nil,
                extraHeaders: ["Accept": "*/*"],
                skipRetry: false
            )
        }

        public func list(prefix: String? = nil, limit: Int = 100, offset: Int = 0) async throws -> (data: [StorageObject], meta: ListMeta) {
            let b = bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bucket
            var q = "limit=\(limit)&offset=\(offset)"
            if let prefix,
               let enc = prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            {
                q += "&prefix=\(enc)"
            }
            struct Env: Decodable {
                let data: [StorageObject]
                let meta: ListMeta
            }
            let env: Env = try await client!.requestJSON(method: "GET", path: "/storage/v1/\(b)?\(q)")
            return (env.data, env.meta)
        }

        public func remove(path: String) async throws -> StorageObject {
            let env: DataEnvelope<StorageObject> = try await client!.requestJSON(
                method: "DELETE",
                path: objectPath(path)
            )
            return env.data
        }
    }

    public func listStorageBuckets() async throws -> [StorageBucketInfo] {
        let env: DataEnvelope<[StorageBucketInfo]> = try await requestJSON(
            method: "GET",
            path: "/storage/v1/buckets"
        )
        return env.data
    }

    public struct AuthAPI: Sendable {
        fileprivate weak var client: LoomupClient?

        public func signUp(email: String, password: String) async throws -> AuthTokens {
            try await client!.signUp(email: email, password: password)
        }

        public func register(email: String, password: String) async throws -> AuthTokens {
            try await signUp(email: email, password: password)
        }

        public func signIn(email: String, password: String) async throws -> AuthTokens {
            try await client!.signIn(email: email, password: password)
        }

        public func login(email: String, password: String) async throws -> AuthTokens {
            try await signIn(email: email, password: password)
        }

        public func oauthProviders() async throws -> [OAuthProviderInfo] {
            try await client!.oauthProviders()
        }

        public func authorizeOAuth(
            provider: OAuthProvider,
            redirectTo: String
        ) async throws -> OAuthAuthorization {
            try await client!.authorizeOAuth(provider: provider, redirectTo: redirectTo)
        }

        public func exchangeOAuthCode(
            code: String,
            codeVerifier: String
        ) async throws -> AuthTokens {
            try await client!.exchangeOAuthCode(code: code, codeVerifier: codeVerifier)
        }

        public func signOut() async {
            await client!.signOut()
        }

        public func logout() async {
            await signOut()
        }

        public func me() async throws -> User {
            try await client!.me()
        }

        public func refresh() async throws -> AuthTokens {
            try await client!.refresh()
        }
    }

    public struct PushAPI: Sendable {
        fileprivate weak var client: LoomupClient?

        public func registerDevice(
            token: String,
            provider: String,
            platform: String? = nil,
            deviceId: String? = nil,
            appVersion: String? = nil,
            locale: String? = nil
        ) async throws -> PushDevice {
            try await client!.registerPushDevice(
                token: token,
                provider: provider,
                platform: platform,
                deviceId: deviceId,
                appVersion: appVersion,
                locale: locale
            )
        }

        public func listDevices() async throws -> [PushDevice] {
            try await client!.listPushDevices()
        }

        public func unregisterDevice(id: String? = nil, token: String? = nil) async throws {
            try await client!.unregisterPushDevice(id: id, token: token)
        }
    }

    public func from(_ table: String) -> TableQuery {
        TableQuery(client: self, table: table)
    }

    // MARK: - Control handlers

    @discardableResult
    public func onControl(_ handler: @escaping ControlHandler) -> Unsubscribe {
        let id = UUID()
        lock.lock()
        controlHandlers[id] = handler
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.controlHandlers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    // MARK: - HTTP

    public func request(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String? = "application/json",
        extraHeaders: [String: String] = [:],
        skipRetry: Bool = false
    ) async throws -> Data {
        try await request(
            method: method,
            path: path,
            body: body,
            contentType: contentType,
            extraHeaders: extraHeaders,
            skipRetry: skipRetry,
            skipIntegrityRetry: false
        )
    }

    private func request(
        method: String,
        path: String,
        body: Data?,
        contentType: String?,
        extraHeaders: [String: String],
        skipRetry: Bool,
        skipIntegrityRetry: Bool
    ) async throws -> Data {
        let requestURL = joinURL(base: url, path: path)
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        if extraHeaders["Accept"] == nil {
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (access, refresh) = lock.withLock { (token, refreshToken) }
        if let access {
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        if let publishableKey {
            req.setValue(publishableKey, forHTTPHeaderField: "X-Loomup-Key")
        }
        if let body {
            if let contentType {
                req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            req.httpBody = body
        }
        if isIntegrityProtected(method: method, path: path), let appIntegrityProvider {
            let grant = try await appIntegrityProvider.prepareGrant(
                for: AppIntegrityRequest(
                    method: method,
                    pathAndQuery: requestTarget(forPath: path),
                    body: body ?? Data(),
                    authorizationToken: access
                )
            )
            req.setValue(grant, forHTTPHeaderField: "X-Loomup-App-Grant")
        }

        let (data, response) = try await http.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 403,
           !skipIntegrityRetry,
           appIntegrityProvider != nil,
           let error = try? JSONDecoder().decode(ErrorBody.self, from: data),
           error.error?.code == "app_integrity_required"
        {
            return try await request(
                method: method,
                path: path,
                body: body,
                contentType: contentType,
                extraHeaders: extraHeaders,
                skipRetry: skipRetry,
                skipIntegrityRetry: true
            )
        }

        if status == 401,
           !skipRetry,
           refresh != nil,
           path != "/auth/refresh",
           path != "/auth/login",
           path != "/auth/register"
        {
            do {
                _ = try await self.refresh()
                return try await request(
                    method: method,
                    path: path,
                    body: body,
                    contentType: contentType,
                    extraHeaders: extraHeaders,
                    skipRetry: true,
                    skipIntegrityRetry: skipIntegrityRetry
                )
            } catch {
                // fall through with original error
            }
        }

        if !(200..<300).contains(status) {
            throw parseError(data: data, status: status)
        }
        return data
    }

    private func isIntegrityProtected(method: String, path: String) -> Bool {
        guard ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased()) else {
            return false
        }
        return path != "/app-integrity/v1/challenge"
            && path != "/app-integrity/v1/verify"
    }

    public func requestJSON<T: Decodable>(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String? = "application/json",
        extraHeaders: [String: String] = [:],
        skipRetry: Bool = false
    ) async throws -> T {
        let data = try await request(
            method: method,
            path: path,
            body: body,
            contentType: contentType,
            extraHeaders: extraHeaders,
            skipRetry: skipRetry
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LoomupError("failed to decode response: \(error)", code: "decode_error", status: nil)
        }
    }

    private func parseError(data: Data, status: Int) -> LoomupError {
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            let msg = body.error?.message ?? body.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return LoomupError(msg, code: body.error?.code, status: status)
        }
        let text = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        return LoomupError(text, code: nil, status: status)
    }

    private func encodeJSON(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    // MARK: - Auth methods

    public func signUp(email: String, password: String) async throws -> AuthTokens {
        struct Creds: Encodable { let email: String; let password: String }
        let body = try encodeJSON(Creds(email: email, password: password))
        let env: DataEnvelope<AuthTokens> = try await requestJSON(
            method: "POST",
            path: "/auth/register",
            body: body,
            skipRetry: true
        )
        applyTokens(env.data)
        return env.data
    }

    public func signIn(email: String, password: String) async throws -> AuthTokens {
        struct Creds: Encodable { let email: String; let password: String }
        let body = try encodeJSON(Creds(email: email, password: password))
        let env: DataEnvelope<AuthTokens> = try await requestJSON(
            method: "POST",
            path: "/auth/login",
            body: body,
            skipRetry: true
        )
        applyTokens(env.data)
        return env.data
    }

    public func oauthProviders() async throws -> [OAuthProviderInfo] {
        let env: DataEnvelope<[OAuthProviderInfo]> = try await requestJSON(
            method: "GET",
            path: "/auth/oauth/providers"
        )
        return env.data
    }

    public func authorizeOAuth(
        provider: OAuthProvider,
        redirectTo: String
    ) async throws -> OAuthAuthorization {
        struct Body: Encodable {
            let provider: OAuthProvider
            let redirectTo: String
            enum CodingKeys: String, CodingKey {
                case provider
                case redirectTo = "redirect_to"
            }
        }
        let env: DataEnvelope<OAuthAuthorization> = try await requestJSON(
            method: "POST",
            path: "/auth/oauth/authorize",
            body: try encodeJSON(Body(provider: provider, redirectTo: redirectTo)),
            skipRetry: true
        )
        return env.data
    }

    public func exchangeOAuthCode(
        code: String,
        codeVerifier: String
    ) async throws -> AuthTokens {
        struct Body: Encodable {
            let code: String
            let codeVerifier: String
            enum CodingKeys: String, CodingKey {
                case code
                case codeVerifier = "code_verifier"
            }
        }
        let env: DataEnvelope<AuthTokens> = try await requestJSON(
            method: "POST",
            path: "/auth/oauth/exchange",
            body: try encodeJSON(Body(code: code, codeVerifier: codeVerifier)),
            skipRetry: true
        )
        applyTokens(env.data)
        return env.data
    }

    public func me() async throws -> User {
        let env: DataEnvelope<User> = try await requestJSON(method: "GET", path: "/auth/me")
        return env.data
    }

    // MARK: - Push devices

    public func registerPushDevice(
        token: String,
        provider: String,
        platform: String? = nil,
        deviceId: String? = nil,
        appVersion: String? = nil,
        locale: String? = nil
    ) async throws -> PushDevice {
        struct Body: Encodable {
            let token: String
            let provider: String
            let platform: String?
            let device_id: String?
            let app_version: String?
            let locale: String?
        }
        let body = try encodeJSON(
            Body(
                token: token,
                provider: provider,
                platform: platform,
                device_id: deviceId,
                app_version: appVersion,
                locale: locale
            )
        )
        let env: DataEnvelope<PushDevice> = try await requestJSON(
            method: "POST",
            path: "/push/devices",
            body: body
        )
        return env.data
    }

    public func listPushDevices() async throws -> [PushDevice] {
        let env: DataEnvelope<[PushDevice]> = try await requestJSON(
            method: "GET",
            path: "/push/devices"
        )
        return env.data
    }

    public func unregisterPushDevice(id: String? = nil, token: String? = nil) async throws {
        if let id, !id.isEmpty {
            _ = try await request(
                method: "DELETE",
                path: "/push/devices/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
            )
            return
        }
        if let token, !token.isEmpty {
            let q = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
            _ = try await request(method: "DELETE", path: "/push/devices?token=\(q)")
            return
        }
        throw LoomupError("id or token required to unregister device", code: "bad_request")
    }

    public func refresh() async throws -> AuthTokens {
        let task = try refreshTask()
        defer { clearRefreshTask() }
        return try await task.value
    }

    private func refreshTask() throws -> Task<AuthTokens, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let rt = refreshToken else {
            throw LoomupError("no refresh token", code: "no_refresh")
        }
        if let existing = refreshingTask {
            return existing
        }
        let task = Task<AuthTokens, Error> { [weak self] in
            guard let self else { throw LoomupError("client deallocated", code: "gone") }
            struct Body: Encodable { let refresh_token: String }
            let body = try self.encodeJSON(Body(refresh_token: rt))
            let env: DataEnvelope<AuthTokens> = try await self.requestJSON(
                method: "POST",
                path: "/auth/refresh",
                body: body,
                skipRetry: true
            )
            self.applyTokens(env.data)
            return env.data
        }
        refreshingTask = task
        return task
    }

    private func clearRefreshTask() {
        lock.withLock {
            refreshingTask = nil
        }
    }

    public func signOut() async {
        let rt = lock.withLock { refreshToken }
        if let rt {
            struct Body: Encodable { let refresh_token: String }
            if let body = try? encodeJSON(Body(refresh_token: rt)) {
                _ = try? await request(
                    method: "POST",
                    path: "/auth/logout",
                    body: body,
                    skipRetry: true
                )
            }
        }
        lock.withLock {
            token = nil
            refreshToken = nil
        }
        try? refreshTokenStore?.saveRefreshToken(nil)
        closeRealtime()
    }

    private func applyTokens(_ data: AuthTokens) {
        lock.lock()
        token = data.accessToken
        refreshToken = data.refreshToken
        lock.unlock()
        try? refreshTokenStore?.saveRefreshToken(data.refreshToken)
        reauthAndResubscribe()
    }

    // MARK: - Realtime core

    public func subscribeTable(
        table: String,
        rowId: String? = nil,
        handler: @escaping SubscribeHandler
    ) -> Unsubscribe {
        let key = makeSubKey(table: table, rowId: rowId)
        let handlerId = UUID()
        lock.lock()
        var map = subs[key] ?? [:]
        map[handlerId] = handler
        subs[key] = map
        lock.unlock()

        ensureWs()
        _ = sendSubscribe(table: table, rowId: rowId)

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.subs[key]?.removeValue(forKey: handlerId)
            let last = self.subs[key]?.isEmpty ?? true
            if last {
                self.subs.removeValue(forKey: key)
            }
            self.lock.unlock()
            if last {
                var msg: [String: Any] = [
                    "type": "unsubscribe",
                    "table": table,
                    "channel": table,
                ]
                if let rowId { msg["id"] = rowId }
                self.sendJSON(msg)
            }
        }
    }

    public func subscribeTableReady(
        table: String,
        rowId: String? = nil,
        timeoutMs: Int = 5000,
        handler: @escaping SubscribeHandler
    ) async throws -> Unsubscribe {
        let unsub = subscribeTable(table: table, rowId: rowId, handler: handler)
        do {
            try await whenConnected(timeoutMs: timeoutMs)
            // Register the waiter *before* sending so a fast server ack cannot be dropped.
            let requestId = makeRequestId(table: table)
            let ackTask = Task {
                try await self.waitForSubscribeAck(requestId: requestId, timeoutMs: timeoutMs)
            }
            // Yield so waitForSubscribeAck installs the pending entry before the frame goes out.
            await Task.yield()
            sendSubscribe(table: table, rowId: rowId, requestId: requestId)
            try await ackTask.value
            return unsub
        } catch {
            unsub()
            throw error
        }
    }

    public func whenConnected(timeoutMs: Int = 5000) async throws {
        ensureWs()
        if isWsOpen() { return }
        let start = Date()
        while true {
            if isWsOpen() { return }
            if Date().timeIntervalSince(start) * 1000 > Double(timeoutMs) {
                throw LoomupError("websocket connect timeout", code: "ws_timeout")
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Re-establish realtime after an app returns to the foreground.
    /// Active subscriptions are retained, re-subscribed, and resynchronized.
    public func resumeRealtime() {
        lock.lock()
        guard !subs.isEmpty else {
            lock.unlock()
            return
        }
        intentionalClose = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        let socket = ws
        ws = nil
        lock.unlock()

        socket?.onOpen = nil
        socket?.onMessage = nil
        socket?.onClose = nil
        socket?.close()
        ensureWs()
    }

    public func closeRealtime() {
        lock.lock()
        intentionalClose = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        let socket = ws
        ws = nil
        subs.removeAll()
        hasOpenedOnce = false
        let pending = pendingSubscribeAcks
        pendingSubscribeAcks.removeAll()
        lock.unlock()

        socket?.close()
        for (_, p) in pending {
            p.workItem.cancel()
            p.continuation.resume(throwing: LoomupError(
                "realtime closed before subscribe acknowledgement",
                code: "realtime_closed"
            ))
        }
    }

    // MARK: - Private realtime helpers

    private func isWsOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ws?.isOpen == true
    }

    private func ensureWs() {
        lock.lock()
        if let ws, ws.isConnectingOrOpen {
            lock.unlock()
            return
        }
        intentionalClose = false
        let factory = webSocketFactory
        lock.unlock()

        let socket = factory()
        lock.lock()
        ws = socket
        lock.unlock()

        socket.onOpen = { [weak self] in
            self?.handleOpen()
        }
        socket.onMessage = { [weak self] text in
            self?.handleMessage(text)
        }
        socket.onClose = { [weak self, weak socket] in
            guard let socket else { return }
            self?.handleClose(socket)
        }
        socket.connect(url: realtimeWebSocketURL(from: url))
    }

    private func handleOpen() {
        lock.lock()
        reconnectAttempt = 0
        let access = token
        let keys = Array(subs.keys)
        let isReconnect = hasOpenedOnce
        hasOpenedOnce = true
        let shouldResync = isReconnect && !keys.isEmpty
        lock.unlock()

        if let access {
            sendJSON(["type": "auth", "token": access])
        }
        for key in keys {
            let parsed = parseSubKey(key)
            _ = sendSubscribe(table: parsed.table, rowId: parsed.rowId)
        }
        if shouldResync {
            Task { [weak self] in
                await self?.resyncSubscriptions()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        if type == "change" {
            let table = obj["table"] as? String ?? ""
            let id = stringifyId(obj["id"])
            let op = obj["op"] as? String ?? ""
            let channel = obj["channel"] as? String
            let ts: Int64
            if let n = obj["ts"] as? NSNumber {
                ts = n.int64Value
            } else if let i = obj["ts"] as? Int64 {
                ts = i
            } else {
                ts = unixSecondsNow()
            }
            var rowData: [String: JSONValue]?
            if let d = obj["data"] {
                if let dict = d as? [String: Any] {
                    rowData = dict.mapValues { JSONValue.from($0) }
                }
            }
            let event = ChangeEvent(
                type: "change",
                channel: channel,
                table: table,
                op: op,
                id: id,
                data: rowData,
                ts: ts
            )
            lock.lock()
            let exact = subs[makeSubKey(table: table, rowId: id)] ?? [:]
            let all = subs[table] ?? [:]
            lock.unlock()
            for h in exact.values { h(event) }
            for h in all.values { h(event) }
            return
        }

        let control = ControlEvent(
            type: type,
            requestId: obj["requestId"] as? String,
            channel: obj["channel"] as? String,
            table: obj["table"] as? String,
            message: obj["message"] as? String,
            code: obj["code"] as? String,
            id: stringifyIdOptional(obj["id"])
        )

        if type == "subscribed" || type == "error" {
            resolveSubscribeAck(control)
        }

        lock.lock()
        let handlers = Array(controlHandlers.values)
        lock.unlock()
        for h in handlers { h(control) }
    }

    private func stringifyId(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let i = value as? Int { return String(i) }
        return String(describing: value)
    }

    private func stringifyIdOptional(_ value: Any?) -> String? {
        guard value != nil else { return nil }
        let s = stringifyId(value)
        return s.isEmpty ? nil : s
    }

    private func handleClose(_ socket: WebSocketConnecting) {
        lock.lock()
        guard ws === socket else {
            lock.unlock()
            return
        }
        ws = nil
        let shouldReconnect = !intentionalClose && !subs.isEmpty
        lock.unlock()
        if shouldReconnect {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        lock.lock()
        reconnectWorkItem?.cancel()
        let baseMs = 1000.0
        let capMs = 30_000.0
        let exp = min(capMs, baseMs * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        let delay = max(50.0, Double.random(in: 0...exp))
        let item = DispatchWorkItem { [weak self] in
            self?.ensureWs()
        }
        reconnectWorkItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay / 1000.0, execute: item)
    }

    private func reauthAndResubscribe() {
        lock.lock()
        guard let ws, ws.isOpen, !subs.isEmpty else {
            lock.unlock()
            return
        }
        let access = token
        let keys = Array(subs.keys)
        lock.unlock()

        if let access {
            sendJSON(["type": "auth", "token": access])
        }
        for key in keys {
            let parsed = parseSubKey(key)
            _ = sendSubscribe(table: parsed.table, rowId: parsed.rowId)
        }
    }

    @discardableResult
    private func sendSubscribe(
        table: String,
        rowId: String? = nil,
        requestId: String? = nil
    ) -> String {
        let rid = requestId ?? makeRequestId(table: table)
        lock.lock()
        let access = token
        lock.unlock()
        var msg: [String: Any] = [
            "type": "subscribe",
            "table": table,
            "channel": table,
            "requestId": rid,
        ]
        if let rowId { msg["id"] = rowId }
        if let access { msg["token"] = access }
        sendJSON(msg)
        return rid
    }

    private func sendJSON(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8)
        else { return }
        lock.lock()
        let socket = ws
        let open = socket?.isOpen == true
        lock.unlock()
        if open {
            socket?.send(text: text)
        }
    }

    private func waitForSubscribeAck(requestId: String, timeoutMs: Int) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.pendingSubscribeAcks.removeValue(forKey: requestId) != nil {
                    self.lock.unlock()
                    cont.resume(throwing: LoomupError(
                        "subscribe acknowledgement timeout",
                        code: "subscribe_timeout"
                    ))
                } else {
                    self.lock.unlock()
                }
            }
            lock.lock()
            pendingSubscribeAcks[requestId] = PendingAck(continuation: cont, workItem: work)
            lock.unlock()
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Double(timeoutMs) / 1000.0,
                execute: work
            )
        }
    }

    private func resolveSubscribeAck(_ data: ControlEvent) {
        guard let rid = data.requestId else { return }
        lock.lock()
        guard let pending = pendingSubscribeAcks.removeValue(forKey: rid) else {
            lock.unlock()
            return
        }
        lock.unlock()
        pending.workItem.cancel()
        if data.type == "subscribed" {
            pending.continuation.resume()
        } else if data.type == "error" {
            let msg = data.message ?? data.code ?? "subscribe failed"
            pending.continuation.resume(throwing: LoomupError(msg, code: data.code))
        }
    }

    private func resyncSubscriptions() async {
        let keys = lock.withLock { Array(subs.keys) }

        for key in keys {
            let (handlers, pkMap) = lock.withLock {
                (Array((subs[key] ?? [:]).values), tablePrimaryKeys)
            }
            guard !handlers.isEmpty else { continue }
            let parsed = parseSubKey(key)
            do {
                if let rowId = parsed.rowId {
                    let path = "/api/\(encodeURIComponent(parsed.table))/\(encodeURIComponent(rowId))"
                    let env: DataEnvelope<[String: JSONValue]> = try await requestJSON(
                        method: "GET",
                        path: path
                    )
                    let ts = unixSecondsNow()
                    let ev = ChangeEvent(
                        table: parsed.table,
                        op: "RESYNC",
                        id: rowId,
                        data: env.data,
                        ts: ts
                    )
                    for h in handlers { h(ev) }
                } else {
                    var offset = 0
                    let pageSize = 100
                    var total = Int.max
                    while offset < total {
                        let path =
                            "/api/\(encodeURIComponent(parsed.table))?limit=\(pageSize)&offset=\(offset)"
                        let env: ListEnvelope = try await requestJSON(method: "GET", path: path)
                        let rows = env.data
                        total = env.meta.total
                        let ts = unixSecondsNow()
                        let pk = pkMap[parsed.table] ?? "id"
                        for row in rows {
                            guard let raw = row[pk] else { continue }
                            let id: String
                            switch raw {
                            case .string(let s): id = s
                            case .number(let n):
                                if n.rounded() == n {
                                    id = String(Int64(n))
                                } else {
                                    id = String(n)
                                }
                            case .bool(let b): id = b ? "1" : "0"
                            default: continue
                            }
                            let ev = ChangeEvent(
                                table: parsed.table,
                                op: "RESYNC",
                                id: id,
                                data: row,
                                ts: ts
                            )
                            for h in handlers { h(ev) }
                        }
                        if rows.isEmpty { break }
                        offset += rows.count
                        if rows.count < pageSize { break }
                    }
                }
            } catch {
                // best-effort catch-up
            }
        }
    }
}
