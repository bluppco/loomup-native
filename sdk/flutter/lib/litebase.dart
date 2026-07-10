/// Litebase Dart client — auth, REST CRUD, and WebSocket subscriptions.
///
/// Works with Flutter and pure Dart (no Flutter framework dependency).
library;

export 'src/client.dart'
    show
        LitebaseClient,
        LitebaseClientOptions,
        createClient,
        AuthAPI;
export 'src/errors.dart' show LitebaseException;
export 'src/http_transport.dart'
    show HttpTransport, HttpTransportResponse, PackageHttpTransport;
export 'src/models.dart'
    show
        AuthTokens,
        ChangeEvent,
        ControlEvent,
        ControlHandler,
        ListMeta,
        ListResult,
        SessionTokens,
        SubscribeHandler,
        Unsubscribe,
        User,
        stringifyId;
export 'src/realtime_url.dart'
    show
        encodeUriComponent,
        joinUrl,
        makeRequestId,
        realtimeWebSocketUrl,
        unixSecondsNow;
export 'src/sub_key.dart' show makeSubKey, parseSubKey;
export 'src/table_query.dart' show TableQuery;
export 'src/websocket.dart'
    show WebSocketChannelConnection, WebSocketConnecting, WebSocketFactory;
