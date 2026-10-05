import 'dart:math';

/// How a profile authenticates against the Cloudflare API.
enum AuthKind {
  /// `Authorization: Bearer <token>` — user- or account-owned API token.
  apiToken,

  /// `X-Auth-Email` + `X-Auth-Key` — legacy Global API Key.
  globalKey,
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
    this.createdAt,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Cloudflare',
    kind: AuthKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => AuthKind.apiToken,
    ),
    token: json['token'] as String?,
    email: json['email'] as String?,
    apiKey: json['apiKey'] as String?,
    originCaKey: json['originCaKey'] as String?,
    accountId: json['accountId'] as String?,
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

  final DateTime? createdAt;

  /// Headers that authenticate a request.
  Map<String, String> authHeaders({bool originCa = false}) {
    if (originCa && (originCaKey?.isNotEmpty ?? false)) {
      return {'X-Auth-User-Service-Key': originCaKey!};
    }
    return switch (kind) {
      AuthKind.apiToken => {'Authorization': 'Bearer ${token ?? ''}'},
      AuthKind.globalKey => {
        'X-Auth-Email': email ?? '',
        'X-Auth-Key': apiKey ?? '',
      },
    };
  }

  /// A short, non-secret hint such as `abcd…wxyz` for display.
  String get secretHint {
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
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
  };
}
