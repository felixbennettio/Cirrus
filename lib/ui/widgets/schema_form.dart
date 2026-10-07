import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../core/catalog/catalog.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import 'code_editor.dart';
import 'glass.dart';

/// Renders a form for a JSON schema from the API catalog and writes the
/// entered values into [value]. Only fields the user sets are included,
/// so defaults are left to the API.
class SchemaForm extends StatefulWidget {
  const SchemaForm({
    super.key,
    required this.catalog,
    required this.schema,
    required this.value,
    this.onChanged,
    this.hiddenFields = const {},
  });

  final ApiCatalog catalog;
  final Map<String, dynamic>? schema;
  final Map<String, dynamic> value;
  final VoidCallback? onChanged;

  /// Top-level property names not to render (e.g. filled from context).
  final Set<String> hiddenFields;

  @override
  State<SchemaForm> createState() => _SchemaFormState();
}

class _SchemaFormState extends State<SchemaForm> {
  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.catalog.resolve(widget.schema);
    if (s.isEmpty) {
      return Text(context.tr('This request has no documented body schema.', '此请求没有文档化的请求体结构。'));
    }
    return _ObjectFields(
      catalog: widget.catalog,
      schema: s,
      target: widget.value,
      depth: 0,
      onChanged: _changed,
      hidden: widget.hiddenFields,
    );
  }
}

String? _desc(Map<String, dynamic> s) => s['description'] as String? ?? s['title'] as String?;

String _typeOf(Map<String, dynamic> s) {
  final t = s['type'];
  if (t is String) return t;
  if (t is List && t.isNotEmpty) return t.firstWhere((e) => e != 'null', orElse: () => t.first).toString();
  if (s['properties'] != null) return 'object';
  if (s['items'] != null) return 'array';
  if (s['enum'] != null) return 'string';
  return 'unknown';
}

class _ObjectFields extends StatelessWidget {
  const _ObjectFields({
    super.key,
    required this.catalog,
    required this.schema,
    required this.target,
    required this.depth,
    required this.onChanged,
    this.hidden = const {},
  });

  final ApiCatalog catalog;
  final Map<String, dynamic> schema;
  final Map<String, dynamic> target;
  final int depth;
  final VoidCallback onChanged;
  final Set<String> hidden;

  @override
  Widget build(BuildContext context) {
    final variants = (schema['oneOf'] ?? schema['anyOf']) as List?;
    if (variants != null && variants.isNotEmpty && schema['properties'] == null) {
      return _VariantPicker(
        catalog: catalog,
        variants: variants.cast<Map<String, dynamic>>(),
        target: target,
        depth: depth,
        onChanged: onChanged,
      );
    }
    final props = (schema['properties'] as Map<String, dynamic>?) ?? const {};
    final required = ((schema['required'] as List?) ?? const []).cast<String>().toSet();
    if (props.isEmpty) {
      return _JsonField(
        label: context.tr('Value (JSON)', '值（JSON）'),
        description: _desc(schema),
        initial: target.isEmpty ? null : target,
        onChanged: (v) {
          target.clear();
          if (v is Map) target.addAll(Map<String, dynamic>.from(v));
          onChanged();
        },
      );
    }
    final keys = props.keys.where((k) => !hidden.contains(k)).toList()
      ..sort((a, b) {
        final ra = required.contains(a) ? 0 : 1;
        final rb = required.contains(b) ? 0 : 1;
        return ra != rb ? ra - rb : 0;
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final k in keys)
          if (catalog.resolve(props[k] as Map<String, dynamic>)['readOnly'] != true)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _Field(
                catalog: catalog,
                name: k,
                schema: catalog.resolve(props[k] as Map<String, dynamic>),
                required: required.contains(k),
                target: target,
                depth: depth,
                onChanged: onChanged,
              ),
            ),
      ],
    );
  }
}

class _VariantPicker extends StatefulWidget {
  const _VariantPicker({
    required this.catalog,
    required this.variants,
    required this.target,
    required this.depth,
    required this.onChanged,
  });

  final ApiCatalog catalog;
  final List<Map<String, dynamic>> variants;
  final Map<String, dynamic> target;
  final int depth;
  final VoidCallback onChanged;

  @override
  State<_VariantPicker> createState() => _VariantPickerState();
}

class _VariantPickerState extends State<_VariantPicker> {
  int _index = 0;

