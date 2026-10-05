import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cf_client.dart';
import '../../core/api/cf_exception.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';
import 'phases.dart';

/// Rules of one phase entry point (zone or account level).
class RulesetPhaseView extends ConsumerStatefulWidget {
  const RulesetPhaseView({super.key, required this.meta, required this.basePath});

  final PhaseMeta meta;

  /// `/zones/{id}` or `/accounts/{id}`.
  final String basePath;

  @override
  ConsumerState<RulesetPhaseView> createState() => _RulesetPhaseViewState();
}

class _RulesetPhaseViewState extends ConsumerState<RulesetPhaseView> {
  String get _entry => '${widget.basePath}/rulesets/phases/${widget.meta.phase}/entrypoint';

  CfClient get _client => ref.read(clientProvider)!;

  Future<Map<String, dynamic>?> _load(CfClient c) async {
    try {
      final r = await c.get(_entry);
      return r is Map ? Map<String, dynamic>.from(r) : null;
    } on CfApiException catch (e) {
      // No entry point yet: the phase simply has no rules.
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  Future<void> _addOrEdit(Map<String, dynamic>? ruleset, QueryHandle<Map<String, dynamic>?> h, [Map<String, dynamic>? rule]) async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RuleEditorDialog(meta: widget.meta, rule: rule),
    );
    if (body == null || !mounted) return;
    final r = await runAction(context, () async {
      if (ruleset == null) {
        // Creating the entry point with the first rule.
        return _client.send('PUT', _entry, data: {
          'rules': [body],
        });
      }
      final id = ruleset['id'];
      if (rule == null) {
        return _client.send('POST', '${widget.basePath}/rulesets/$id/rules', data: body);
      }
      return _client.send('PATCH', '${widget.basePath}/rulesets/$id/rules/${rule['id']}', data: body);
    }, success: context.tr('Saved', '已保存'));
    if (r != null) await h.reload();
  }

  Future<void> _toggle(Map<String, dynamic> ruleset, Map<String, dynamic> rule, bool v, QueryHandle<Map<String, dynamic>?> h) async {
    final rules = (ruleset['rules'] as List).map((e) => e['id'] == rule['id'] ? {...e as Map, 'enabled': v} : e).toList();
    h.setData({...ruleset, 'rules': rules});
    final body = _ruleBody(rule)..['enabled'] = v;
    final r = await runAction(
      context,
      () => _client.send('PATCH', '${widget.basePath}/rulesets/${ruleset['id']}/rules/${rule['id']}', data: body),
      blocking: false,
    );
    if (r == null) await h.reload();
  }

  Future<void> _delete(Map<String, dynamic> ruleset, Map<String, dynamic> rule, QueryHandle<Map<String, dynamic>?> h) async {
    final ok = await confirmDanger(
      context,
      title: context.tr('Delete rule?', '删除规则？'),
      message: (rule['description'] as String?)?.isNotEmpty == true ? rule['description'] as String : '${rule['expression']}',
    );
    if (!ok || !mounted) return;
    final r = await runAction(
      context,
      () => _client.send('DELETE', '${widget.basePath}/rulesets/${ruleset['id']}/rules/${rule['id']}'),
      success: context.tr('Deleted', '已删除'),
    );
    if (r != null) await h.reload();
  }

