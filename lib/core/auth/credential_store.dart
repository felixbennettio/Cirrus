import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'credential.dart';

/// Persists [Profile]s in the platform secure store.
///
/// On Linux desktops without a Secret Service (e.g. no GNOME Keyring /
/// KWallet running) secure storage is unavailable. In that case profiles
/// fall back to a file readable only by the current user and
/// [usingFallback] is set so the UI can warn about it.
class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ??
          const FlutterSecureStorage(
            // Unsigned macOS builds cannot use the data-protection keychain
            // (errSecMissingEntitlement); the login keychain works everywhere.
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _key = 'cirrus.profiles.v1';

  final FlutterSecureStorage _storage;
  bool usingFallback = false;

  Future<File> _fallbackFile() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}profiles.json');
  }

  Future<List<Profile>> load() async {
    String? raw;
    try {
      raw = await _storage.read(key: _key);
      usingFallback = false;
    } catch (e) {
      debugPrint('Secure storage unavailable, using fallback: $e');
      usingFallback = true;
      final f = await _fallbackFile();
      if (await f.exists()) raw = await f.readAsString();
    }
    if (raw == null || raw.isEmpty) {
      // A previous run may have used the fallback file.
      if (!usingFallback) {
        try {
          final f = await _fallbackFile();
          if (await f.exists()) raw = await f.readAsString();
        } catch (_) {}
      }
      if (raw == null || raw.isEmpty) return [];
    }
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(Profile.fromJson)
          .toList();
    } catch (e) {
      debugPrint('Corrupt profile store: $e');
      return [];
    }
  }

  Future<void> save(List<Profile> profiles) async {
    final raw = jsonEncode(profiles.map((p) => p.toJson()).toList());
    if (!usingFallback) {
      try {
        await _storage.write(key: _key, value: raw);
        return;
      } catch (e) {
        debugPrint('Secure storage write failed, using fallback: $e');
        usingFallback = true;
      }
    }
    final f = await _fallbackFile();
    await f.writeAsString(raw, flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {}
    }
  }
}
