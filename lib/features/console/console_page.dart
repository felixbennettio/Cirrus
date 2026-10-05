import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:re_editor/re_editor.dart';

import '../../core/api/cf_client.dart';
import '../../core/catalog/catalog.dart';
import '../../core/session/session.dart';
import '../../core/settings/app_settings.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/code_editor.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/files.dart';
import '../../ui/widgets/json_view.dart';
import '../../ui/widgets/schema_form.dart';

/// Requests sent from the console during this session.
class ConsoleHistoryEntry {
  ConsoleHistoryEntry(this.opId, this.method, this.url, this.status, this.at);

  final String opId;
  final String method;
  final String url;
  final int status;
  final DateTime at;
}

class ConsoleHistory extends Notifier<List<ConsoleHistoryEntry>> {
  @override
  List<ConsoleHistoryEntry> build() => const [];

  void add(ConsoleHistoryEntry e) => state = [e, ...state].take(100).toList();
}

final consoleHistoryProvider = NotifierProvider<ConsoleHistory, List<ConsoleHistoryEntry>>(ConsoleHistory.new);

class ConsolePage extends ConsumerStatefulWidget {
  const ConsolePage({super.key, this.initialOpId});

  final String? initialOpId;

  @override
  ConsumerState<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends ConsumerState<ConsolePage> {
  String? _opId;
  String _q = '';
  int _tab = 0; // 0 browse, 1 favorites, 2 history

  @override
  void initState() {
    super.initState();
    _opId = widget.initialOpId;
  }

  @override
  void didUpdateWidget(covariant ConsolePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialOpId != null && widget.initialOpId != oldWidget.initialOpId) _opId = widget.initialOpId;
  }

