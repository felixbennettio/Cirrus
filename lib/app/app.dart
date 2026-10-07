import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings/app_settings.dart';
import '../features/lock/lock_gate.dart';
import 'router.dart';
import 'theme.dart';

class CirrusApp extends ConsumerWidget {
  const CirrusApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final locale = ref.watch(settingsProvider.select((s) => s.locale));
    final dynamicColor = ref.watch(settingsProvider.select((s) => s.dynamicColor));
    final glass = ref.watch(settingsProvider.select((s) => s.glassEnabled));
    // Android 12+: the wallpaper palette; macOS, Windows, Linux: the system
    // accent colour. Null elsewhere, which keeps the brand scheme.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final available = lightDynamic != null && darkDynamic != null;
        final light = available && dynamicColor ? schemeFromMaterialUi(lightDynamic) : null;
        final dark = available && dynamicColor ? schemeFromMaterialUi(darkDynamic) : null;
        ThemeData theme(Brightness b, ColorScheme? scheme, {required bool glass}) =>
            buildTheme(b, dynamicScheme: scheme, glass: glass, dynamicColorAvailable: available);
        return MaterialApp.router(
          title: 'Cirrus',
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light, light, glass: glass),
          darkTheme: theme(Brightness.dark, dark, glass: glass),
          // No glass when the platform asks for high contrast.
          highContrastTheme: theme(Brightness.light, light, glass: false),
          highContrastDarkTheme: theme(Brightness.dark, dark, glass: false),
          themeMode: themeMode,
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: router,
          builder: (context, child) => LockGate(child: child ?? const SizedBox()),
        );
      },
    );
  }
}
