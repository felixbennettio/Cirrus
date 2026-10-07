import 'dart:convert';

import 'package:cirrus/core/settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container() async {
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('appearance defaults: system theme, dynamic colour on', () async {
    final s = (await _container()).read(settingsProvider);
    expect(s.themeMode, ThemeMode.system);
    expect(s.dynamicColor, isTrue);
    expect(s.liquidGlass, isNull);
  });

  test('liquid glass is on by default on iOS and macOS only', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final (platform, on) in [
      (TargetPlatform.iOS, true),
      (TargetPlatform.macOS, true),
      (TargetPlatform.android, false),
      (TargetPlatform.windows, false),
      (TargetPlatform.linux, false),
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(const AppSettings().glassEnabled, on, reason: '$platform');
      // An explicit choice wins everywhere.
      expect(const AppSettings(liquidGlass: false).glassEnabled, isFalse);
      expect(const AppSettings(liquidGlass: true).glassEnabled, isTrue);
    }
  });

  test('theme mode, dynamic colour and liquid glass persist', () async {
    final first = await _container();
    first.read(settingsProvider.notifier)
      ..setThemeMode(ThemeMode.dark)
      ..setDynamicColor(false)
      ..setLiquidGlass(true);
    // A fresh start reads them back from SharedPreferences.
    final again = (await _container()).read(settingsProvider);
    expect(again.themeMode, ThemeMode.dark);
    expect(again.dynamicColor, isFalse);
    expect(again.liquidGlass, isTrue);
    expect(again.glassEnabled, isTrue);
  });

  test('settings saved before these options existed keep the defaults', () async {
    SharedPreferences.setMockInitialValues({
      'cirrus.settings.v1': jsonEncode({'themeMode': 'light', 'compactSidebar': true}),
    });
    final s = (await _container()).read(settingsProvider);
    expect(s.themeMode, ThemeMode.light);
    expect(s.compactSidebar, isTrue);
    expect(s.dynamicColor, isTrue);
    expect(s.liquidGlass, isNull);
  });
}
