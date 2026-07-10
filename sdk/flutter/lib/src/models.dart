/// Authenticated user returned by `/auth/me` and login/register payloads.
class User {
  final String id;
  final String email;
  final String role;
  final bool disabled;
  final int createdAt;

  const User({
    required this.id,
    required this.email,
    required this.role,
    required this.disabled,
    required this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id']?.toString() ?? '',
      email: json['email'] as String? ?? '',
      role: json['role'] as String? ?? '',
      disabled: json['disabled'] == true || json['disabled'] == 1,
      createdAt: _asInt(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'role': role,
        'disabled': disabled,
        'created_at': createdAt,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is User &&
          id == other.id &&
          email == other.email &&
          role == other.role &&
          disabled == other.disabled &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(id, email, role, disabled, createdAt);
}

/// Access + refresh token pair from login/register/refresh.
class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final int expiresIn;
  final User? user;

  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
    this.user,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access_token'] as String? ?? '',
      refreshToken: json['refresh_token'] as String? ?? '',
      tokenType: json['token_type'] as String? ?? 'Bearer',
      expiresIn: _asInt(json['expires_in']),
      user: json['user'] is Map<String, dynamic>
          ? User.fromJson(json['user'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'token_type': tokenType,
        'expires_in': expiresIn,
        if (user != null) 'user': user!.toJson(),
      };
}

/// Minimal session shape for [LitebaseClient.setSession].
class SessionTokens {
  final String accessToken;
  final String refreshToken;
  final String? tokenType;
  final int? expiresIn;
  final User? user;

  const SessionTokens({
    required this.accessToken,
    required this.refreshToken,
    this.tokenType,
    this.expiresIn,
    this.user,
  });
}

/// List response metadata.
class ListMeta {
  final int limit;
  final int offset;
  final int total;

  /// Present when rule-filtered list hit the server scan cap; [total] is a lower bound.
  final bool? truncated;

  const ListMeta({
    required this.limit,
    required this.offset,
    required this.total,
    this.truncated,
  });

  factory ListMeta.fromJson(Map<String, dynamic> json) {
    return ListMeta(
      limit: _asInt(json['limit']),
      offset: _asInt(json['offset']),
      total: _asInt(json['total']),
      truncated: json['truncated'] as bool?,
    );
  }
}

/// Result of a table list (`select`).
class ListResult {
  final List<Map<String, dynamic>> data;
  final ListMeta meta;

  const ListResult({required this.data, required this.meta});
}

/// Realtime change frame (`type: "change"`).
class ChangeEvent {
  final String type;
  final String? channel;
  final String table;
  final String op;
  final String id;
  final Map<String, dynamic>? data;

  /// Unix **seconds** (same unit as server CDC events).
  final int ts;

  const ChangeEvent({
    this.type = 'change',
    this.channel,
    required this.table,
    required this.op,
    required this.id,
    this.data,
    required this.ts,
  });

  factory ChangeEvent.fromJson(Map<String, dynamic> json) {
    return ChangeEvent(
      type: json['type'] as String? ?? 'change',
      channel: json['channel'] as String?,
      table: json['table'] as String? ?? '',
      op: json['op'] as String? ?? '',
      id: stringifyId(json['id']),
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : null,
      ts: _asInt(json['ts']),
    );
  }
}

/// Non-change control frames (auth/subscribe/error).
class ControlEvent {
  final String type;
  final String? requestId;
  final String? channel;
  final String? table;
  final String? message;
  final String? code;
  final String? id;

  const ControlEvent({
    required this.type,
    this.requestId,
    this.channel,
    this.table,
    this.message,
    this.code,
    this.id,
  });

  factory ControlEvent.fromJson(Map<String, dynamic> json) {
    return ControlEvent(
      type: json['type'] as String? ?? '',
      requestId: json['requestId'] as String?,
      channel: json['channel'] as String?,
      table: json['table'] as String?,
      message: json['message'] as String?,
      code: json['code'] as String?,
      id: json.containsKey('id') ? stringifyId(json['id']) : null,
    );
  }
}

typedef SubscribeHandler = void Function(ChangeEvent event);
typedef ControlHandler = void Function(ControlEvent event);
typedef Unsubscribe = void Function();

/// Coerce JSON id values to string.
String stringifyId(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num) {
    if (value is int || value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }
  return value.toString();
}

int _asInt(Object? value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
