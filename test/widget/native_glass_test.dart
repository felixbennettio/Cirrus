import 'package:cirrus/app/theme.dart';
import 'package:cirrus/ui/widgets/glass.dart';
import 'package:cirrus/ui/widgets/native_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// On iOS and macOS glass surfaces are backed by the system's glass view.
void main() {
  final created = <Map<Object?, Object?>>[];

  setUp(() {
    debugNativeGlassOverride = true;
    created.clear();
    var id = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        if (call.method == 'create') {
          final args = call.arguments as Map<Object?, Object?>;
          final params = const StandardMessageCodec().decodeMessage(ByteData.sublistView(args['params']! as Uint8List));
          created.add(params as Map<Object?, Object?>);
          return id++;
        }
        return null;
      },
    );
  });

  tearDown(() {
    debugNativeGlassOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
  });

  Widget host(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
    theme: buildTheme(brightness, glass: true),
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('a glass panel is the system glass view under the content', (tester) async {
    await tester.pumpWidget(
      host(
        const SizedBox(width: 200, height: 80, child: GlassSurface(radius: 20, child: Text('content'))),
        brightness: Brightness.dark,
      ),
    );
    expect(find.text('content'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    final view = tester.widget<UiKitView>(find.byType(UiKitView));
    expect(view.viewType, NativeGlassView.viewType);
    expect(view.hitTestBehavior, PlatformViewHitTestBehavior.transparent);
    expect(tester.getSize(find.byType(UiKitView)), const Size(200, 80));
    expect(created.single, {'cornerRadius': 20.0, 'dark': true, 'kind': 'panel'});
  });

  testWidgets('app bars use the bar material', (tester) async {
    await tester.pumpWidget(host(const SizedBox(width: 300, height: 56, child: GlassSurface(edge: GlassEdge.bottom))));
    expect(created.single, {'cornerRadius': 0.0, 'dark': false, 'kind': 'bar'});
  });

  testWidgets('dialogs get the system glass exactly behind their surface', (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppDialog<void>(
              context: context,
              builder: (_) => const AlertDialog(title: Text('Title'), content: Text('Body')),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final surface = find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first;
    expect(tester.getRect(find.byType(UiKitView)), tester.getRect(surface));
    expect(created.single['cornerRadius'], 28.0);
    // The dialog itself is clear so the glass shows through, and nothing
    // blurs the page behind it.
    expect(tester.widget<Material>(surface).color, Colors.transparent);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
