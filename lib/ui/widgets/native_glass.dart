import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Whether glass comes from the system: on iOS and macOS the material behind
/// glass surfaces is Apple's own (Liquid Glass on iOS 26 / macOS 26, the
/// system blur materials before), drawn by a native view under the Flutter
/// content. Elsewhere [GlassSurface] draws its own.
bool get nativeGlassAvailable => _nativeGlassOverride ?? (!kIsWeb && (Platform.isIOS || Platform.isMacOS));

bool? _nativeGlassOverride;

/// Forces [nativeGlassAvailable] (tests).
@visibleForTesting
set debugNativeGlassOverride(bool? value) => _nativeGlassOverride = value;

/// What a native glass view backs: bars get the system's bar material where
/// the OS has no Liquid Glass, floating panels the regular one.
enum NativeGlassKind { bar, panel }

/// Apple's glass material, sized by its parent. It takes no input: pointer
/// events go to the Flutter content above and behind it.
///
/// Native side: `ios/Runner/AppDelegate.swift`, `macos/Runner/MainFlutterWindow.swift`.
class NativeGlassView extends StatelessWidget {
  const NativeGlassView({super.key, this.cornerRadius = 0, this.kind = NativeGlassKind.panel});

  static const viewType = 'io.felixbennett.cirrus/glass';

  final double cornerRadius;
  final NativeGlassKind kind;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final params = <String, Object>{'cornerRadius': cornerRadius, 'dark': dark, 'kind': kind.name};
    // The native view reads these once, so a change makes a new one.
    final key = ValueKey('$cornerRadius/$dark/${kind.name}');
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return AppKitView(
        key: key,
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      );
    }
    return UiKitView(
      key: key,
      viewType: viewType,
      creationParams: params,
      creationParamsCodec: const StandardMessageCodec(),
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    );
  }
}

/// Puts a [NativeGlassView] behind the surface of the dialog in [child]
/// (its outermost [Material]), wherever the dialog lays it out.
class NativeGlassDialog extends StatefulWidget {
  const NativeGlassDialog({super.key, required this.child, this.cornerRadius = 28});

  final Widget child;
  final double cornerRadius;

  @override
  State<NativeGlassDialog> createState() => _NativeGlassDialogState();
}

class _NativeGlassDialogState extends State<NativeGlassDialog> {
  Rect? _rect;

  void _onRect(Rect rect) {
    if (mounted && rect != _rect) setState(() => _rect = rect);
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      if (_rect != null)
        Positioned.fromRect(
          rect: _rect!,
          child: NativeGlassView(cornerRadius: widget.cornerRadius),
        ),
      _SurfaceTracker(onRect: _onRect, child: widget.child),
    ],
  );
}

class _SurfaceTracker extends SingleChildRenderObjectWidget {
  const _SurfaceTracker({required this.onRect, super.child});

  final ValueChanged<Rect> onRect;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSurfaceTracker(onRect);

  @override
  void updateRenderObject(BuildContext context, _RenderSurfaceTracker renderObject) => renderObject.onRect = onRect;
}

/// Reports where the first [RenderPhysicalShape] below it (a dialog's
/// [Material]) is, each time it paints: a change in the dialog's size or
/// position repaints it, as no repaint boundary lies in between.
class _RenderSurfaceTracker extends RenderProxyBox {
  _RenderSurfaceTracker(this.onRect);

  ValueChanged<Rect> onRect;
  Rect? _last;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _measure();
  }

  RenderPhysicalShape? _find(RenderObject node) {
    if (node is RenderPhysicalShape) return node;
    RenderPhysicalShape? found;
    node.visitChildren((c) => found ??= _find(c));
    return found;
  }

  void _measure() {
    final shape = child == null ? null : _find(child!);
    if (shape == null || !shape.hasSize) return;
    final rect = MatrixUtils.transformRect(shape.getTransformTo(this), Offset.zero & shape.size);
    if (rect == _last) return;
    _last = rect;
    SchedulerBinding.instance.addPostFrameCallback((_) => onRect(rect));
  }
}
