import 'package:cirrus/app/theme.dart';
import 'package:cirrus/ui/cirrus_theme.dart';
import 'package:cirrus/ui/widgets/glass.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui show ColorScheme;

Widget _host(
  Widget child, {
  required bool glass,
  Brightness brightness = Brightness.light,
  bool highContrast = false,
}) => MaterialApp(
  theme: buildTheme(brightness, glass: glass),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(highContrast: highContrast),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

const _panel = SizedBox(
  width: 200,
  height: 80,
  child: GlassSurface(radius: 20, shadow: true, child: Center(child: Text('content'))),
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('GlassSurface is a blurred, translucent panel with glass on ($brightness)', (tester) async {
      await tester.pumpWidget(_host(_panel, glass: true, brightness: brightness));
      expect(find.text('content'), findsOneWidget);
      expect(find.descendant(of: find.byType(GlassSurface), matching: find.byType(BackdropFilter)), findsOneWidget);
      expect(find.descendant(of: find.byType(GlassSurface), matching: find.byType(ClipRRect)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('GlassSurface falls back to an opaque surface with glass off ($brightness)', (tester) async {
      await tester.pumpWidget(_host(_panel, glass: false, brightness: brightness));
      expect(find.text('content'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      final box = tester.widget<DecoratedBox>(
        find.descendant(of: find.byType(GlassSurface), matching: find.byType(DecoratedBox)).first,
      );
      expect((box.decoration as BoxDecoration).color!.a, 1);
    });
  }

  testWidgets('high contrast turns glass off', (tester) async {
    await tester.pumpWidget(_host(_panel, glass: true, highContrast: true));
    expect(find.text('content'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('`enabled` overrides the theme', (tester) async {
    await tester.pumpWidget(_host(const GlassSurface(enabled: true, child: Text('x')), glass: false));
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  for (final glass in [true, false]) {
    testWidgets('showAppDialog ${glass ? 'frosts' : 'does not frost'} the backdrop', (tester) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(title: Text('Hello')),
              ),
              child: const Text('open'),
            ),
          ),
          glass: glass,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.byType(FrostedBackdrop), glass ? findsOneWidget : findsNothing);
      final bg = Theme.of(tester.element(find.text('Hello'))).dialogTheme.backgroundColor;
      if (glass) {
        expect(bg!.a, lessThan(1));
      } else {
        expect(bg, isNull);
      }
      // Dismissing by tapping outside still works.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Hello'), findsNothing);
    });
  }

  test('the brand scheme and desktop accent schemes have grey surfaces', () {
    bool grey(Color c) => c.r == c.g && c.g == c.b;
    for (final b in Brightness.values) {
      final brand = brandScheme(b);
      for (final c in [brand.surface, brand.surfaceContainerLow, brand.surfaceContainerHighest, brand.outlineVariant]) {
        expect(grey(c), isTrue, reason: '$b $c');
      }
      expect(grey(brand.primary), isFalse);
    }
    final accent = schemeFromMaterialUi(mui.ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)));
    expect(grey(accent.surfaceContainerLow), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final mac = buildTheme(Brightness.light, dynamicScheme: accent).colorScheme;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final android = buildTheme(Brightness.light, dynamicScheme: accent).colorScheme;
    debugDefaultTargetPlatformOverride = null;
    expect(grey(mac.surfaceContainerLow), isTrue);
    expect(mac.primary, accent.primary);
    expect(android.surfaceContainerLow, accent.surfaceContainerLow);
  });

  test('dynamic schemes are copied role by role and harmonise the status colours', () {
    final source = mui.ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0));
    final scheme = schemeFromMaterialUi(source);
    expect(scheme.primary, source.primary);
    expect(scheme.surfaceContainerLow, source.surfaceContainerLow);
    expect(scheme.onTertiaryContainer, source.onTertiaryContainer);
    expect(scheme.brightness, Brightness.light);

    final brand = buildTheme(Brightness.light);
    final dynamicTheme = buildTheme(Brightness.light, dynamicScheme: scheme, dynamicColorAvailable: true);
    expect(dynamicTheme.colorScheme.primary, scheme.primary);
    expect(brand.colorScheme.primary, isNot(scheme.primary));
    final brandStatus = brand.extension<CirrusTheme>()!;
    final dynamicStatus = dynamicTheme.extension<CirrusTheme>()!;
    expect(brandStatus.successContainer, CirrusTheme.fallback(Brightness.light).successContainer);
    expect(dynamicStatus.successContainer, isNot(brandStatus.successContainer));
    expect(dynamicStatus.dynamicColorAvailable, isTrue);
  });
}
