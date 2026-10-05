import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/files.dart';

String _ns(String accountId) => '/accounts/$accountId/storage/kv/namespaces';

class KvNamespacesPage extends ConsumerWidget {
  const KvNamespacesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: 'Workers KV',
      builder: (context, accountId) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'kv-ns:$accountId',
        load: (c) => c.list(_ns(accountId), perPage: 100),
        frame: (w) => PageScaffold(title: 'Workers KV', body: w),
        builder: (context, list, h) {
          final c = ref.read(clientProvider)!;
          return PageScaffold(
            title: 'Workers KV',
            actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload)],
            floatingActionButton: FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: Text(context.tr('Create namespace', '创建命名空间')),
              onPressed: () async {
                final title = await promptText(context, title: context.tr('Namespace name', '命名空间名称'), hint: 'MY_KV');
                if (title == null || title.trim().isEmpty || !context.mounted) return;
                await runAction(
                  context,
                  () => c.post(_ns(accountId), data: {'title': title.trim()}),
                  success: context.tr('Created', '已创建'),
                );
                await h.reload();
              },
            ),
            body: list.isEmpty
                ? EmptyView(icon: Icons.key, title: context.tr('No namespaces', '没有命名空间'))
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96, top: 8),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (context, i) {
                      final ns = list[i];
                      final id = ns['id'] as String;
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.key)),
                        title: Text('${ns['title']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Mono(id, size: 11),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'rename') {
                              final t = await promptText(
                                context,
                                title: context.tr('Rename', '重命名'),
                                initial: ns['title'] as String?,
                              );
                              if (t == null || t.trim().isEmpty || !context.mounted) return;
                              await runAction(context, () => c.put('${_ns(accountId)}/$id', data: {'title': t.trim()}));
                              await h.reload();
                            } else if (v == 'copy') {
                              await copyText(context, id);
                            } else if (v == 'delete') {
                              final ok = await confirmDanger(
                                context,
                                title: context.tr('Delete namespace?', '删除命名空间？'),
                                message: context.tr('All keys in it will be deleted.', '其中所有键都会被删除。'),
                                typeToConfirm: ns['title'] as String?,
                              );
                              if (!ok || !context.mounted) return;
                              await runAction(context, () => c.delete('${_ns(accountId)}/$id'));
                              await h.reload();
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(value: 'rename', child: Text(context.tr('Rename', '重命名'))),
                            PopupMenuItem(value: 'copy', child: Text(context.tr('Copy ID', '复制 ID'))),
                            PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'))),
                          ],
                        ),
                        onTap: () => context.push('/kv/$id?title=${Uri.encodeComponent('${ns['title']}')}'),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

class KvBrowserPage extends ConsumerStatefulWidget {
  const KvBrowserPage({super.key, required this.namespaceId, this.title});

  final String namespaceId;
  final String? title;

  @override
  ConsumerState<KvBrowserPage> createState() => _KvBrowserPageState();
}

class _KvBrowserPageState extends ConsumerState<KvBrowserPage> {
  final _prefix = TextEditingController();
  final List<Map<String, dynamic>> _keys = [];
  String? _cursor;
  bool _loading = false;
  Object? _error;
  final Set<String> _selected = {};

