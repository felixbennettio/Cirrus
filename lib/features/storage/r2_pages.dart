import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/code_editor.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/files.dart';
import '../../ui/widgets/json_view.dart';

String _buckets(String accountId) => '/accounts/$accountId/r2/buckets';

class R2BucketsPage extends ConsumerWidget {
  const R2BucketsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: 'R2',
      builder: (context, accountId) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'r2-buckets:$accountId',
        frame: (w) => PageScaffold(title: 'R2', body: w),
        load: (c) async {
          final res = await c.send('GET', _buckets(accountId), query: {'per_page': 1000});
          final r = res.result;
          final list = r is Map ? (r['buckets'] as List? ?? const []) : (r as List? ?? const []);
          return list.cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        },
        builder: (context, buckets, h) {
          final c = ref.read(clientProvider)!;
          return PageScaffold(
            title: context.tr('R2 object storage', 'R2 对象存储'),
            actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload)],
            floatingActionButton: FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: Text(context.tr('Create bucket', '创建存储桶')),
              onPressed: () async {
                final r = await showDialog<Map<String, dynamic>>(
                  context: context,
                  builder: (_) => const _CreateBucketDialog(),
                );
                if (r == null || !context.mounted) return;
                await runAction(
                  context,
                  () => c.post(_buckets(accountId), data: r),
                  success: context.tr('Bucket created', '存储桶已创建'),
                );
                await h.reload();
              },
            ),
            body: buckets.isEmpty
                ? EmptyView(icon: Icons.cloud_queue, title: context.tr('No buckets', '没有存储桶'))
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96, top: 8),
                    itemCount: buckets.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (context, i) {
                      final b = buckets[i];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.inventory_2_outlined)),
                        title: Text('${b['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          [
                            if (b['location'] != null) '${b['location']}',
                            if (b['storage_class'] != null) '${b['storage_class']}',
                            if (b['jurisdiction'] != null && b['jurisdiction'] != 'default') '${b['jurisdiction']}',
                            formatDate(b['creation_date'], withTime: false),
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/r2/${Uri.encodeComponent(b['name'] as String)}'),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

class _CreateBucketDialog extends StatefulWidget {
  const _CreateBucketDialog();

  @override
  State<_CreateBucketDialog> createState() => _CreateBucketDialogState();
}

class _CreateBucketDialogState extends State<_CreateBucketDialog> {
  final _name = TextEditingController();
  String _location = '';
  String _class = 'Standard';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('Create bucket', '创建存储桶')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.tr('Bucket name', '存储桶名称'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _location,
              decoration: InputDecoration(
                labelText: context.tr('Location hint', '位置提示'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: '', child: Text(context.tr('Automatic', '自动'))),
                const DropdownMenuItem(value: 'apac', child: Text('Asia-Pacific (APAC)')),
                const DropdownMenuItem(value: 'enam', child: Text('Eastern North America (ENAM)')),
                const DropdownMenuItem(value: 'wnam', child: Text('Western North America (WNAM)')),
                const DropdownMenuItem(value: 'weur', child: Text('Western Europe (WEUR)')),
                const DropdownMenuItem(value: 'eeur', child: Text('Eastern Europe (EEUR)')),
                const DropdownMenuItem(value: 'oc', child: Text('Oceania (OC)')),
              ],
              onChanged: (v) => setState(() => _location = v ?? ''),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _class,
              decoration: InputDecoration(
                labelText: context.tr('Default storage class', '默认存储类型'),
                border: const OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'Standard', child: Text('Standard')),
                DropdownMenuItem(value: 'InfrequentAccess', child: Text('Infrequent Access')),
              ],
              onChanged: (v) => setState(() => _class = v ?? 'Standard'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel', '取消'))),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'name': _name.text.trim(),
            if (_location.isNotEmpty) 'locationHint': _location,
            'storageClass': _class,
          }),
          child: Text(context.tr('Create', '创建')),
        ),
      ],
    );
  }
}

class R2BucketPage extends ConsumerWidget {
  const R2BucketPage({super.key, required this.bucket});

