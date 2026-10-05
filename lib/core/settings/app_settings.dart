import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in `main()` with the loaded instance.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider must be overridden'),
);

@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.localeCode,
    this.appLock = false,
    this.activeProfileId,
    this.activeAccount = const {},
    this.activeZone = const {},
    this.favoriteOps = const [],
    this.compactSidebar = false,
    this.confirmMutations = true,
  });

  final ThemeMode themeMode;

  /// `null` follows the system language.
  final String? localeCode;
  final bool appLock;
  final String? activeProfileId;

  /// Last selected account per profile id.
  final Map<String, String> activeAccount;

  /// Last selected zone per account id.
  final Map<String, String> activeZone;
  final List<String> favoriteOps;
  final bool compactSidebar;

  /// Ask before sending POST/PUT/PATCH/DELETE from the API console.
  final bool confirmMutations;

  Locale? get locale => localeCode == null ? null : Locale(localeCode!);

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? localeCode,
    bool clearLocale = false,
    bool? appLock,
    String? activeProfileId,
    Map<String, String>? activeAccount,
    Map<String, String>? activeZone,
    List<String>? favoriteOps,
    bool? compactSidebar,
    bool? confirmMutations,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    localeCode: clearLocale ? null : (localeCode ?? this.localeCode),
    appLock: appLock ?? this.appLock,
    activeProfileId: activeProfileId ?? this.activeProfileId,
    activeAccount: activeAccount ?? this.activeAccount,
    activeZone: activeZone ?? this.activeZone,
    favoriteOps: favoriteOps ?? this.favoriteOps,
    compactSidebar: compactSidebar ?? this.compactSidebar,
    confirmMutations: confirmMutations ?? this.confirmMutations,
  );

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.name,
    'localeCode': localeCode,
    'appLock': appLock,
    'activeProfileId': activeProfileId,
    'activeAccount': activeAccount,
    'activeZone': activeZone,
    'favoriteOps': favoriteOps,
    'compactSidebar': compactSidebar,
    'confirmMutations': confirmMutations,
  };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    themeMode: ThemeMode.values.firstWhere((m) => m.name == j['themeMode'], orElse: () => ThemeMode.system),
    localeCode: j['localeCode'] as String?,
    appLock: j['appLock'] == true,
    activeProfileId: j['activeProfileId'] as String?,
    activeAccount: Map<String, String>.from(j['activeAccount'] as Map? ?? const {}),
    activeZone: Map<String, String>.from(j['activeZone'] as Map? ?? const {}),
    favoriteOps: (j['favoriteOps'] as List?)?.cast<String>() ?? const [],
    compactSidebar: j['compactSidebar'] == true,
    confirmMutations: j['confirmMutations'] != false,
  );
}

class SettingsController extends Notifier<AppSettings> {
  static const _key = 'cirrus.settings.v1';

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPrefsProvider);
    final raw = prefs.getString(_key);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  void _save(AppSettings s) {
    state = s;
    ref.read(sharedPrefsProvider).setString(_key, jsonEncode(s.toJson()));
  }

  void update(AppSettings Function(AppSettings) fn) => _save(fn(state));

  void setThemeMode(ThemeMode m) => _save(state.copyWith(themeMode: m));

  void setLocale(String? code) =>
      _save(code == null ? state.copyWith(clearLocale: true) : state.copyWith(localeCode: code));

  void setActiveProfile(String id) => _save(state.copyWith(activeProfileId: id));

  void setActiveAccount(String profileId, String accountId) =>
      _save(state.copyWith(activeAccount: {...state.activeAccount, profileId: accountId}));

  void setActiveZone(String accountId, String? zoneId) {
    final m = {...state.activeZone};
    if (zoneId == null) {
      m.remove(accountId);
    } else {
      m[accountId] = zoneId;
    }
    _save(state.copyWith(activeZone: m));
  }

  void toggleFavoriteOp(String id) {
    final f = [...state.favoriteOps];
    f.contains(id) ? f.remove(id) : f.insert(0, id);
    _save(state.copyWith(favoriteOps: f));
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
