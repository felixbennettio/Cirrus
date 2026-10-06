import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Platforms sold with licence keys, named as in activation tokens and
/// product ids (`docs/licensing.md`).
enum LicensePlatform {
  windows('Windows'),
  linux('Linux'),
  android('Android');

  const LicensePlatform(this.label);

  final String label;

  /// `cirrus-windows`, `cirrus-linux` or `cirrus-android`.
  String get productId => 'cirrus-$name';

  static LicensePlatform? fromName(String name) => values.firstWhereOrNull((p) => p.name == name);

  /// The platform this binary runs on, or null where licences are not sold.
  static LicensePlatform? get current {
    if (kIsWeb) return null;
    if (Platform.isWindows) return windows;
    if (Platform.isLinux) return linux;
    if (Platform.isAndroid) return android;
    return null;
  }
}

/// The licence server and the key its activation tokens are signed with.
@immutable
class LicenseConfig {
  const LicenseConfig({this.server = defaultServer, this.publicKey});

  /// Parses the raw settings: a server URL (blank for the default) and the
  /// standard base64 of the 32-byte Ed25519 public key. A missing or
  /// malformed key leaves [publicKey] null.
  factory LicenseConfig.parse({String server = '', String publicKey = ''}) {
    final url = server.trim().replaceFirst(RegExp(r'/+$'), '');
    List<int>? key;
    try {
      final bytes = base64.decode(publicKey.trim());
      if (bytes.length == 32) key = bytes;
    } on FormatException {
      // Not base64: treated like a missing key.
    }
    return LicenseConfig(server: url.isEmpty ? defaultServer : url, publicKey: key);
  }

  /// The configuration built into this binary, from
  /// `--dart-define=CIRRUS_LICENSE_SERVER=https://...` and
  /// `--dart-define=CIRRUS_LICENSE_PUBKEY=<base64>`.
  factory LicenseConfig.builtIn() => LicenseConfig.parse(
    server: const String.fromEnvironment('CIRRUS_LICENSE_SERVER'),
    publicKey: const String.fromEnvironment('CIRRUS_LICENSE_PUBKEY'),
  );

  static const defaultServer = 'https://cirrus.routeforge.zone';

  /// Base URL, without a trailing slash.
  final String server;

  /// The server's Ed25519 public key (32 bytes). Null when the build has
  /// none, which disables activation.
  final List<int>? publicKey;

  bool get canActivate => publicKey != null;

  /// The website's purchase page for [platform].
  Uri buyUri(LicensePlatform platform) =>
      Uri.parse('$server/buy').replace(queryParameters: {'product': platform.productId});

  /// The website's licence page, where devices can be reset.
  Uri get manageUri => Uri.parse('$server/license');
}

final licenseConfigProvider = Provider<LicenseConfig>((ref) => LicenseConfig.builtIn());

/// The platform licences are checked against (overridden in tests).
final licensePlatformProvider = Provider<LicensePlatform?>((ref) => LicensePlatform.current);