  String _label(int i) {
    final s = widget.catalog.resolve(widget.variants[i]);
    final title = s['title'] as String?;
    if (title != null) return title;
    final props = (s['properties'] as Map?)?.keys.toList() ?? const [];
    // A const-like discriminator such as {"type": {"enum": ["A"]}}.
    for (final k in const ['type', 'kind', 'action', 'mode', 'name']) {
      final p = (s['properties'] as Map?)?[k];
      if (p is Map) {
        final r = widget.catalog.resolve(Map<String, dynamic>.from(p));
        final e = r['enum'];
        if (e is List && e.length == 1) return '$k = ${e.first}';
      }
    }
    if (props.isNotEmpty) return props.take(3).join(', ');
    final d = s['description'] as String?;
    if (d != null) return d.length > 50 ? '${d.substring(0, 50)}…' : d;
    return 'Variant ${i + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.catalog.resolve(widget.variants[_index]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          initialValue: _index,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.tr('Variant', '类型'),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (var i = 0; i < widget.variants.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(_label(i), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (i) {
            setState(() => _index = i ?? 0);
            widget.target.clear();
            widget.onChanged();
          },
        ),
        const SizedBox(height: 12),
        _ObjectFields(
          key: ValueKey(_index),
          catalog: widget.catalog,
          schema: s,
          target: widget.target,
          depth: widget.depth + 1,
          onChanged: widget.onChanged,
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.catalog,
    required this.name,
    required this.schema,
    required this.required,
    required this.target,
    required this.depth,
    required this.onChanged,
  });

  final ApiCatalog catalog;
  final String name;
  final Map<String, dynamic> schema;
  final bool required;
  final Map<String, dynamic> target;
  final int depth;
  final VoidCallback onChanged;

  String get label => required ? '$name *' : name;

  void _set(Object? v) {
    if (v == null || (v is String && v.isEmpty) || (v is List && v.isEmpty)) {
      target.remove(name);
    } else {
      target[name] = v;
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final type = _typeOf(schema);
    final desc = _desc(schema);
    final current = target[name];
    final enumValues = schema['enum'] as List?;

    if (enumValues != null && enumValues.isNotEmpty) {
      return DropdownButtonFormField<Object?>(
        initialValue: enumValues.contains(current) ? current : null,
        isExpanded: true,
        decoration: _decoration(context, label, desc),
        items: [
          if (!required) DropdownMenuItem<Object?>(value: null, child: Text(context.tr('— not set —', '— 未设置 —'))),
          for (final v in enumValues) DropdownMenuItem<Object?>(value: v, child: Text('$v')),
        ],
        onChanged: _set,
      );
    }

    switch (type) {
      case 'boolean':
        return DropdownButtonFormField<bool?>(
          initialValue: current is bool ? current : null,
          decoration: _decoration(context, label, desc),
          items: [
            DropdownMenuItem<bool?>(value: null, child: Text(context.tr('— not set —', '— 未设置 —'))),
            const DropdownMenuItem<bool?>(value: true, child: Text('true')),
            const DropdownMenuItem<bool?>(value: false, child: Text('false')),
          ],
          onChanged: _set,
        );
      case 'integer':
      case 'number':
        return TextFormField(
          initialValue: current?.toString(),
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: _decoration(context, label, desc, hint: schema['example']?.toString()),
          onChanged: (v) {
            final t = v.trim();
            if (t.isEmpty) return _set(null);
            _set(type == 'integer' ? (int.tryParse(t) ?? num.tryParse(t)) : num.tryParse(t));
          },
        );
      case 'string':
        final long =
            (schema['maxLength'] is int && (schema['maxLength'] as int) > 300) ||
            const [
              'content',
              'script',
              'body',
              'certificate',
              'private_key',
              'expression',
              'query',
              'sql',
              'description',
              'html',
              'value',
            ].contains(name);
        return TextFormField(
          initialValue: current?.toString(),
          minLines: long ? 2 : 1,
          maxLines: long ? 8 : 1,
          style: long ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
          decoration: _decoration(
            context,
            label,
            desc,
            hint: schema['example']?.toString() ?? (schema['format'] == 'date-time' ? '2026-01-01T00:00:00Z' : null),
          ),
          onChanged: _set,
        );
      case 'array':
        final items = catalog.resolve(schema['items'] as Map<String, dynamic>?);
        final itemType = _typeOf(items);
        if (const ['string', 'integer', 'number'].contains(itemType) && items['properties'] == null) {
          return TextFormField(
            initialValue: current is List ? current.join('\n') : null,
            minLines: 1,
            maxLines: 6,
            decoration: _decoration(
              context,
              label,
              desc,
              helper: context.tr('One value per line (or comma separated)', '每行一个值（或用逗号分隔）'),
            ),
            onChanged: (v) {
              final parts = v.split(RegExp(r'[\n,]')).map((e) => e.trim()).where((e) => e.isNotEmpty);
              _set(itemType == 'string' ? parts.toList() : parts.map(num.tryParse).whereType<num>().toList());
            },
          );
        }
        if (depth < 3 && (itemType == 'object' || items['oneOf'] != null || items['anyOf'] != null)) {
          return _ObjectArrayField(
            catalog: catalog,
            name: name,
            label: label,
            description: desc,
            itemSchema: items,
            target: target,
            depth: depth,
            onChanged: onChanged,
          );
        }
        return _JsonField(label: label, description: desc, initial: current, onChanged: _set);
      case 'object':
        final props = schema['properties'] as Map?;
        if (depth < 3 && props != null && props.isNotEmpty) {
          final child = current is Map<String, dynamic> ? current : <String, dynamic>{};
          return _Group(
            label: label,
            description: desc,
            initiallyExpanded: required || current != null,
            child: _ObjectFields(
              catalog: catalog,
              schema: schema,
              target: child,
              depth: depth + 1,
              onChanged: () {
                if (child.isEmpty) {
                  target.remove(name);
                } else {
                  target[name] = child;
                }
                onChanged();
              },
            ),
          );
        }
        return _JsonField(label: label, description: desc, initial: current, onChanged: _set);
      default:
        if (schema['oneOf'] != null || schema['anyOf'] != null) {
          if (depth < 3) {
            final child = current is Map<String, dynamic> ? current : <String, dynamic>{};
            return _Group(
              label: label,
              description: desc,
              initiallyExpanded: required || current != null,
              child: _ObjectFields(
                catalog: catalog,
                schema: schema,
                target: child,
                depth: depth + 1,
                onChanged: () {
                  if (child.isEmpty) {
                    target.remove(name);
                  } else {
                    target[name] = child;
                  }
                  onChanged();
                },
              ),
            );
          }
        }
        return _JsonField(label: label, description: desc, initial: current, onChanged: _set);
    }
  }
}