  void _select(BuildContext context, ApiOperation op) {
    if (isWide(context)) {
      setState(() => _opId = op.id);
    } else {
      context.push('/console/op/${Uri.encodeComponent(op.id)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    return PageScaffold(
      title: context.tr('API console', 'API 控制台'),
      subtitle: catalog.value == null ? null : context.tr('${catalog.value!.operations.length} endpoints', '${catalog.value!.operations.length} 个接口'),
      body: catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e),
        data: (cat) {
          final browser = _browser(context, cat);
          if (!isWide(context)) return browser;
          final op = _opId == null ? null : cat.byId(_opId!);
          return Row(
            children: [
              SizedBox(width: 380, child: browser),
              const VerticalDivider(width: 1),
              Expanded(
                child: op == null
                    ? EmptyView(
                        icon: Icons.terminal,
                        title: context.tr('Pick an endpoint', '选择一个接口'),
                        subtitle: context.tr('Every Cloudflare API endpoint is here — search by name, path or product.', '所有 Cloudflare API 接口都在这里——可按名称、路径或产品搜索。'),
                      )
                    : OperationRunner(key: ValueKey(op.id), op: op, catalog: cat),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _browser(BuildContext context, ApiCatalog cat) {
    final favorites = ref.watch(settingsProvider.select((s) => s.favoriteOps));
    final history = ref.watch(consoleHistoryProvider);
    Widget opTile(ApiOperation op, {String? trailingText}) => ListTile(
      dense: true,
      selected: op.id == _opId,
      leading: MethodBadge(op.method, small: true),
      title: Text(op.summary.isEmpty ? op.path : op.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(trailingText ?? op.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
      trailing: op.deprecated ? const Icon(Icons.warning_amber, size: 16) : null,
      onTap: () => _select(context, op),
    );

    Widget body;
    if (_tab == 1) {
      final ops = favorites.map(cat.byId).whereType<ApiOperation>().toList();
      body = ops.isEmpty
          ? EmptyView(icon: Icons.star_border, title: context.tr('No favorites yet', '还没有收藏'))
          : ListView(children: [for (final op in ops) opTile(op)]);
    } else if (_tab == 2) {
      body = history.isEmpty
          ? EmptyView(icon: Icons.history, title: context.tr('No requests yet', '还没有请求'))
          : ListView(
              children: [
                for (final h in history)
                  if (cat.byId(h.opId) case final op?) opTile(op, trailingText: '${h.status} · ${formatRelative(h.at, zh: context.isZh)} · ${h.url}'),
              ],
            );
    } else if (_q.length >= 2) {
      final results = cat.search(_q, limit: 300);
      body = ListView(children: [for (final op in results) opTile(op)]);
    } else {
      final products = cat.byProduct.entries.toList();
      body = ListView.builder(
        itemCount: products.length,
        itemBuilder: (context, i) {
          final e = products[i];
          return ExpansionTile(
            dense: true,
            title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(context.tr('${e.value.length} endpoints', '${e.value.length} 个接口'), style: const TextStyle(fontSize: 11)),
            children: [for (final op in e.value) opTile(op)],
          );
        },
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: SearchField(
            hint: context.tr('Search endpoints (e.g. "dns create", "tunnel")', '搜索接口（如 "dns create"、"tunnel"）'),
            onChanged: (v) => setState(() {
              _q = v.trim();
              _tab = 0;
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(context.tr('Browse', '浏览')), icon: const Icon(Icons.account_tree_outlined, size: 16)),
              ButtonSegment(value: 1, label: Text(context.tr('Starred', '收藏')), icon: const Icon(Icons.star_outline, size: 16)),
              ButtonSegment(value: 2, label: Text(context.tr('History', '历史')), icon: const Icon(Icons.history, size: 16)),
            ],
            selected: {_tab},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: body),
      ],
    );
  }
}

/// Phone layout: an operation on its own page.
class ConsoleOperationPage extends ConsumerWidget {
  const ConsoleOperationPage({super.key, required this.opId});

  final String opId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final op = catalog.value?.byId(opId);
    return PageScaffold(
      title: op?.summary ?? opId,
      body: catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e),
        data: (cat) => op == null ? EmptyView(icon: Icons.help_outline, title: opId) : OperationRunner(op: op, catalog: cat),
      ),
    );
  }
}

class _Response {
  _Response({required this.status, required this.headers, required this.bytes, required this.duration, required this.contentType});

  final int status;
  final Map<String, List<String>> headers;
  final Uint8List bytes;
  final Duration duration;
  final String contentType;

  Object? get json {
    try {
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }
}

class OperationRunner extends ConsumerStatefulWidget {
  const OperationRunner({super.key, required this.op, required this.catalog});

  final ApiOperation op;
  final ApiCatalog catalog;

  @override
  ConsumerState<OperationRunner> createState() => _OperationRunnerState();
}

class _OperationRunnerState extends ConsumerState<OperationRunner> {
  final Map<String, TextEditingController> _params = {};
  late final CodeLineEditingController _body;
  final Map<String, (String?, PickedFile?)> _multipart = {};
  PickedFile? _rawFile;
  _Response? _response;
  Object? _error;
  bool _sending = false;

  ApiOperation get op => widget.op;

  @override
  void initState() {
    super.initState();
    final ids = ref.read(scopeIdsProvider);
    for (final p in op.params) {
      final initial = p.location == 'path' ? (ids[p.name] ?? '') : '';
      _params['${p.location}:${p.name}'] = TextEditingController(text: initial);
    }
    final body = op.body;
    String text = '';
    if (body != null && body.isJson) {
      final sk = widget.catalog.skeleton(body.schema);
      text = sk == null ? '{}' : prettyJson(sk);
    }
    _body = CodeLineEditingController.fromText(text);
  }

  @override
  void dispose() {
    for (final c in _params.values) {
      c.dispose();
    }
    _body.dispose();
    super.dispose();
  }

  String _path() {
    var p = op.path;
    for (final param in op.pathParams) {
      final v = _params['path:${param.name}']!.text.trim();
      p = p.replaceAll('{${param.name}}', param.name == 'model_name' ? v : Uri.encodeComponent(v));
    }
    return p;
  }

  Map<String, dynamic> _query() => {
    for (final p in op.queryParams)
      if (_params['query:${p.name}']!.text.trim().isNotEmpty) p.name: _params['query:${p.name}']!.text.trim(),
  };

  Map<String, String> _headers() => {
    for (final p in op.headerParams)
      if (_params['header:${p.name}']!.text.trim().isNotEmpty) p.name: _params['header:${p.name}']!.text.trim(),
  };

  Object? _jsonBody() {
    final t = _body.text.trim();
    if (t.isEmpty) return null;
    return jsonDecode(t);
  }

  Future<void> _send() async {
    final missing = op.params.where((p) => p.required && _params['${p.location}:${p.name}']!.text.trim().isEmpty).map((p) => p.name).toList();
    if (missing.isNotEmpty) {
      showToast(context, context.tr('Missing required: ${missing.join(', ')}', '缺少必填参数：${missing.join('、')}'), error: true);
      return;
    }
    Object? data;
    String? contentType;
    final body = op.body;
    try {
      if (body != null) {
        if (body.isJson) {
          data = _jsonBody();
        } else if (body.isMultipart) {
          final form = FormData();
          _multipart.forEach((k, v) {
            if (v.$2 != null) {
              form.files.add(MapEntry(k, MultipartFile.fromBytes(v.$2!.bytes, filename: v.$2!.name)));
            } else if (v.$1 != null && v.$1!.isNotEmpty) {
              form.fields.add(MapEntry(k, v.$1!));
            }
          });
          data = form;
        } else {
          final bytes = _rawFile?.bytes ?? Uint8List.fromList(utf8.encode(_body.text));
          data = Stream.fromIterable([bytes]);
          contentType = body.contentType;
        }
      }
    } catch (e) {
      showToast(context, context.tr('Body is not valid JSON', '请求体不是合法的 JSON'), error: true);
      return;
    }
    if (op.isMutation && ref.read(settingsProvider).confirmMutations) {
      final ok = await confirm(
        context,
        title: context.tr('Send ${op.method} request?', '发送 ${op.method} 请求？'),
        message: _path(),
        destructive: op.method == 'DELETE',
        confirmLabel: context.tr('Send', '发送'),
      );
      if (!ok) return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final CfClient c = ref.read(clientProvider)!;
    try {
      final headers = _headers();
      if (data is Stream) {
        final bytes = _rawFile?.bytes ?? Uint8List.fromList(utf8.encode(_body.text));
        headers['Content-Length'] = '${bytes.length}';
      }
      final r = await c.raw(op.method, _path(), query: _query(), data: data, contentType: contentType, headers: headers);
      final resp = _Response(
        status: r.statusCode,
        headers: r.headers,
        bytes: r.bytes,
        duration: r.duration,
        contentType: r.header('content-type') ?? '',
      );
      ref.read(consoleHistoryProvider.notifier).add(ConsoleHistoryEntry(op.id, op.method, _path(), r.statusCode, DateTime.now()));
      setState(() => _response = resp);
    } catch (e) {
      setState(() => _error = e);
    }
    if (mounted) setState(() => _sending = false);
  }

  Widget _paramField(ApiParam p) {
    final s = widget.catalog.resolve(p.schema);
    final enumValues = s['enum'] as List?;
    final ctl = _params['${p.location}:${p.name}']!;
    final label = '${p.name}${p.required ? ' *' : ''}';
    if (enumValues != null && enumValues.isNotEmpty) {
      return DropdownButtonFormField<String>(
        initialValue: ctl.text.isEmpty ? null : ctl.text,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, helperText: p.description, helperMaxLines: 2, border: const OutlineInputBorder(), isDense: true),
        items: [
          const DropdownMenuItem(value: '', child: Text('—')),
          for (final v in enumValues) DropdownMenuItem(value: '$v', child: Text('$v')),
        ],
        onChanged: (v) => ctl.text = v ?? '',
      );
    }
    return TextField(
      controller: ctl,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: s['example']?.toString() ?? s['type']?.toString(),
        helperText: p.description,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _bodyEditor(BuildContext context) {
    final body = op.body!;
    if (body.isMultipart) {
      final props = (widget.catalog.resolve(body.schema)['properties'] as Map<String, dynamic>?) ?? const {};
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('multipart/form-data', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          for (final name in props.keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: InputDecoration(
                        labelText: name,
                        helperText: _multipart[name]?.$2 == null ? null : '📎 ${_multipart[name]!.$2!.name}',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => _multipart[name] = (v, _multipart[name]?.$2),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Attach file', '附加文件'),
                    icon: const Icon(Icons.attach_file),
                    onPressed: () async {
                      final f = await pickFile();
                      if (f != null) setState(() => _multipart[name] = (null, f));
                    },
                  ),
                ],
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(body.contentType, style: Theme.of(context).textTheme.labelMedium),
            const Spacer(),
            if (body.isJson) ...[
              TextButton.icon(
                icon: const Icon(Icons.dynamic_form_outlined, size: 18),
                label: Text(context.tr('Form', '表单')),
                onPressed: () async {
                  Map<String, dynamic>? initial;
                  try {
                    final j = _jsonBody();
                    if (j is Map<String, dynamic>) initial = j;
                  } catch (_) {}
                  final r = await showSchemaEditor(context, title: op.summary, catalog: widget.catalog, schema: body.schema, initial: initial, submitLabel: context.tr('Apply', '应用'));
                  if (r != null) _body.text = prettyJson(r);
                },
              ),
              TextButton(
                onPressed: () {
                  try {
                    _body.text = prettyJson(_jsonBody());
                  } catch (_) {
                    showToast(context, context.tr('Invalid JSON', 'JSON 格式错误'), error: true);
                  }
                },
                child: Text(context.tr('Format', '格式化')),
              ),
              TextButton(
                onPressed: () => _body.text = prettyJson(widget.catalog.skeleton(body.schema, requiredOnly: true)),
                child: Text(context.tr('Required only', '仅必填')),
              ),
            ] else
              TextButton.icon(
                icon: const Icon(Icons.attach_file, size: 18),
                label: Text(_rawFile?.name ?? context.tr('Use file', '使用文件')),
                onPressed: () async {
                  final f = await pickFile();
                  if (f != null) setState(() => _rawFile = f);
                },
              ),
          ],
        ),
        SizedBox(
          height: 260,
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CodeEditorField(controller: _body, language: body.isJson ? 'json' : languageFor(body.contentType)),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final favorites = ref.watch(settingsProvider.select((s) => s.favoriteOps));
    final starred = favorites.contains(op.id);
    final pathParams = op.pathParams.toList();
    final queryParams = op.queryParams.toList();
    final headerParams = op.headerParams.toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            MethodBadge(op.method),
            const SizedBox(width: 10),
            Expanded(child: SelectableText(op.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 14, fontWeight: FontWeight.w600))),
            IconButton(
              tooltip: starred ? context.tr('Unstar', '取消收藏') : context.tr('Star', '收藏'),
              icon: Icon(starred ? Icons.star : Icons.star_border, color: starred ? Colors.amber : null),
              onPressed: () => ref.read(settingsProvider.notifier).toggleFavoriteOp(op.id),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(op.summary, style: theme.textTheme.titleMedium),
        if (op.description != null) ...[
          const SizedBox(height: 6),
          Text(op.description!, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            Chip(label: Text(op.group), visualDensity: VisualDensity.compact),
            if (op.deprecated) Chip(avatar: const Icon(Icons.warning_amber, size: 16), label: Text(context.tr('Deprecated', '已弃用')), visualDensity: VisualDensity.compact),
            if (op.availability != null) Chip(label: Text(op.availability!), visualDensity: VisualDensity.compact),
            for (final p in op.permissions) Chip(avatar: const Icon(Icons.key, size: 14), label: Text(p), visualDensity: VisualDensity.compact),
            if (op.plans.isNotEmpty && op.plans.length < 4) Chip(label: Text(op.plans.join(' / ')), visualDensity: VisualDensity.compact),
          ],
        ),
        const SizedBox(height: 16),
        if (pathParams.isNotEmpty) ...[
          Text(context.tr('Path parameters', '路径参数'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final p in pathParams) Padding(padding: const EdgeInsets.only(bottom: 8), child: _paramField(p)),
        ],
        if (queryParams.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(context.tr('Query parameters (${queryParams.length})', '查询参数（${queryParams.length}）'), style: theme.textTheme.titleSmall),
            initiallyExpanded: queryParams.any((p) => p.required),
            children: [for (final p in queryParams) Padding(padding: const EdgeInsets.only(bottom: 8), child: _paramField(p))],
          ),
        if (headerParams.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(context.tr('Headers (${headerParams.length})', '请求头（${headerParams.length}）'), style: theme.textTheme.titleSmall),
            children: [for (final p in headerParams) Padding(padding: const EdgeInsets.only(bottom: 8), child: _paramField(p))],
          ),
        if (op.body != null) ...[
          const SizedBox(height: 8),
          Text(context.tr('Request body', '请求体'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _bodyEditor(context),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
              label: Text(context.tr('Send', '发送')),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('cURL'),
              onPressed: () {
                Object? body;
                try {
                  body = op.body?.isJson == true ? _jsonBody() : null;
                } catch (_) {}
                final curl = ref.read(clientProvider)!.curl(op.method, _path(), query: _query(), body: body);
                copyText(context, curl, label: context.tr('cURL copied (secrets masked)', '已复制 cURL（已隐藏密钥）'));
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null) ErrorView(error: _error!, compact: true),
        if (_response != null) _ResponseView(response: _response!, name: op.id),
      ],
    );
  }
}

class _ResponseView extends StatelessWidget {
  const _ResponseView({required this.response, required this.name});

  final _Response response;
  final String name;

  @override
  Widget build(BuildContext context) {
    final r = response;
    final ok = r.status >= 200 && r.status < 300;
    final json = r.contentType.contains('json') || r.bytes.isNotEmpty && (r.bytes.first == 123 || r.bytes.first == 91) ? r.json : null;
    final isImage = r.contentType.startsWith('image/');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DefaultTabController(
          length: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  StatusChip('${r.status}', tone: ok ? Tone.good : Tone.bad),
                  const SizedBox(width: 8),
                  Text('${r.duration.inMilliseconds} ms · ${formatBytes(r.bytes.length)} · ${r.contentType}', style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  IconButton(
                    tooltip: context.tr('Save response', '保存响应'),
                    icon: const Icon(Icons.save_alt, size: 20),
                    onPressed: () => saveBytes(context, fileName: '$name.${json != null ? 'json' : 'bin'}', bytes: r.bytes),
                  ),
                ],
              ),
              TabBar(tabs: [Tab(text: context.tr('Body', '响应体')), Tab(text: context.tr('Headers', '响应头'))]),
              SizedBox(
                height: 480,
                child: TabBarView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: isImage
                          ? Image.memory(r.bytes, fit: BoxFit.contain)
                          : json != null
                          ? JsonViewer(json)
                          : CodeView(text: utf8.decode(r.bytes, allowMalformed: true), language: languageFor(r.contentType)),
                    ),
                    ListView(
                      children: [
                        for (final e in r.headers.entries) InfoRow(e.key, e.value.join(', '), mono: true),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
