import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// A licence key and this device's activation token.
@immutable
class StoredLicense {
  const StoredLicense({required this.key, required this.token});

  factory StoredLicense.fromJson(Map<String, dynamic> j) =>
      StoredLicense(key: j['key'] as String, token: j['token'] as String);

  final String key;
  final String token;

  Map<String, dynamic> toJson() => {'key': key, 'token': token};
}

/// Persists the [StoredLicense] in the platform secure store, like
/// `CredentialStore`: where secure storage is unavailable (a Linux desktop
/// without a Secret Service) it falls back to a file readable only by the
/// current user. The token is signed, so the file cannot be used to forge
/// an activation.
class LicenseStore {
  LicenseStore({FlutterSecureStorage? storage, Future<Directory> Function()? fallbackDir})
    : _storage = storage ?? const FlutterSecureStorage(),
      _fallbackDir = fallbackDir ?? getApplicationSupportDirectory;

  static const storageKey = 'cirrus.license.v1';

  final FlutterSecureStorage _storage;
  final Future<Directory> Function() _fallbackDir;
  bool usingFallback = false;

  Future<File> _fallbackFile() async {
    final dir = await _fallbackDir();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}license.json');
  }

  Future<void> _restrict(File f) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', f.path]);
    } catch (_) {}
  }

  Future<StoredLicense?> load() async {
    String? raw;
    try {
      raw = await _storage.read(key: storageKey);
      usingFallback = false;
    } catch (e) {
      debugPrint('Secure storage unavailable, using fallback: $e');
      usingFallback = true;
    }
    if (raw == null || raw.isEmpty) {
      // Secure storage is unavailable, or a previous run used the fallback.
      try {
        final f = await _fallbackFile();
        if (await f.exists()) raw = await f.readAsString();
      } catch (_) {}
      if (raw == null || raw.isEmpty) return null;
    }
    try {
      return StoredLicense.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (e) {
      debugPrint('Corrupt licence store: $e');
      return null;
    }
  }

  Future<void> save(StoredLicense license) async {
    final raw = jsonEncode(license.toJson());
    if (!usingFallback) {
      try {
        await _storage.write(key: storageKey, value: raw);
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

  Future<void> clear() async {
    try {
      await _storage.delete(key: storageKey);
    } catch (_) {}
    try {
      final f = await _fallbackFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

final licenseStoreProvider = Provider<LicenseStore>((ref) => LicenseStore());