InputDecoration _decoration(BuildContext context, String label, String? desc, {String? hint, String? helper}) {
  final help = [?helper, ?desc].join('\n');
  return InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: help.isEmpty ? null : help,
    helperMaxLines: 4,
    border: const OutlineInputBorder(),
    isDense: true,
  );
}

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.child, this.description, this.initiallyExpanded = false});

  final String label;
  final String? description;
  final Widget child;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          dense: true,
          title: Text(label),
          subtitle: description == null
              ? null
              : Text(description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          childrenPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          children: [child],
        ),
      ),
    );
  }
}

class _ObjectArrayField extends StatefulWidget {
  const _ObjectArrayField({
    required this.catalog,
    required this.name,
    required this.label,
    required this.itemSchema,
    required this.target,
    required this.depth,
    required this.onChanged,
    this.description,
  });

  final ApiCatalog catalog;
  final String name;
  final String label;
  final String? description;
  final Map<String, dynamic> itemSchema;
  final Map<String, dynamic> target;
  final int depth;
  final VoidCallback onChanged;

  @override
  State<_ObjectArrayField> createState() => _ObjectArrayFieldState();
}

class _ObjectArrayFieldState extends State<_ObjectArrayField> {
  late final List<Map<String, dynamic>> _items = [
    for (final e in (widget.target[widget.name] as List? ?? const []))
      if (e is Map) Map<String, dynamic>.from(e),
  ];
  int _keySeed = 0;
  late final List<int> _keys = [for (var i = 0; i < _items.length; i++) _keySeed++];