  String get _base => '${_ns(ref.read(currentAccountIdProvider)!)}/${widget.namespaceId}';
  CfClient get _c => ref.read(clientProvider)!;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _keys.clear();
        _cursor = null;
        _selected.clear();
      }
    });
    try {
      final res = await _c.send(
        'GET',
        '$_base/keys',
        query: {
          'limit': 1000,
          if (_prefix.text.trim().isNotEmpty) 'prefix': _prefix.text.trim(),
          if (_cursor != null && _cursor!.isNotEmpty) 'cursor': _cursor,
        },
      );
      final items = (res.result as List? ?? const []).cast<Map>().map((e) => Map<String, dynamic>.from(e));
      setState(() {
        _keys.addAll(items);
        final cur = res.resultInfo?['cursor'] as String?;
        _cursor = (cur == null || cur.isEmpty) ? null : cur;
      });
    } catch (e) {
      setState(() => _error = e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openValue(Map<String, dynamic> key) async {
    final name = key['name'] as String;
    final r = await runAction(context, () => _c.rawOk('GET', '$_base/values/${Uri.encodeComponent(name)}'));
    if (r == null || !mounted) return;
    final isText = _looksText(r.bytes);
    await showDialog<void>(
      context: context,
      builder: (_) => _ValueEditor(
        name: name,
        initial: isText ? utf8.decode(r.bytes, allowMalformed: true) : null,
        bytes: r.bytes,
        metadata: key['metadata'],
        expiration: key['expiration'],
        onSave: (text, ttl) => _put(name, Uint8List.fromList(utf8.encode(text)), ttl: ttl),
      ),
    );
  }

  bool _looksText(Uint8List b) {
    final n = b.length > 2048 ? 2048 : b.length;
    for (var i = 0; i < n; i++) {
      final c = b[i];
      if (c == 0) return false;
    }
    try {
      utf8.decode(b.sublist(0, n));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _put(String key, Uint8List bytes, {int? ttl}) async {
    final r = await runAction(
      context,
      () => _c.send(
        'PUT',
        '$_base/values/${Uri.encodeComponent(key)}',
        data: Stream.fromIterable([bytes]),
        contentType: 'application/octet-stream',
        headers: {'Content-Length': '${bytes.length}'},
        query: {'expiration_ttl': ?ttl},
      ),
      success: context.tr('Saved', '已保存'),
    );
    if (r != null) await _load(reset: true);
    return r != null;
  }

  Future<void> _add() async {
    final key = await promptText(context, title: context.tr('Key name', '键名'));
    if (key == null || key.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ValueEditor(
        name: key,
        initial: '',
        onSave: (text, ttl) => _put(key, Uint8List.fromList(utf8.encode(text)), ttl: ttl),
      ),
    );
  }

  Future<void> _upload() async {
    final f = await pickFile();
    if (f == null || !mounted) return;
    final key = await promptText(context, title: context.tr('Key name', '键名'), initial: f.name);
    if (key == null || key.isEmpty) return;
    await _put(key, f.bytes);
  }

  Future<void> _deleteSelected(List<String> keys) async {
    final ok = await confirmDanger(
      context,
      title: context.tr('Delete ${keys.length} key(s)?', '删除 ${keys.length} 个键？'),
      message: keys.take(10).join('\n') + (keys.length > 10 ? '\n…' : ''),
    );
    if (!ok || !mounted) return;
    final r = await runAction(context, () async {
      for (var i = 0; i < keys.length; i += 10000) {
        await _c.post('$_base/bulk/delete', data: keys.sublist(i, i + 10000 > keys.length ? keys.length : i + 10000));
      }
      return true;
    }, success: context.tr('Deleted', '已删除'));
    if (r == true) await _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return PageScaffold(
      title: selecting
          ? context.tr('${_selected.length} selected', '已选 ${_selected.length} 个')
          : (widget.title ?? 'KV'),
      subtitle: selecting ? null : widget.namespaceId,
      leading: selecting ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)) : null,
      actions: selecting
          ? [IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteSelected(_selected.toList()))]
          : [
              IconButton(
                tooltip: context.tr('Upload file as value', '上传文件作为值'),
                icon: const Icon(Icons.upload_file),
                onPressed: _upload,
              ),
              IconButton(icon: const Icon(Icons.refresh), onPressed: () => _load(reset: true)),
            ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(context.tr('Add key', '添加键')),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _prefix,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: context.tr('Filter by key prefix (press Enter)', '按键前缀过滤（回车）'),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
              ),
              onSubmitted: (_) => _load(reset: true),
            ),
          ),
          if (_error != null)
            Expanded(
              child: ErrorView(error: _error!, onRetry: () => _load(reset: true)),
            ),
          if (_error == null)
            Expanded(
              child: _keys.isEmpty && _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _keys.isEmpty
                  ? EmptyView(icon: Icons.key_off, title: context.tr('No keys', '没有键'))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: _keys.length + (_cursor != null ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == _keys.length) {
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: OutlinedButton(
                                onPressed: _loading ? null : _load,
                                child: Text(context.tr('Load more', '加载更多')),
                              ),
                            ),
                          );
                        }
                        final k = _keys[i];
                        final name = k['name'] as String;
                        final sel = _selected.contains(name);
                        return ListTile(
                          dense: true,
                          selected: sel,
                          leading: selecting
                              ? Checkbox(
                                  value: sel,
                                  onChanged: (_) => setState(() => sel ? _selected.remove(name) : _selected.add(name)),
                                )
                              : const Icon(Icons.vpn_key_outlined, size: 18),
                          title: Text(name, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                          subtitle: k['expiration'] == null && k['metadata'] == null
                              ? null
                              : Text(
                                  [
                                    if (k['expiration'] != null)
                                      '${context.tr('expires', '过期')} ${formatDate(k['expiration'])}',
                                    if (k['metadata'] != null) 'metadata: ${jsonEncode(k['metadata'])}',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => selecting
                              ? setState(() => sel ? _selected.remove(name) : _selected.add(name))
                              : _openValue(k),
                          onLongPress: () => setState(() => _selected.add(name)),
                          trailing: selecting
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  onPressed: () => _deleteSelected([name]),
                                ),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}

class _ValueEditor extends StatefulWidget {
  const _ValueEditor({
    required this.name,
    required this.onSave,
    this.initial,
    this.bytes,
    this.metadata,
    this.expiration,
  });

  final String name;
  final String? initial;
  final Uint8List? bytes;
  final Object? metadata;
  final Object? expiration;
  final Future<bool> Function(String text, int? ttl) onSave;

  @override
  State<_ValueEditor> createState() => _ValueEditorState();
}

class _ValueEditorState extends State<_ValueEditor> {
  late final _text = TextEditingController(text: widget.initial);
  final _ttl = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    _ttl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final binary = widget.initial == null;
    return AlertDialog(
      title: Text(widget.name, style: const TextStyle(fontFamily: 'monospace')),
      content: SizedBox(
        width: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (binary)
              Text(
                context.tr(
                  'Binary value · ${formatBytes(widget.bytes?.length ?? 0)}',
                  '二进制值 · ${formatBytes(widget.bytes?.length ?? 0)}',
                ),
              )
            else
              TextField(
                controller: _text,
                minLines: 8,
                maxLines: 22,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            const SizedBox(height: 12),
            if (!binary)
              TextField(
                controller: _ttl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.tr('Expiration TTL in seconds (optional, ≥ 60)', '过期 TTL 秒数（可选，≥ 60）'),
                  border: const OutlineInputBorder(),
                ),
              ),
            if (widget.metadata != null) ...[
              const SizedBox(height: 8),
              Text('metadata: ${jsonEncode(widget.metadata)}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.bytes != null)
          TextButton.icon(
            icon: const Icon(Icons.download),
            label: Text(context.tr('Download', '下载')),
            onPressed: () => saveBytes(context, fileName: widget.name.split('/').last, bytes: widget.bytes!),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Close', '关闭'))),
        if (!binary)
          FilledButton(
            onPressed: () async {
              final ok = await widget.onSave(_text.text, int.tryParse(_ttl.text.trim()));
              if (ok && context.mounted) Navigator.pop(context);
            },
            child: Text(context.tr('Save', '保存')),
          ),
      ],
    );
  }
}
