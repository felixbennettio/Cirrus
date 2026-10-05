import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/dns.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

final _languages = {
  'javascript': CodeHighlightThemeMode(mode: langJavascript),
  'typescript': CodeHighlightThemeMode(mode: langTypescript),
  'json': CodeHighlightThemeMode(mode: langJson),
  'sql': CodeHighlightThemeMode(mode: langSql),
  'yaml': CodeHighlightThemeMode(mode: langYaml),
  'graphql': CodeHighlightThemeMode(mode: langGraphql),
  'bash': CodeHighlightThemeMode(mode: langBash),
  'xml': CodeHighlightThemeMode(mode: langXml),
  'dns': CodeHighlightThemeMode(mode: langDns),
  'python': CodeHighlightThemeMode(mode: langPython),
  'rust': CodeHighlightThemeMode(mode: langRust),
  'plaintext': CodeHighlightThemeMode(mode: langPlaintext),
};

/// Guesses an editor language from a file name or MIME type.
String languageFor(String? nameOrType) {
  final s = (nameOrType ?? '').toLowerCase();
  if (s.endsWith('.ts') || s.endsWith('.mts') || s.contains('typescript')) return 'typescript';
  if (s.endsWith('.js') || s.endsWith('.mjs') || s.endsWith('.cjs') || s.contains('javascript')) {
    return 'javascript';
  }
  if (s.endsWith('.json') || s.contains('json')) return 'json';
  if (s.endsWith('.sql')) return 'sql';
  if (s.endsWith('.yaml') || s.endsWith('.yml')) return 'yaml';
  if (s.endsWith('.py') || s.contains('python')) return 'python';
  if (s.endsWith('.rs')) return 'rust';
  if (s.endsWith('.html') || s.endsWith('.xml') || s.endsWith('.svg') || s.contains('html') || s.contains('xml')) {
    return 'xml';
  }
  if (s.endsWith('.sh')) return 'bash';
  if (s.endsWith('.graphql') || s.endsWith('.gql')) return 'graphql';
  return 'plaintext';
}

CodeEditorStyle _style(BuildContext context, String language) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final scheme = Theme.of(context).colorScheme;
  return CodeEditorStyle(
    fontSize: 13,
    fontFamily: 'monospace',
    backgroundColor: dark ? const Color(0xFF1E2127) : const Color(0xFFFAFAFA),
    cursorColor: scheme.primary,
    selectionColor: scheme.primary.withValues(alpha: 0.25),
    codeTheme: CodeHighlightTheme(
      languages: {language: _languages[language] ?? _languages['plaintext']!},
      theme: dark ? atomOneDarkTheme : atomOneLightTheme,
    ),
  );
}

Widget _indicator(
  BuildContext context,
  CodeLineEditingController editingController,
  CodeChunkController chunkController,
  CodeIndicatorValueNotifier notifier,
) {
  return Row(
    children: [
      DefaultCodeLineNumber(controller: editingController, notifier: notifier),
      DefaultCodeChunkIndicator(width: 18, controller: chunkController, notifier: notifier),
    ],
  );
}

/// Editable code editor with syntax highlighting and line numbers.
class CodeEditorField extends StatelessWidget {
  const CodeEditorField({
    super.key,
    required this.controller,
    this.language = 'javascript',
    this.readOnly = false,
    this.wordWrap = false,
    this.hint,
    this.onChanged,
    this.lineNumbers = true,
  });

  final CodeLineEditingController controller;
  final String language;
  final bool readOnly;
  final bool wordWrap;
  final String? hint;
  final ValueChanged<CodeLineEditingValue>? onChanged;
  final bool lineNumbers;

  @override
  Widget build(BuildContext context) {
    return CodeEditor(
      controller: controller,
      readOnly: readOnly,
      wordWrap: wordWrap,
      hint: hint,
      onChanged: onChanged,
      style: _style(context, language),
      indicatorBuilder: lineNumbers ? _indicator : null,
      padding: const EdgeInsets.only(left: 4, top: 8, right: 8, bottom: 8),
    );
  }
}

/// Read-only highlighted text.
class CodeView extends StatefulWidget {
  const CodeView({super.key, required this.text, this.language = 'plaintext', this.wordWrap = false});

  final String text;
  final String language;
  final bool wordWrap;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  late final CodeLineEditingController _controller = CodeLineEditingController.fromText(widget.text);

  @override
  void didUpdateWidget(covariant CodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CodeEditorField(controller: _controller, language: widget.language, readOnly: true, wordWrap: widget.wordWrap);
}