  void _sync() {
    if (_items.isEmpty) {
      widget.target.remove(widget.name);
    } else {
      widget.target[widget.name] = _items;
    }
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return _Group(
      label: '${widget.label} (${_items.length})',
      description: widget.description,
      initiallyExpanded: _items.isNotEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _items.length; i++)
            Card(
              key: ValueKey(_keys[i]),
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text('#${i + 1}', style: Theme.of(context).textTheme.labelLarge),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () {
                            setState(() {
                              _items.removeAt(i);
                              _keys.removeAt(i);
                            });
                            _sync();
                          },
                        ),
                      ],
                    ),
                    _ObjectFields(
                      catalog: widget.catalog,
                      schema: widget.itemSchema,
                      target: _items[i],
                      depth: widget.depth + 1,
                      onChanged: _sync,
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: Text(context.tr('Add item', '添加一项')),
              onPressed: () {
                setState(() {
                  _items.add(<String, dynamic>{});
                  _keys.add(_keySeed++);
                });
                _sync();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _JsonField extends StatefulWidget {
  const _JsonField({required this.label, required this.onChanged, this.description, this.initial});

  final String label;
  final String? description;
  final Object? initial;
  final ValueChanged<Object?> onChanged;

  @override
  State<_JsonField> createState() => _JsonFieldState();
}

class _JsonFieldState extends State<_JsonField> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: widget.initial == null ? null : prettyJson(widget.initial),
      minLines: 2,
      maxLines: 10,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: _decoration(context, widget.label, widget.description, helper: 'JSON').copyWith(errorText: _error),
      onChanged: (v) {
        if (v.trim().isEmpty) {
          setState(() => _error = null);
          widget.onChanged(null);
          return;
        }
        try {
          final parsed = jsonDecode(v);
          setState(() => _error = null);
          widget.onChanged(parsed);
        } catch (_) {
          setState(() => _error = context.tr('Invalid JSON', 'JSON 格式错误'));
        }
      },
    );
  }
}

/// Dialog with a schema-generated form and a raw JSON tab. Returns the
/// body to send, or `null` when cancelled.
Future<Map<String, dynamic>?> showSchemaEditor(
  BuildContext context, {
  required String title,
  required ApiCatalog catalog,
  required Map<String, dynamic>? schema,
  Map<String, dynamic>? initial,
  String? submitLabel,
  Set<String> hiddenFields = const {},
}) {
  return showAppDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => _SchemaEditorDialog(
      title: title,
      catalog: catalog,
      schema: schema,
      initial: initial,
      submitLabel: submitLabel,
      hiddenFields: hiddenFields,
    ),
  );
}

class _SchemaEditorDialog extends StatefulWidget {
  const _SchemaEditorDialog({
    required this.title,
    required this.catalog,
    required this.schema,
    this.initial,
    this.submitLabel,
    this.hiddenFields = const {},
  });

  final String title;
  final ApiCatalog catalog;
  final Map<String, dynamic>? schema;
  final Map<String, dynamic>? initial;
  final String? submitLabel;
  final Set<String> hiddenFields;

  @override
  State<_SchemaEditorDialog> createState() => _SchemaEditorDialogState();
}

class _SchemaEditorDialogState extends State<_SchemaEditorDialog> {
  late Map<String, dynamic> _value = _clone(widget.initial ?? <String, dynamic>{});
  late final CodeLineEditingController _json = CodeLineEditingController.fromText(prettyJson(_value));
  bool _jsonMode = false;
  String? _jsonError;
  int _formGeneration = 0;

  static Map<String, dynamic> _clone(Map<String, dynamic> m) => jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _toJson() {
    _json.text = prettyJson(_value);
    setState(() => _jsonMode = true);
  }

  bool _fromJson() {
    try {
      final v = jsonDecode(_json.text.trim().isEmpty ? '{}' : _json.text);
      if (v is! Map) throw const FormatException();
      setState(() {
        _value = Map<String, dynamic>.from(v);
        _jsonError = null;
        _jsonMode = false;
        _formGeneration++;
      });
      return true;
    } catch (_) {
      setState(() => _jsonError = context.tr('Invalid JSON object', 'JSON 对象格式错误'));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760, maxHeight: size.height * 0.92),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge)),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: false, label: Text(context.tr('Form', '表单'))),
                      const ButtonSegment(value: true, label: Text('JSON')),
                    ],
                    selected: {_jsonMode},
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    onSelectionChanged: (s) => s.first ? _toJson() : _fromJson(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: _jsonMode
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: size.height * 0.55,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: CodeEditorField(controller: _json, language: 'json'),
                            ),
                          ),
                          if (_jsonError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(_jsonError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                            ),
                        ],
                      )
                    : SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: SchemaForm(
                            key: ValueKey(_formGeneration),
                            catalog: widget.catalog,
                            schema: widget.schema,
                            value: _value,
                            hiddenFields: widget.hiddenFields,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel', '取消'))),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      if (_jsonMode && !_fromJson()) return;
                      Navigator.pop(context, _value);
                    },
                    child: Text(widget.submitLabel ?? context.tr('Save', '保存')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
