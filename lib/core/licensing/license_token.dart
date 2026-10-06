import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'license_config.dart';

/// What an activation token says (`docs/licensing.md`, "Activation token").
@immutable
class LicensePayload {
  const LicensePayload({
    required this.version,
    required this.licenseId,
    required this.product,
    required this.platform,
    required this.device,
    required this.issuedAt,
    required this.owner,
  });

  factory LicensePayload.fromJson(Map<String, dynamic> j) => LicensePayload(
    version: switch (j['v']) {
      final int v => v,
      _ => 0,
    },
    licenseId: j['lic'] as String? ?? '',
    product: j['product'] as String? ?? '',
    platform: j['platform'] as String,
    device: j['device'] as String,
    issuedAt: DateTime.fromMillisecondsSinceEpoch(((j['iat'] as num?) ?? 0).toInt() * 1000, isUtc: true),
    owner: j['owner'] as String? ?? '',
  );

  final int version;
  final String licenseId;
  final String product;
  final String platform;

  /// The device id the token was issued for.
  final String device;
  final DateTime issuedAt;

  /// The buyer's email, partly hidden (`q***@gmail.com`).
  final String owner;
}

/// Why a token was refused.
enum TokenRejection { malformed, badSignature, unsupportedVersion, wrongPlatform, wrongDevice }

class InvalidTokenException implements Exception {
  const InvalidTokenException(this.reason);

  final TokenRejection reason;

  @override
  String toString() => 'Invalid activation token (${reason.name})';
}

/// Checks activation tokens against the public key built into the app.
class LicenseVerifier {
  LicenseVerifier(List<int> publicKey) : _publicKey = SimplePublicKey(publicKey, type: KeyPairType.ed25519);

  final SimplePublicKey _publicKey;
  static final _ed25519 = Ed25519();

  /// The payload of [token] when it is signed by the server, of version 1
  /// and issued for [platform] and [deviceId]. Throws
  /// [InvalidTokenException] otherwise.
  Future<LicensePayload> verify(String token, {required LicensePlatform platform, required String deviceId}) async {
    final parts = token.trim().split('.');
    final payload = parts.length == 2 ? decodeBase64Url(parts[0]) : null;
    final signature = parts.length == 2 ? decodeBase64Url(parts[1]) : null;
    if (payload == null || signature == null || signature.length != 64) {
      throw const InvalidTokenException(TokenRejection.malformed);
    }
    // Over the exact payload bytes, before reading anything from them.
    var valid = false;
    try {
      valid = await _ed25519.verify(payload, signature: Signature(signature, publicKey: _publicKey));
    } catch (_) {
      // An unusable key or signature verifies nothing.
    }
    if (!valid) throw const InvalidTokenException(TokenRejection.badSignature);
    final LicensePayload p;
    try {
      p = LicensePayload.fromJson(Map<String, dynamic>.from(jsonDecode(utf8.decode(payload)) as Map));
    } catch (_) {
      throw const InvalidTokenException(TokenRejection.malformed);
    }
    if (p.version != 1) throw const InvalidTokenException(TokenRejection.unsupportedVersion);
    if (p.platform != platform.name) throw const InvalidTokenException(TokenRejection.wrongPlatform);
    if (p.device != deviceId) throw const InvalidTokenException(TokenRejection.wrongDevice);
    return p;
  }
}

/// base64url without padding, as used in tokens.
String encodeBase64Url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes unpadded base64url; null when [s] is anything else.
List<int>? decodeBase64Url(String s) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s) || s.length % 4 == 1) return null;
  try {
    return base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    return null;
  }
}
