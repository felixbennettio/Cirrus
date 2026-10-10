import 'dart:async';

import 'package:cirrus/app/theme.dart';
import 'package:cirrus/ui/widgets/glass.dart';
import 'package:flutter/material.dart';

/// Glass surfaces over colourful scrolling content, to see the system glass
/// on iOS and macOS (`.forgejo/workflows/glass-preview.yml`):
/// `flutter run -t tool/glass_preview.dart [--dart-define=PREVIEW_DARK=true]`.
/// A dialog opens after a few seconds.
void main() => runApp(const _Preview());

const _dark = bool.fromEnvironment('PREVIEW_DARK');

class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(_dark ? Brightness.dark : Brightness.light, glass: true),
    home: const _Page(),
  );
}

class _Page extends StatefulWidget {
  const _Page();

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final _scroll = ScrollController(initialScrollOffset: 60);

  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      showAppDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Liquid Glass'),
          content: const Text('The dialog, the bar and the panel are the system’s glass material.'),
          actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    const colors = [Colors.deepOrange, Colors.indigo, Colors.teal, Colors.pink, Colors.amber, Colors.blue];
    return Scaffold(
      body: AmbientBackground(
        child: Stack(
          children: [
            ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(16, top + 72, 16, 16),
              itemCount: 24,
              itemBuilder: (context, i) => Container(
                height: 96,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(colors: [colors[i % 6], colors[(i + 2) % 6]]),
                ),
                child: Text(
                  'Cirrus 卷云 · row $i',
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: top + 56,
              child: GlassSurface(
                edge: GlassEdge.bottom,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, top, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Glass app bar', style: Theme.of(context).textTheme.titleLarge),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 40,
              height: 120,
              child: GlassSurface(
                radius: 28,
                child: Center(child: Text('Floating glass panel', style: Theme.of(context).textTheme.titleMedium)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