  Future<void> _move(Map<String, dynamic> ruleset, int from, int to, QueryHandle<Map<String, dynamic>?> h) async {
    final rules = [...(ruleset['rules'] as List)];
    // onReorderItem already adjusts [to] for the removed item.
    final rule = rules.removeAt(from) as Map;
    rules.insert(to, rule);
    h.setData({...ruleset, 'rules': rules});
    final body = _ruleBody(Map<String, dynamic>.from(rule))..['position'] = {'index': to + 1};
    final r = await runAction(
      context,
      () => _client.send('PATCH', '${widget.basePath}/rulesets/${ruleset['id']}/rules/${rule['id']}', data: body),
      blocking: false,
    );
    if (r == null) await h.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiQuery<Map<String, dynamic>?>(
      cacheKey: 'ruleset:$_entry',
      load: _load,
      builder: (context, ruleset, h) {
        final rules = ((ruleset?['rules'] as List?) ?? const []).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        final header = Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.meta.description?.of(context) ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
              if (ruleset != null)
                IconButton(
                  tooltip: 'JSON',
                  icon: const Icon(Icons.data_object),
                  onPressed: () => showJsonDialog(context, ruleset, title: widget.meta.title.of(context)),
                ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.add),
                label: Text(context.tr('Add rule', '添加规则')),
                onPressed: () => _addOrEdit(ruleset, h),
              ),
            ],
          ),
        );
        if (rules.isEmpty) {
          return Column(
            children: [
              header,
              Expanded(
                child: EmptyView(
                  icon: widget.meta.icon,
                  title: context.tr('No rules in this phase', '该阶段还没有规则'),
                  subtitle: context.tr('Rules run top to bottom.', '规则按从上到下的顺序执行。'),
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            header,
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                buildDefaultDragHandles: false,
                itemCount: rules.length,
                onReorderItem: (from, to) => _move(ruleset!, from, to, h),
                itemBuilder: (context, i) {
                  final rule = rules[i];
                  final enabled = rule['enabled'] != false;
                  return Card(
                    key: ValueKey(rule['id']),
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
                      title: Row(
                        children: [
                          Text('${i + 1}. ', style: Theme.of(context).textTheme.labelLarge),
                          Expanded(
                            child: Text(
                              (rule['description'] as String?)?.isNotEmpty == true
                                  ? rule['description'] as String
                                  : context.tr('(no description)', '（无描述）'),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          StatusChip('${rule['action']}', tone: _actionTone(rule['action'] as String?)),
                        ],
                      ),
                      subtitle: Text(
                        '${rule['expression']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(value: enabled, onChanged: (v) => _toggle(ruleset!, rule, v, h)),
                          PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'edit') _addOrEdit(ruleset, h, rule);
                              if (v == 'delete') _delete(ruleset!, rule, h);
                              if (v == 'json') showJsonDialog(context, rule);
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(value: 'edit', child: Text(context.tr('Edit', '编辑'))),
                              PopupMenuItem(value: 'json', child: Text(context.tr('View JSON', '查看 JSON'))),
                              PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'))),
                            ],
                          ),
                        ],
                      ),
                      onTap: () => _addOrEdit(ruleset, h, rule),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

Tone _actionTone(String? a) => switch (a) {
  'block' => Tone.bad,
  'challenge' || 'js_challenge' || 'managed_challenge' => Tone.warn,
  'skip' || 'log' => Tone.neutral,
  _ => Tone.info,
};

/// Strips read-only fields so a rule can be sent back in a PATCH.
Map<String, dynamic> _ruleBody(Map<String, dynamic> rule) {
  const keep = {
    'action',
    'action_parameters',
    'description',
    'enabled',
    'expression',
    'logging',
    'ratelimit',
    'ref',
    'exposed_credential_check',
  };
  return {
    for (final e in rule.entries)
      if (keep.contains(e.key)) e.key: e.value,
  };
}

/// Editor for a single rule (expression + action + parameters).
class RuleEditorDialog extends StatefulWidget {
  const RuleEditorDialog({super.key, required this.meta, this.rule});

  final PhaseMeta meta;
  final Map<String, dynamic>? rule;

  @override
  State<RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<RuleEditorDialog> {
  late final _desc = TextEditingController(text: widget.rule?['description'] as String?);
  late final _expr = TextEditingController(text: widget.rule?['expression'] as String? ?? '');
  late String _action = widget.rule?['action'] as String? ?? widget.meta.actions.first;
  late final _params = TextEditingController(
    text: widget.rule?['action_parameters'] != null
        ? prettyJson(widget.rule!['action_parameters'])
        : (widget.meta.templates[_action] == null ? '' : prettyJson(widget.meta.templates[_action])),
  );
  late final _ratelimit = TextEditingController(
    text: prettyJson(widget.rule?['ratelimit'] ??
        {
          'characteristics': ['cf.colo.id', 'ip.src'],
          'period': 60,
          'requests_per_period': 100,
          'mitigation_timeout': 600,
        }),
  );
  late bool _enabled = widget.rule?['enabled'] != false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_desc, _expr, _params, _ratelimit]) {
      c.dispose();
    }
    super.dispose();
  }

  void _insert(String text) {
    final sel = _expr.selection;
    final t = _expr.text;
    final start = sel.isValid ? sel.start : t.length;
    final end = sel.isValid ? sel.end : t.length;
    _expr.value = TextEditingValue(
      text: t.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  void _submit() {
    final body = <String, dynamic>{
      'description': _desc.text.trim(),
      'expression': _expr.text.trim().isEmpty ? 'true' : _expr.text.trim(),
      'action': _action,
      'enabled': _enabled,
    };
    try {
      if (_params.text.trim().isNotEmpty) body['action_parameters'] = jsonDecode(_params.text);
      if (widget.meta.ratelimit) body['ratelimit'] = jsonDecode(_ratelimit.text);
    } catch (_) {
      setState(() => _error = context.tr('Parameters must be valid JSON', '参数必须是合法 JSON'));
      return;
    }
    if (widget.rule?['ref'] != null) body['ref'] = widget.rule!['ref'];
    Navigator.pop(context, body);
  }

  @override
  Widget build(BuildContext context) {
    final mono = const TextStyle(fontFamily: 'monospace', fontSize: 13);
    return AlertDialog(
      title: Text(widget.rule == null ? context.tr('New rule', '新建规则') : context.tr('Edit rule', '编辑规则')),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _desc,
                decoration: InputDecoration(labelText: context.tr('Rule name', '规则名称'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _expr,
                minLines: 3,
                maxLines: 8,
                style: mono,
                decoration: InputDecoration(
                  labelText: context.tr('Expression', '表达式'),
                  helperText: context.tr('Cloudflare Rules language (wirefilter)', 'Cloudflare 规则语言 (wirefilter)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final t in expressionTemplates)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.auto_fix_high, size: 14),
                      label: Text(t.$1.of(context), style: const TextStyle(fontSize: 12)),
                      onPressed: () => setState(() => _expr.text = t.$2),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final f in expressionFields)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(f, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                      onPressed: () => _insert(f),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _action,
                      decoration: InputDecoration(labelText: context.tr('Action', '动作'), border: const OutlineInputBorder()),
                      items: [for (final a in widget.meta.actions) DropdownMenuItem(value: a, child: Text(a))],
                      onChanged: (v) => setState(() {
                        _action = v ?? _action;
                        final t = widget.meta.templates[_action];
                        _params.text = t == null ? '' : prettyJson(t);
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(context.tr('Enabled', '启用')),
                  Switch(value: _enabled, onChanged: (v) => setState(() => _enabled = v)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _params,
                minLines: 3,
                maxLines: 14,
                style: mono,
                decoration: InputDecoration(
                  labelText: 'action_parameters (JSON)',
                  helperText: context.tr('Leave empty if the action takes no parameters', '若动作无需参数可留空'),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (widget.meta.ratelimit) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _ratelimit,
                  minLines: 3,
                  maxLines: 10,
                  style: mono,
                  decoration: const InputDecoration(labelText: 'ratelimit (JSON)', border: OutlineInputBorder()),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel', '取消'))),
        FilledButton(onPressed: _submit, child: Text(context.tr('Save', '保存'))),
      ],
    );
  }
}
