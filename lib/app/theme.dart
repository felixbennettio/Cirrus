import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui show ColorScheme;

import '../ui/cirrus_theme.dart';
import '../ui/widgets/glass.dart';

const cirrusSeed = Color(0xFFF2701B);

/// The scheme from the brand colour, used when dynamic colour is off or the
/// platform has none.
ColorScheme brandScheme(Brightness brightness) => ColorScheme.fromSeed(
  seedColor: cirrusSeed,
  brightness: brightness,
  dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
);

/// dynamic_color 2.x builds its schemes with `package:material_ui`, whose
/// `ColorScheme` is a different class from Flutter's: copy it role by role.
ColorScheme schemeFromMaterialUi(mui.ColorScheme s) => ColorScheme(
  brightness: s.brightness,
  primary: s.primary,
  onPrimary: s.onPrimary,
  primaryContainer: s.primaryContainer,
  onPrimaryContainer: s.onPrimaryContainer,
  primaryFixed: s.primaryFixed,
  primaryFixedDim: s.primaryFixedDim,
  onPrimaryFixed: s.onPrimaryFixed,
  onPrimaryFixedVariant: s.onPrimaryFixedVariant,
  secondary: s.secondary,
  onSecondary: s.onSecondary,
  secondaryContainer: s.secondaryContainer,
  onSecondaryContainer: s.onSecondaryContainer,
  secondaryFixed: s.secondaryFixed,
  secondaryFixedDim: s.secondaryFixedDim,
  onSecondaryFixed: s.onSecondaryFixed,
  onSecondaryFixedVariant: s.onSecondaryFixedVariant,
  tertiary: s.tertiary,
  onTertiary: s.onTertiary,
  tertiaryContainer: s.tertiaryContainer,
  onTertiaryContainer: s.onTertiaryContainer,
  tertiaryFixed: s.tertiaryFixed,
  tertiaryFixedDim: s.tertiaryFixedDim,
  onTertiaryFixed: s.onTertiaryFixed,
  onTertiaryFixedVariant: s.onTertiaryFixedVariant,
  error: s.error,
  onError: s.onError,
  errorContainer: s.errorContainer,
  onErrorContainer: s.onErrorContainer,
  surface: s.surface,
  onSurface: s.onSurface,
  surfaceDim: s.surfaceDim,
  surfaceBright: s.surfaceBright,
  surfaceContainerLowest: s.surfaceContainerLowest,
  surfaceContainerLow: s.surfaceContainerLow,
  surfaceContainer: s.surfaceContainer,
  surfaceContainerHigh: s.surfaceContainerHigh,
  surfaceContainerHighest: s.surfaceContainerHighest,
  onSurfaceVariant: s.onSurfaceVariant,
  outline: s.outline,
  outlineVariant: s.outlineVariant,
  shadow: s.shadow,
  scrim: s.scrim,
  inverseSurface: s.inverseSurface,
  onInverseSurface: s.onInverseSurface,
  inversePrimary: s.inversePrimary,
  surfaceTint: s.surfaceTint,
);

/// Shifts the error roles of a dynamic scheme towards its primary colour,
/// as dynamic_color recommends for colours that are not part of the palette.
ColorScheme harmonizeScheme(ColorScheme s) => s.copyWith(
  error: s.error.harmonizeWith(s.primary),
  onError: s.onError.harmonizeWith(s.primary),
  errorContainer: s.errorContainer.harmonizeWith(s.primary),
  onErrorContainer: s.onErrorContainer.harmonizeWith(s.primary),
);

/// The app theme. [dynamicScheme] (from the wallpaper or accent colour)
/// replaces the brand scheme; [glass] switches bars, panels and overlays to
/// the liquid-glass style.
ThemeData buildTheme(
  Brightness brightness, {
  ColorScheme? dynamicScheme,
  bool glass = false,
  bool dynamicColorAvailable = false,
}) {
  final scheme = dynamicScheme == null ? brandScheme(brightness) : harmonizeScheme(dynamicScheme);
  final dark = brightness == Brightness.dark;
  var cirrus = CirrusTheme.fallback(brightness).copyWith(glass: glass, dynamicColorAvailable: dynamicColorAvailable);
  if (dynamicScheme != null) cirrus = cirrus.harmonized((c) => c.harmonizeWith(scheme.primary));
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final titleStyle = base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface);
  return base.copyWith(
    visualDensity: VisualDensity.standard,
    extensions: [cirrus],
    appBarTheme: glass
        // Pages put a glass surface behind the bar (`PageScaffold`).
        ? AppBarTheme(
            centerTitle: false,
            elevation: 0,
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            titleTextStyle: titleStyle,
          )
        : AppBarTheme(
            centerTitle: false,
            scrolledUnderElevation: 1,
            backgroundColor: scheme.surface,
            titleTextStyle: titleStyle,
          ),
    dialogTheme: glass
        // Translucent over the frosted backdrop of `showAppDialog`.
        ? DialogThemeData(
            backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: dark ? 0.70 : 0.74),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: GlassRoundedBorder(borderRadius: BorderRadius.circular(28), scheme: scheme),
            barrierColor: Colors.black.withValues(alpha: dark ? 0.32 : 0.16),
          )
        : null,
    bottomSheetTheme: glass
        ? BottomSheetThemeData(modalBarrierColor: Colors.black.withValues(alpha: dark ? 0.32 : 0.16))
        : null,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(isDense: true),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
  );
}
