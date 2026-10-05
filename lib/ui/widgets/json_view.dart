import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import 'code_editor.dart';
import 'feedback.dart';

/// Collapsible tree view of decoded JSON.
class JsonTreeView extends StatelessWidget {
  const JsonTreeView(this.data, {super.key, this.initiallyExpandedDepth = 2, this.shrinkWrap = false});

  final Object? data;
  final int initiallyExpandedDepth;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[_JsonNode(name: null, value: data, depth: 0, expandDepth: initiallyExpandedDepth)];
    if (shrinkWrap) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
      ),
    );
  }
}

class _JsonNode extends StatefulWidget {
  const _JsonNode({required this.name, required this.value, required this.depth, required this.expandDepth});

  final String? name;
  final Object? value;
  final int depth;
  final int expandDepth;

  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  late bool _open = widget.depth < widget.expandDepth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = widget.value;
    final keyStyle = TextStyle(fontFamily: 'monospace', fontSize: 13, color: scheme.primary);
    final indent = EdgeInsets.only(left: widget.depth == 0 ? 0 : 16);
    final nameSpan = widget.name == null ? null : TextSpan(text: '${widget.name}: ', style: keyStyle);

    if (v is Map || v is List) {
      final isMap = v is Map;
      final entries = isMap
          ? (v).entries.map((e) => MapEntry(e.key.toString(), e.value)).toList()
          : [for (var i = 0; i < (v as List).length; i++) MapEntry('[$i]', v[i])];
      final summary = isMap ? '{${entries.length}}' : '[${entries.length}]';
      return Padding(
        padding: indent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              onLongPress: () => copyText(context, prettyJson(v)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16),
                    Text.rich(
                      TextSpan(
                        children: [
                          ?nameSpan,
                          TextSpan(
                            text: summary,
                            style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: scheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_open)
              for (final e in entries)
                _JsonNode(name: e.key, value: e.value, depth: widget.depth + 1, expandDepth: widget.expandDepth),
          ],
        ),
      );
    }
    final (text, color) = switch (v) {
      null => ('null', scheme.outline),
      final String s => (jsonEncode(s), const Color(0xFF2E8B57)),
      final bool b => (b.toString(), const Color(0xFFD9822B)),
      final num n => (n.toString(), const Color(0xFF3B82F6)),
      _ => (v.toString(), scheme.onSurface),
    };
    return Padding(
      padding: indent.add(const EdgeInsets.only(left: 16, top: 1, bottom: 1)),
      child: GestureDetector(
        onLongPress: () => copyText(context, v is String ? v : text),
        child: SelectableText.rich(
          TextSpan(
            children: [
              ?nameSpan,
              TextSpan(
                text: text,
                style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tabbed JSON viewer: tree or raw text, with copy.
class JsonViewer extends StatefulWidget {
  const JsonViewer(this.data, {super.key});

  final Object? data;

  @override
  State<JsonViewer> createState() => _JsonViewerState();
}

class _JsonViewerState extends State<JsonViewer> {
  bool _raw = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.data is String ? widget.data as String : prettyJson(widget.data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(context.tr('Tree', '树形')),
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(context.tr('Raw', '原始')),
                  icon: const Icon(Icons.code, size: 16),
                ),
              ],
              selected: {_raw},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (s) => setState(() => _raw = s.first),
            ),
            const Spacer(),
            IconButton(
              tooltip: context.tr('Copy', '复制'),
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => copyText(context, text),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _raw || widget.data is String
                  ? CodeView(text: text, language: widget.data is String ? 'plaintext' : 'json')
                  : JsonTreeView(widget.data),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows any JSON in a dialog/bottom sheet.
Future<void> showJsonDialog(BuildContext context, Object? data, {String? title}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title ?? 'JSON', style: Theme.of(ctx).textTheme.titleMedium)),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(child: JsonViewer(data)),
            ],
          ),
        ),
      ),
    ),
  );
}
