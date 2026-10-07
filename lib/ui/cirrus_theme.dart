import 'package:flutter/material.dart';

/// App-specific theme values: the liquid-glass switch, whether the platform
/// offers dynamic colour, and semantic status colours (harmonised with the
/// primary colour when the scheme is dynamic).
@immutable
class CirrusTheme extends ThemeExtension<CirrusTheme> {
  const CirrusTheme({
    required this.glass,
    required this.dynamicColorAvailable,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  /// The brand palette for [brightness], glass off.
  factory CirrusTheme.fallback(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return CirrusTheme(
      glass: false,
      dynamicColorAvailable: false,
      successContainer: dark ? const Color(0xFF1E3A2A) : const Color(0xFFDDF4E4),
      onSuccessContainer: dark ? const Color(0xFF8BE0A8) : const Color(0xFF16683A),
      warningContainer: dark ? const Color(0xFF3D3214) : const Color(0xFFFFF1CC),
      onWarningContainer: dark ? const Color(0xFFF5CF6A) : const Color(0xFF7A5A00),
    );
  }

  static CirrusTheme of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<CirrusTheme>() ?? CirrusTheme.fallback(theme.brightness);
  }

  /// Translucent, blurred surfaces for bars, panels and overlays.
  final bool glass;

  /// The platform supplies a dynamic scheme (wallpaper or accent colour).
  final bool dynamicColorAvailable;

  final Color successContainer;
  final Color onSuccessContainer;
  final Color warningContainer;
  final Color onWarningContainer;

  CirrusTheme harmonized(Color Function(Color) shift) => copyWith(
    successContainer: shift(successContainer),
    onSuccessContainer: shift(onSuccessContainer),
    warningContainer: shift(warningContainer),
    onWarningContainer: shift(onWarningContainer),
  );

  @override
  CirrusTheme copyWith({
    bool? glass,
    bool? dynamicColorAvailable,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warningContainer,
    Color? onWarningContainer,
  }) => CirrusTheme(
    glass: glass ?? this.glass,
    dynamicColorAvailable: dynamicColorAvailable ?? this.dynamicColorAvailable,
    successContainer: successContainer ?? this.successContainer,
    onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
    warningContainer: warningContainer ?? this.warningContainer,
    onWarningContainer: onWarningContainer ?? this.onWarningContainer,
  );

  @override
  CirrusTheme lerp(covariant CirrusTheme? other, double t) {
    if (other == null) return this;
    return CirrusTheme(
      glass: t < 0.5 ? glass : other.glass,
      dynamicColorAvailable: t < 0.5 ? dynamicColorAvailable : other.dynamicColorAvailable,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer: Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer: Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
    );
  }
}
