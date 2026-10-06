import 'dart:math';

/// How a profile authenticates against the Cloudflare API.
enum AuthKind {
  /// `Authorization: Bearer <token>` — user- or account-owned API token.
  apiToken,

  /// `X-Auth-Email` + `X-Auth-Key` — legacy Global API Key.
  globalKey,

  /// `Authorization: Bearer <access token>` from Cloudflare OAuth. The
  /// tokens live in an `OAuthSession`, not in the profile.
  oauth,
}

/// A saved set of credentials. Everything here is stored in the platform's
/// secure storage (Keychain / Keystore / libsecret / Credential Manager).
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.kind,
    this.token,
    this.email,
    this.apiKey,
    this.originCaKey,
    this.accountId,
    this.oauthClientId,
    this.oauthScopes = const [],
    this.createdAt,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Cloudflare',
    kind: AuthKind.values.firstWhere((k) => k.name == json['kind'], orElse: () => AuthKind.apiToken),
    token: json['token'] as String?,
    email: json['email'] as String?,
    apiKey: json['apiKey'] as String?,
    originCaKey: json['originCaKey'] as String?,
    accountId: json['accountId'] as String?,
    oauthClientId: json['oauthClientId'] as String?,
    oauthScopes: ((json['oauthScopes'] as List?) ?? const []).map((e) => '$e').toList(),
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );

  static String newId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  final String id;
  final String name;
  final AuthKind kind;

  /// API token (for [AuthKind.apiToken]).
  final String? token;

  /// Account e-mail (for [AuthKind.globalKey]).
  final String? email;

  /// Global API key (for [AuthKind.globalKey]).
  final String? apiKey;

  /// Optional Origin CA key, used only for `/certificates` endpoints.
  final String? originCaKey;

  /// Set for account-owned API tokens, which must be verified against
  /// `/accounts/{id}/tokens/verify`.
  final String? accountId;

  /// OAuth client the session was issued to (for [AuthKind.oauth]).
  final String? oauthClientId;

  /// Scopes requested at sign-in (for [AuthKind.oauth]).
  final List<String> oauthScopes;

  final DateTime? createdAt;

  /// Human-readable credential type.
  String get kindLabel => switch (kind) {
    AuthKind.apiToken => 'API Token',
    AuthKind.globalKey => 'Global API Key',
    AuthKind.oauth => 'OAuth',
  };

  /// Headers that authenticate a request. OAuth profiles get their bearer
  /// token from the client's `AccessTokenSource` instead.
  Map<String, String> authHeaders({bool originCa = false}) {
    if (originCa && (originCaKey?.isNotEmpty ?? false)) {
      return {'X-Auth-User-Service-Key': originCaKey!};
    }
    return switch (kind) {
      AuthKind.apiToken => {'Authorization': 'Bearer ${token ?? ''}'},
      AuthKind.globalKey => {'X-Auth-Email': email ?? '', 'X-Auth-Key': apiKey ?? ''},
      AuthKind.oauth => const {},
    };
  }

  /// A short, non-secret hint such as `abcd…wxyz` for display.
  String get secretHint {
    if (kind == AuthKind.oauth) return email ?? 'Cloudflare';
    final s = kind == AuthKind.apiToken ? token : apiKey;
    if (s == null || s.length < 10) return '••••';
    return '${s.substring(0, 4)}…${s.substring(s.length - 4)}';
  }

  Profile copyWith({
    String? name,
    AuthKind? kind,
    String? token,
    String? email,
    String? apiKey,
    String? originCaKey,
    String? accountId,
    bool clearAccountId = false,
    bool clearOriginCaKey = false,
  }) => Profile(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    token: token ?? this.token,
    email: email ?? this.email,
    apiKey: apiKey ?? this.apiKey,
    originCaKey: clearOriginCaKey ? null : (originCaKey ?? this.originCaKey),
    accountId: clearAccountId ? null : (accountId ?? this.accountId),
    oauthClientId: oauthClientId,
    oauthScopes: oauthScopes,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    if (token != null) 'token': token,
    if (email != null) 'email': email,
    if (apiKey != null) 'apiKey': apiKey,
    if (originCaKey != null) 'originCaKey': originCaKey,
    if (accountId != null) 'accountId': accountId,
    if (oauthClientId != null) 'oauthClientId': oauthClientId,
    if (oauthScopes.isNotEmpty) 'oauthScopes': oauthScopes,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
  };
}
