import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../settings/app_settings.dart';
import 'device_identity.dart';
import 'license_api.dart';
import 'license_config.dart';
import 'license_key.dart';
import 'license_store.dart';
import 'license_token.dart';

/// This device's verified activation.
@immutable
class ActiveLicense {
  const ActiveLicense({required this.key, required this.token, required this.payload});

  /// The canonical licence key.
  final String key;
  final String token;
  final LicensePayload payload;

  String get maskedKey => maskLicenseKey(key);
}

@immutable
class LicenseState {
  const LicenseState({this.active, this.loading = false, this.busy = false, this.error});

  /// Null when this device is not activated.
  final ActiveLicense? active;

  /// The stored activation is still being read and verified.
  final bool loading;

  /// An activation or deactivation is in progress.
  final bool busy;
  final LicenseException? error;

  bool get isActive => active != null;

  LicenseState copyWith({bool? busy, LicenseException? error, bool clearError = false}) => LicenseState(
    active: active,
    loading: loading,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Licence activation for builds sold outside the stores
/// (`CIRRUS_STORE=license`): activates and deactivates this device, keeps
/// the signed token in secure storage, verifies it again on every start and
/// re-checks it with the server once a week.
class LicenseController extends Notifier<LicenseState> {
  /// When the server last confirmed the activation (ms since epoch).
  static const lastValidatedKey = 'cirrus.license.lastValidated';
  static const validateInterval = Duration(days: 7);

  @override
  LicenseState build() {
    Future<void>.microtask(_load);
    return const LicenseState(loading: true);
  }

  /// The token verifier and the running platform; throws
  /// [LicenseError.notConfigured] when this build cannot check tokens.
  (LicenseVerifier, LicensePlatform) _setup() {
    final key = ref.read(licenseConfigProvider).publicKey;
    final platform = ref.read(licensePlatformProvider);
    if (key == null || platform == null) throw const LicenseException(LicenseError.notConfigured);
    return (LicenseVerifier(key), platform);
  }

  static Future<DeviceIdentity> _device(DeviceIdentitySource source) async {
    try {
      return await source.read();
    } catch (e) {
      throw LicenseException(LicenseError.deviceUnavailable, message: '$e');
    }
  }

  static Future<String> _appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '';
    }
  }

  Future<void> _load() async {
    LicenseState next;
    try {
      final (verifier, platform) = _setup();
      final store = ref.read(licenseStoreProvider);
      final source = ref.read(deviceIdentityProvider);
      final stored = await store.load();
      if (stored == null) {
        next = const LicenseState();
      } else {
        final device = await _device(source);
        try {
          final payload = await verifier.verify(stored.token, platform: platform, deviceId: device.id);
          next = LicenseState(
            active: ActiveLicense(key: stored.key, token: stored.token, payload: payload),
          );
        } on InvalidTokenException catch (e) {
          // Copied from another device, or signed with a retired key.
          debugPrint('Dropping the stored licence activation: $e');
          await store.clear();
          next = const LicenseState();
        }
      }
    } on LicenseException catch (e) {
      next = LicenseState(error: e);
    }
    if (!ref.mounted) return;
    state = next;
    if (next.isActive) await validate();
  }

  /// Activates this device with a licence key as typed or pasted. Returns
  /// whether it worked; otherwise [LicenseState.error] says why.
  Future<bool> activate(String input) async {
    final key = normalizeLicenseKey(input);
    if (key == null) {
      state = state.copyWith(error: const LicenseException(LicenseError.invalidKey));
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final (verifier, platform) = _setup();
      final store = ref.read(licenseStoreProvider);
      final api = ref.read(licenseApiProvider);
      final prefs = ref.read(sharedPrefsProvider);
      final device = await _device(ref.read(deviceIdentityProvider));
      final activation = await api.activate(
        key: key,
        deviceId: device.id,
        deviceName: device.name,
        platform: platform,
        appVersion: await _appVersion(),
      );
      final LicensePayload payload;
      try {
        payload = await verifier.verify(activation.token, platform: platform, deviceId: device.id);
      } on InvalidTokenException catch (e) {
        throw LicenseException(LicenseError.invalidToken, message: '$e');
      }
      await store.save(StoredLicense(key: key, token: activation.token));
      // A fresh activation needs no check for a while.
      await prefs.setInt(lastValidatedKey, DateTime.now().millisecondsSinceEpoch);
      if (ref.mounted) {
        state = LicenseState(
          active: ActiveLicense(key: key, token: activation.token, payload: payload),
        );
      }
      return true;
    } catch (e) {
      if (ref.mounted) state = state.copyWith(busy: false, error: _asLicenseException(e));
      return false;
    }
  }

  /// Frees this device's activation on the server and forgets it here, so
  /// the key can be used on another device. Returns whether it worked.
  Future<bool> deactivate() async {
    final active = state.active;
    if (active == null) return true;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final store = ref.read(licenseStoreProvider);
      final api = ref.read(licenseApiProvider);
      final prefs = ref.read(sharedPrefsProvider);
      final device = await _device(ref.read(deviceIdentityProvider));
      try {
        await api.deactivate(key: active.key, deviceId: device.id);
      } on LicenseException catch (e) {
        // A key the server no longer knows has no activation to free.
        if (e.code != LicenseError.invalidKey) rethrow;
      }
      await store.clear();
      await prefs.remove(lastValidatedKey);
      if (ref.mounted) state = const LicenseState();
      return true;
    } catch (e) {
      if (ref.mounted) state = state.copyWith(busy: false, error: _asLicenseException(e));
      return false;
    }
  }

  /// Asks the server whether this device's activation still stands, at most
  /// once every [validateInterval] unless [force]d. Drops the activation when
  /// the device was deactivated (e.g. by a reset on the website) or the
  /// licence revoked; keeps it when the server cannot be reached.
  Future<void> validate({bool force = false}) async {
    final active = state.active;
    if (active == null) return;
    final prefs = ref.read(sharedPrefsProvider);
    final last = prefs.getInt(lastValidatedKey);
    final now = DateTime.now();
    if (!force && last != null) {
      final elapsed = now.difference(DateTime.fromMillisecondsSinceEpoch(last));
      // A clock set back counts as due.
      if (!elapsed.isNegative && elapsed < validateInterval) return;
    }
    final store = ref.read(licenseStoreProvider);
    final api = ref.read(licenseApiProvider);
    final LicenseCheck check;
    try {
      final device = await _device(ref.read(deviceIdentityProvider));
      check = await api.validate(key: active.key, deviceId: device.id);
    } on LicenseException catch (e) {
      // Offline or a server problem: keep the activation, try next start.
      debugPrint('Licence check failed: $e');
      return;
    }
    if (check == LicenseCheck.active) {
      await prefs.setInt(lastValidatedKey, now.millisecondsSinceEpoch);
      return;
    }
    // Unless the user changed the activation in the meantime.
    if (ref.mounted && state.active != active) return;
    await store.clear();
    await prefs.remove(lastValidatedKey);
    if (ref.mounted) {
      state = LicenseState(
        error: LicenseException(check == LicenseCheck.revoked ? LicenseError.revoked : LicenseError.notActivated),
      );
    }
  }

  static LicenseException _asLicenseException(Object e) =>
      e is LicenseException ? e : LicenseException(LicenseError.unexpected, message: '$e');
}

final licenseProvider = NotifierProvider<LicenseController, LicenseState>(LicenseController.new);
