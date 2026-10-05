import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'credential.dart';
import 'oauth.dart';
import 'oauth_session.dart';

/// Persists [Profile]s in the platform secure store.
///
/// On Linux desktops without a Secret Service (e.g. no GNOME Keyring /
/// KWallet running) secure storage is unavailable. In that case profiles
/// fall back to a file readable only by the current user and
/// [usingFallback] is set so the UI can warn about it.
class CredentialStore implements OAuthTokenStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Unsigned macOS builds cannot use the data-protection keychain
            // (errSecMissingEntitlement); the login keychain works everywhere.
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _key = 'cirrus.profiles.v1';

  final FlutterSecureStorage _storage;
  bool usingFallback = false;

  Future<File> _fallbackFile([String name = 'profiles.json']) async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Future<void> _restrict(File f) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', f.path]);
    } catch (_) {}
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
      return list.whereType<Map<String, dynamic>>().map(Profile.fromJson).toList();
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
    await _restrict(f);
  }

  // OAuth tokens: one secure-storage entry (or fallback file) per profile.

  static String _tokenKey(String profileId) => 'cirrus.oauth.$profileId';
  static String _tokenFile(String profileId) => 'oauth-$profileId.json';

  @override
  Future<OAuthTokens?> readTokens(String profileId) async {
    String? raw;
    if (!usingFallback) {
      try {
        raw = await _storage.read(key: _tokenKey(profileId));
      } catch (_) {
        usingFallback = true;
      }
    }
    if (raw == null) {
      try {
        final f = await _fallbackFile(_tokenFile(profileId));
        if (await f.exists()) raw = await f.readAsString();
      } catch (_) {}
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      return OAuthTokens.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (e) {
      debugPrint('Corrupt OAuth tokens for $profileId: $e');
      return null;
    }
  }

  @override
  Future<void> writeTokens(String profileId, OAuthTokens tokens) async {
    final raw = jsonEncode(tokens.toJson());
    if (!usingFallback) {
      try {
        await _storage.write(key: _tokenKey(profileId), value: raw);
        return;
      } catch (e) {
        debugPrint('Secure storage write failed, using fallback: $e');
        usingFallback = true;
      }
    }
    final f = await _fallbackFile(_tokenFile(profileId));
    await f.writeAsString(raw, flush: true);
    await _restrict(f);
  }

  @override
  Future<void> deleteTokens(String profileId) async {
    try {
      await _storage.delete(key: _tokenKey(profileId));
    } catch (_) {}
    try {
      final f = await _fallbackFile(_tokenFile(profileId));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