  final String bucket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: bucket,
      builder: (context, accountId) {
        final base = '${_buckets(accountId)}/${Uri.encodeComponent(bucket)}';
        return DefaultTabController(
          length: 3,
          child: PageScaffold(
            title: bucket,
            subtitle: 'R2',
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v != 'delete') return;
                  final ok = await confirmDanger(
                    context,
                    title: context.tr('Delete bucket?', '删除存储桶？'),
                    message: context.tr('The bucket must be empty.', '存储桶必须为空。'),
                    typeToConfirm: bucket,
                  );
                  if (!ok || !context.mounted) return;
                  final r = await runAction(
                    context,
                    () => ref.read(clientProvider)!.send('DELETE', base),
                    success: context.tr('Deleted', '已删除'),
                  );
                  if (r != null && context.mounted) context.go('/r2');
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'delete', child: Text(context.tr('Delete bucket', '删除存储桶'))),
                ],
              ),
            ],
            bottom: TabBar(
              tabs: [
                Tab(text: context.tr('Objects', '对象')),
                Tab(text: context.tr('Settings', '设置')),
                Tab(text: context.tr('Custom domains', '自定义域')),
              ],
            ),
            body: TabBarView(
              children: [
                _ObjectBrowser(base: base, bucket: bucket),
                _BucketSettings(base: base),
                _CustomDomains(base: base),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ObjectBrowser extends ConsumerStatefulWidget {
  const _ObjectBrowser({required this.base, required this.bucket});

  final String base;
  final String bucket;

  @override
  ConsumerState<_ObjectBrowser> createState() => _ObjectBrowserState();
}

class _ObjectBrowserState extends ConsumerState<_ObjectBrowser> with AutomaticKeepAliveClientMixin {
  String _prefix = '';
  final List<Map<String, dynamic>> _objects = [];
  final List<String> _folders = [];
  String? _cursor;
  bool _loading = false;
  Object? _error;
  double? _progress;

  @override
  bool get wantKeepAlive => true;

  CfClient get _c => ref.read(clientProvider)!;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _objects.clear();
        _folders.clear();
        _cursor = null;
      }
    });
    try {
      final res = await _c.send(
        'GET',
        '${widget.base}/objects',
        query: {'prefix': _prefix, 'delimiter': '/', 'per_page': 1000, if (_cursor != null) 'cursor': _cursor},
      );
      final r = res.result;
      final objs = r is Map ? (r['objects'] as List? ?? const []) : (r as List? ?? const []);
      final info = res.resultInfo ?? const {};
      final delimited = (info['delimited'] as List?) ?? (r is Map ? r['delimited'] as List? : null) ?? const [];
      setState(() {
        _objects.addAll(objs.cast<Map>().map((e) => Map<String, dynamic>.from(e)).where((o) => o['key'] != _prefix));
        _folders.addAll(delimited.map((e) => '$e').where((f) => !_folders.contains(f)));
        final truncated = info['is_truncated'] == true || info['is_truncated'] == 'true';
        final cur = info['cursor'] as String?;
        _cursor = truncated && cur != null && cur.isNotEmpty ? cur : null;
      });
    } catch (e) {
      setState(() => _error = e);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _cd(String prefix) {
    _prefix = prefix;
    _load(reset: true);
  }

  String _objPath(String key) => '${widget.base}/objects/${Uri.encodeComponent(key)}';

  Future<void> _upload() async {
    final files = await pickFiles();
    if (files.isEmpty || !mounted) return;
    for (final f in files) {
      final key = '$_prefix${f.name}';
      setState(() => _progress = 0);
      final ok = await runAction(
        context,
        () => _c.rawOk(
          'PUT',
          _objPath(key),
          data: Stream.fromIterable([f.bytes]),
          headers: {'Content-Length': '${f.bytes.length}', 'Content-Type': _mimeFor(f.name)},
          onSendProgress: (s, t) {
            if (mounted && t > 0) setState(() => _progress = s / t);
          },
        ),
        blocking: false,
      );
      if (ok == null) break;
    }
    if (!mounted) return;
    setState(() => _progress = null);
    showToast(context, context.tr('Upload complete', '上传完成'));
    await _load(reset: true);
  }

  Future<void> _newFolder() async {
    final name = await promptText(context, title: context.tr('Folder name', '文件夹名称'));
    if (name == null || name.trim().isEmpty) return;
    // Folders are implicit in R2: navigate into the prefix; it appears once a file is uploaded.
    _cd('$_prefix${name.trim().replaceAll('/', '')}/');
  }

  Future<void> _download(Map<String, dynamic> o) async {
    final key = o['key'] as String;
    final r = await runAction(context, () => _c.rawOk('GET', _objPath(key)));
    if (r == null || !mounted) return;
    await saveBytes(
      context,
      fileName: key.split('/').last,
      bytes: r.bytes,
      mimeType: r.header('content-type') ?? 'application/octet-stream',
    );
  }

  Future<void> _preview(Map<String, dynamic> o) async {
    final key = o['key'] as String;
    final size = (o['size'] as num?)?.toInt() ?? 0;
    final ct = ((o['http_metadata'] as Map?)?['contentType'] as String?) ?? _mimeFor(key);
    final isImage = ct.startsWith('image/');
    final isText =
        ct.startsWith('text/') ||
        ct.contains('json') ||
        ct.contains('javascript') ||
        ct.contains('xml') ||
        ct.contains('yaml');
    if ((!isImage && !isText) || size > 5 * 1024 * 1024) {
      await showJsonDialog(context, o, title: key);
      return;
    }
    final r = await runAction(context, () => _c.rawOk('GET', _objPath(key)));
    if (r == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 760),
          child: Column(
            children: [
              ListTile(
                title: Text(key, style: const TextStyle(fontFamily: 'monospace')),
                subtitle: Text('$ct · ${formatBytes(size)}'),
                trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ),
              Expanded(
                child: isImage
                    ? InteractiveViewer(child: Image.memory(r.bytes, fit: BoxFit.contain))
                    : CodeView(text: utf8.decode(r.bytes, allowMalformed: true), language: languageFor(key)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(List<String> keys) async {
    final ok = await confirmDanger(
      context,
      title: context.tr('Delete ${keys.length} object(s)?', '删除 ${keys.length} 个对象？'),
      message: keys.take(10).join('\n'),
    );
    if (!ok || !mounted) return;
    await runAction(context, () async {
      for (final k in keys) {
        await _c.send('DELETE', _objPath(k));
      }
      return true;
    }, success: context.tr('Deleted', '已删除'));
    await _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final crumbs = _prefix.isEmpty ? <String>[] : _prefix.substring(0, _prefix.length - 1).split('/');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => _cd(''),
                        icon: const Icon(Icons.home_outlined, size: 18),
                        label: Text(widget.bucket),
                      ),
                      for (var i = 0; i < crumbs.length; i++) ...[
                        const Icon(Icons.chevron_right, size: 16),
                        TextButton(
                          onPressed: () => _cd('${crumbs.sublist(0, i + 1).join('/')}/'),
                          child: Text(crumbs[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: context.tr('New folder', '新建文件夹'),
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _newFolder,
              ),
              IconButton(
                tooltip: context.tr('Refresh', '刷新'),
                icon: const Icon(Icons.refresh),
                onPressed: () => _load(reset: true),
              ),
              FilledButton.tonalIcon(
                onPressed: _progress == null ? _upload : null,
                icon: const Icon(Icons.upload),
                label: Text(context.tr('Upload', '上传')),
              ),
            ],
          ),
        ),
        if (_progress != null) LinearProgressIndicator(value: _progress),
        if (_error != null)
          Expanded(
            child: ErrorView(error: _error!, onRetry: () => _load(reset: true)),
          )
        else
          Expanded(
            child: _loading && _objects.isEmpty && _folders.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : (_objects.isEmpty && _folders.isEmpty)
                ? EmptyView(icon: Icons.folder_open, title: context.tr('Empty', '空'))
                : ListView(
                    children: [
                      if (_prefix.isNotEmpty)
                        ListTile(
                          leading: const Icon(Icons.arrow_upward),
                          title: const Text('..'),
                          onTap: () {
                            final parts = _prefix.substring(0, _prefix.length - 1).split('/')..removeLast();
                            _cd(parts.isEmpty ? '' : '${parts.join('/')}/');
                          },
                        ),
                      for (final f in _folders)
                        ListTile(
                          leading: const Icon(Icons.folder, color: Color(0xFFF2A33A)),
                          title: Text(f.substring(_prefix.length)),
                          onTap: () => _cd(f),
                        ),
                      for (final o in _objects)
                        ListTile(
                          leading: Icon(_iconFor(o['key'] as String)),
                          title: Text(
                            (o['key'] as String).substring(_prefix.length),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${formatBytes(o['size'] as num?)} · ${formatDate(o['last_modified'])}${o['storage_class'] != null ? ' · ${o['storage_class']}' : ''}',
                          ),
                          onTap: () => _preview(o),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'download') _download(o);
                              if (v == 'info') showJsonDialog(context, o, title: o['key'] as String);
                              if (v == 'copy') copyText(context, o['key'] as String);
                              if (v == 'delete') _delete([o['key'] as String]);
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(value: 'download', child: Text(context.tr('Download', '下载'))),
                              PopupMenuItem(value: 'info', child: Text(context.tr('Details', '详情'))),
                              PopupMenuItem(value: 'copy', child: Text(context.tr('Copy key', '复制键名'))),
                              PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'))),
                            ],
                          ),
                        ),
                      if (_cursor != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Center(
                            child: OutlinedButton(
                              onPressed: _loading ? null : _load,
                              child: Text(context.tr('Load more', '加载更多')),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
      ],
    );
  }
}

IconData _iconFor(String key) {
  final k = key.toLowerCase();
  if (RegExp(r'\.(png|jpe?g|gif|webp|svg|avif|ico)$').hasMatch(k)) return Icons.image_outlined;
  if (RegExp(r'\.(mp4|mov|webm|mkv)$').hasMatch(k)) return Icons.movie_outlined;
  if (RegExp(r'\.(mp3|wav|flac|ogg)$').hasMatch(k)) return Icons.audiotrack_outlined;
  if (RegExp(r'\.(zip|gz|tar|7z|rar|zst)$').hasMatch(k)) return Icons.archive_outlined;
  if (RegExp(r'\.(js|ts|json|html|css|xml|ya?ml|md|txt|csv)$').hasMatch(k)) return Icons.description_outlined;
  return Icons.insert_drive_file_outlined;
}

String _mimeFor(String name) {
  final n = name.toLowerCase();
  const map = {
    '.html': 'text/html',
    '.htm': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.mjs': 'application/javascript',
    '.json': 'application/json',
    '.txt': 'text/plain',
    '.md': 'text/markdown',
    '.csv': 'text/csv',
    '.xml': 'application/xml',
    '.yaml': 'application/yaml',
    '.yml': 'application/yaml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.avif': 'image/avif',
    '.ico': 'image/x-icon',
    '.pdf': 'application/pdf',
    '.zip': 'application/zip',
    '.mp4': 'video/mp4',
    '.webm': 'video/webm',
    '.mp3': 'audio/mpeg',
    '.wasm': 'application/wasm',
  };
  for (final e in map.entries) {
    if (n.endsWith(e.key)) return e.value;
  }
  return 'application/octet-stream';
}

class _BucketSettings extends ConsumerWidget {
  const _BucketSettings({required this.base});

  final String base;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ApiQuery<(Map<String, dynamic>?, Object?, Object?, Map<String, dynamic>?)>(
      cacheKey: 'r2-settings:$base',
      load: (c) async {
        Future<Object?> safe(String p) => c.get(p).catchError((_) => null);
        final info = await safe(base);
        final cors = await safe('$base/cors');
        final lifecycle = await safe('$base/lifecycle');
        final managed = await safe('$base/domains/managed');
        return (
          info is Map ? Map<String, dynamic>.from(info) : null,
          cors,
          lifecycle,
          managed is Map ? Map<String, dynamic>.from(managed) : null,
        );
      },
      builder: (context, data, h) {
        final (info, cors, lifecycle, managed) = data;
        final c = ref.read(clientProvider)!;
        Future<void> editJson(String title, String path, Object? current) async {
          final text = await promptText(
            context,
            title: title,
            initial: prettyJson(current ?? {}),
            multiline: true,
            monospace: true,
            confirmLabel: context.tr('Save', '保存'),
          );
          if (text == null || !context.mounted) return;
          await runAction(context, () => c.send('PUT', path, data: text), success: context.tr('Saved', '已保存'));
          await h.reload();
        }

        return ContentList(
          onRefresh: h.reload,
          children: [
            if (info != null)
              SectionCard(
                title: context.tr('Bucket', '存储桶'),
                children: [
                  for (final e in info.entries.where((e) => e.value is! Map && e.value is! List))
                    InfoRow(e.key, '${e.value}'),
                ],
              ),
            SectionCard(
              title: context.tr('Public access (r2.dev)', '公共访问（r2.dev）'),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Allow access via r2.dev subdomain', '允许通过 r2.dev 子域名访问')),
                  subtitle: managed?['domain'] == null ? null : Text('https://${managed!['domain']}'),
                  value: managed?['enabled'] == true,
                  onChanged: managed == null
                      ? null
                      : (v) async {
                          await runAction(context, () => c.put('$base/domains/managed', data: {'enabled': v}));
                          await h.reload();
                        },
                ),
              ],
            ),
            SectionCard(
              title: 'CORS',
              trailing: TextButton(
                onPressed: () => editJson('CORS', '$base/cors', cors ?? {'rules': []}),
                child: Text(context.tr('Edit', '编辑')),
              ),
              children: [JsonTreeView(cors ?? {}, shrinkWrap: true)],
            ),
            SectionCard(
              title: context.tr('Lifecycle rules', '生命周期规则'),
              trailing: TextButton(
                onPressed: () =>
                    editJson(context.tr('Lifecycle rules', '生命周期规则'), '$base/lifecycle', lifecycle ?? {'rules': []}),
                child: Text(context.tr('Edit', '编辑')),
              ),
              children: [JsonTreeView(lifecycle ?? {}, shrinkWrap: true)],
            ),
          ],
        );
      },
    );
  }
}

class _CustomDomains extends ConsumerWidget {
  const _CustomDomains({required this.base});

  final String base;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'r2-domains:$base',
      load: (c) async {
        final r = await c.get('$base/domains/custom');
        final list = r is Map ? (r['domains'] as List? ?? const []) : (r as List? ?? const []);
        return list.cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      },
      builder: (context, domains, h) {
        final c = ref.read(clientProvider)!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.add),
                    label: Text(context.tr('Connect domain', '连接域名')),
                    onPressed: () async {
                      final zoneId = ref.read(currentZoneIdProvider);
                      final zone = ref.read(currentZoneProvider);
                      final domain = await promptText(
                        context,
                        title: context.tr('Domain', '域名'),
                        hint: 'files.${zone?['name'] ?? 'example.com'}',
                      );
                      if (domain == null || domain.trim().isEmpty || !context.mounted) return;
                      await runAction(
                        context,
                        () => c.post(
                          '$base/domains/custom',
                          data: {'domain': domain.trim(), 'zoneId': zoneId, 'enabled': true},
                        ),
                        success: context.tr('Domain connected', '域名已连接'),
                      );
                      await h.reload();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: domains.isEmpty
                  ? EmptyView(icon: Icons.language, title: context.tr('No custom domains', '没有自定义域'))
                  : ListView(
                      children: [
                        for (final d in domains)
                          ListTile(
                            leading: const Icon(Icons.language),
                            title: Text('${d['domain']}'),
                            subtitle: Text(
                              '${(d['status'] as Map?)?['ssl'] ?? ''} · ${(d['status'] as Map?)?['ownership'] ?? ''}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.link_off),
                              onPressed: () async {
                                final ok = await confirm(
                                  context,
                                  title: context.tr('Disconnect ${d['domain']}?', '断开 ${d['domain']}？'),
                                  destructive: true,
                                );
                                if (!ok || !context.mounted) return;
                                await runAction(context, () => c.delete('$base/domains/custom/${d['domain']}'));
                                await h.reload();
                              },
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
