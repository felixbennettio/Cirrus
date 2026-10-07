import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../cirrus_theme.dart';
import 'native_glass.dart';

/// Whether glass surfaces render as glass here: the theme has it on and the
/// platform does not ask for high contrast.
bool glassActive(BuildContext context) =>
    CirrusTheme.of(context).glass && !(MediaQuery.maybeHighContrastOf(context) ?? false);

/// Which edges of a [GlassSurface] get the hairline.
enum GlassEdge {
  /// The whole outline (floating panels, pills, sheets).
  all,

  /// Only the bottom edge (app bars).
  bottom,

  /// Only the top edge (bars docked at the bottom).
  top,

  none,
}

/// A "liquid glass" material. On iOS and macOS it is Apple's own
/// ([NativeGlassView]: Liquid Glass on iOS 26 / macOS 26). Elsewhere the
/// content behind is blurred, tinted with a translucent surface colour and
/// lit by a faint specular gradient, inside a hairline that is bright at the
/// top and fades lower.
///
/// When glass is off (setting, or high contrast) it is a plain opaque
/// surface, so callers need not branch. Never nest one inside another, and
/// keep them out of list items: each is a backdrop blur.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    this.child,
    this.radius = 0,
    this.borderRadius,
    this.edge = GlassEdge.all,
    this.blur = 24,
    this.shadow = false,
    this.tint,
    this.opaqueColor,
    this.enabled,
  });

  final Widget? child;

  /// Corner radius; see [borderRadius] for per-corner shapes.
  final double radius;
  final BorderRadius? borderRadius;
  final GlassEdge edge;

  /// Blur sigma of the backdrop.
  final double blur;

  /// A soft drop shadow outside the shape (floating panels).
  final bool shadow;

  /// Fill colour before transparency; defaults to `colorScheme.surface`.
  final Color? tint;

  /// Colour of the opaque fallback; defaults to `colorScheme.surfaceContainer`.
  final Color? opaqueColor;

  /// Overrides [glassActive].
  final bool? enabled;

  BorderRadius get _radius => borderRadius ?? BorderRadius.circular(radius);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final br = _radius;
    final rounded = br != BorderRadius.zero;
    final content = child ?? const SizedBox.expand();
    if (!(enabled ?? glassActive(context))) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: opaqueColor ?? scheme.surfaceContainer,
          borderRadius: rounded ? br : null,
          boxShadow: shadow ? [BoxShadow(color: scheme.shadow.withValues(alpha: 0.12), blurRadius: 12)] : null,
        ),
        child: rounded ? ClipRRect(borderRadius: br, child: content) : content,
      );
    }
    if (nativeGlassAvailable) {
      final r = [
        br.topLeft,
        br.topRight,
        br.bottomLeft,
        br.bottomRight,
      ].map((c) => c.x).reduce((a, b) => a > b ? a : b);
      return Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: NativeGlassView(
              cornerRadius: r,
              kind: edge == GlassEdge.all ? NativeGlassKind.panel : NativeGlassKind.bar,
            ),
          ),
          if (rounded) ClipRRect(borderRadius: br, child: content) else content,
        ],
      );
    }
    final fill = (tint ?? scheme.surface).withValues(alpha: dark ? 0.45 : 0.55);
    Widget glass = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: CustomPaint(
        painter: _GlassFillPainter(fill: fill, dark: dark),
        foregroundPainter: edge == GlassEdge.none
            ? null
            : _GlassEdgePainter(edge: edge, borderRadius: br, scheme: scheme),
        child: content,
      ),
    );
    glass = rounded ? ClipRRect(borderRadius: br, child: glass) : ClipRect(child: glass);
    if (shadow) {
      glass = CustomPaint(
        painter: _GlassShadowPainter(borderRadius: br, dark: dark),
        child: glass,
      );
    }
    return glass;
  }
}

class _GlassFillPainter extends CustomPainter {
  _GlassFillPainter({required this.fill, required this.dark});

  final Color fill;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = fill);
    // Specular sheen: a little light catching the top of the glass.
    final sheen = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withValues(alpha: dark ? 0.06 : 0.16),
        Colors.white.withValues(alpha: 0),
      ],
    );
    canvas.drawRect(rect, Paint()..shader = sheen.createShader(rect));
  }

  @override
  bool shouldRepaint(_GlassFillPainter old) => old.fill != fill || old.dark != dark;
}

/// The gradient hairline of glass: bright at the top, fading lower.
List<Color> glassHairlineColors(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return [
    Colors.white.withValues(alpha: dark ? 0.30 : 0.95),
    Colors.white.withValues(alpha: dark ? 0.08 : 0.35),
    scheme.outlineVariant.withValues(alpha: dark ? 0.30 : 0.60),
  ];
}

void paintGlassHairline(Canvas canvas, RRect rrect, ColorScheme scheme, {double width = 0.8}) {
  final rect = rrect.outerRect;
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: glassHairlineColors(scheme),
      stops: const [0, 0.45, 1],
    ).createShader(rect);
  canvas.drawRRect(rrect.deflate(width / 2), paint);
}

class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter({required this.edge, required this.borderRadius, required this.scheme});

  final GlassEdge edge;
  final BorderRadius borderRadius;
  final ColorScheme scheme;

  static const _width = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final colors = glassHairlineColors(scheme);
    switch (edge) {
      case GlassEdge.all:
        paintGlassHairline(canvas, borderRadius.toRRect(rect), scheme, width: _width);
      case GlassEdge.bottom:
        final y = size.height - _width / 2;
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..strokeWidth = _width
            ..color = colors.last,
        );
      case GlassEdge.top:
        canvas.drawLine(
          const Offset(0, _width / 2),
          Offset(size.width, _width / 2),
          Paint()
            ..strokeWidth = _width
            ..color = colors.first,
        );
      case GlassEdge.none:
        break;
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.edge != edge || old.borderRadius != borderRadius || old.scheme != scheme;
}

/// A drop shadow drawn only outside the shape, so it never darkens the
/// translucent glass itself.
class _GlassShadowPainter extends CustomPainter {
  _GlassShadowPainter({required this.borderRadius, required this.dark});

  final BorderRadius borderRadius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = borderRadius.toRRect(Offset.zero & size);
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect((Offset.zero & size).inflate(48)),
        Path()..addRRect(rrect),
      ),
    );
    canvas.drawRRect(
      rrect.shift(const Offset(0, 6)),
      Paint()
        ..color = Colors.black.withValues(alpha: dark ? 0.40 : 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadowPainter old) => old.borderRadius != borderRadius || old.dark != dark;
}

/// The shape of glass dialogs: rounded, with the gradient hairline.
class GlassRoundedBorder extends RoundedRectangleBorder {
  const GlassRoundedBorder({super.borderRadius, required this.scheme});

  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    paintGlassHairline(canvas, borderRadius.resolve(textDirection).toRRect(rect), scheme);
  }

  @override
  bool operator ==(Object other) => other is GlassRoundedBorder && other.scheme == scheme && super == other;

  @override
  int get hashCode => Object.hash(super.hashCode, scheme);
}

/// The softly tinted page background shown behind glass. It only varies
/// vertically, so neighbouring panels of the same height line up seamlessly.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(scheme.primaryContainer.withValues(alpha: dark ? 0.28 : 0.40), scheme.surface),
            scheme.surface,
            Color.alphaBlend(scheme.tertiaryContainer.withValues(alpha: dark ? 0.22 : 0.32), scheme.surface),
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
      child: child,
    );
  }
}

/// Blurs everything behind a dialog, in step with the route's animation.
/// Together with the translucent glass dialog theme this gives frosted-glass
/// dialogs without touching each dialog.
class FrostedBackdrop extends StatelessWidget {
  const FrostedBackdrop({super.key, required this.child, this.sigma = 18});

  final Widget child;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) {
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: child,
      );
    }
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final s = sigma * animation.value;
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: s, sigmaY: s),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// [showDialog] that turns into a frosted-glass dialog when glass is on.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final glass = glassActive(context);
  if (glass && nativeGlassAvailable) {
    // Apple's glass behind the dialog itself; the page behind is only dimmed,
    // as with system alerts.
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      builder: (ctx) => NativeGlassDialog(child: Builder(builder: builder)),
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    // The blur must cover the whole screen, so the safe area goes inside it.
    useSafeArea: useSafeArea && !glass,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    builder: !glass
        ? builder
        : (ctx) => FrostedBackdrop(
            child: useSafeArea ? SafeArea(child: Builder(builder: builder)) : Builder(builder: builder),
          ),
  );
}

/// [showModalBottomSheet] with a glass sheet when glass is on.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) {
  final glass = glassActive(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: glass ? Colors.transparent : null,
    elevation: glass ? 0 : null,
    builder: !glass
        ? builder
        : (ctx) => GlassSurface(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            blur: 30,
            child: Builder(builder: builder),
          ),
  );
}

/// Marks a page body that pads its scroll content by the [MediaQuery]
/// insets, so it can scroll behind glass bars (see `PageScaffold`).
abstract interface class InsetAwareBody {}
