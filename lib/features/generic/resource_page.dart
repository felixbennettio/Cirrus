import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/cf_client.dart';
import '../../core/cache/query_cache.dart';
import '../../core/catalog/catalog.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';
import '../../ui/widgets/schema_form.dart';
import 'resource_specs.dart';

// ---------------------------------------------------------------------------
// Helpers

String fillPath(String template, Map<String, String?> ids, {String? id, String? parent}) {
  var t = template;
  if (id != null) t = t.replaceAll('{id}', Uri.encodeComponent(id));
  if (parent != null) t = t.replaceAll('{parent}', Uri.encodeComponent(parent));
  return expandPath(t, ids);
}

String? itemIdOf(ResourceSpec spec, Map<String, dynamic> item) {
  final v = pick(item, spec.idField) ?? item['id'];
  return v?.toString();
}

String itemTitleOf(ResourceSpec spec, Map<String, dynamic> item) {
  for (final f in spec.titleFields) {
    final v = pick(item, f);
    if (v != null && v.toString().isNotEmpty) return v.toString();
  }
  return itemIdOf(spec, item) ?? '—';
}

String _fmt(Object? v) {
  if (v == null) return '';
  if (v is bool) return v ? '✓' : '✗';
  if (v is List) {
    if (v.isEmpty) return '';
    if (v.every((e) => e is String || e is num)) return v.join(', ');
    return '${v.length} items';
  }
  if (v is Map) return '{…}';
  final s = v.toString();
  if (RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(s)) return formatDate(s);
  return s;
}

String itemSubtitleOf(ResourceSpec spec, Map<String, dynamic> item) {
  return spec.subtitleFields.map((f) => _fmt(pick(item, f))).where((s) => s.isNotEmpty).join(' · ');
}

(String, Tone)? itemStatusOf(ResourceSpec spec, Map<String, dynamic> item) {
  final f = spec.statusField;
  if (f == null) return null;
  final v = pick(item, f);
  if (v == null) return null;
  if (v is bool) {
    final positive = f == 'suspended' ? !v : v;
    final label = switch (f) {
      'enabled' => v ? 'enabled' : 'disabled',
      'suspended' => v ? 'suspended' : 'active',
      'allowed' => v ? 'allowed' : 'blocked',
      'success' => v ? 'success' : 'failed',
      'in_use' => v ? 'in use' : 'unused',
      _ => v.toString(),
    };
    return (label, positive ? Tone.good : Tone.warn);
  }
  return (v.toString(), StatusChip.toneFor(v.toString()));
}

/// Keeps only the fields an update body schema accepts.
Map<String, dynamic> filterForSchema(ApiCatalog catalog, Map<String, dynamic>? schema, Map<String, dynamic> item) {
  final s = catalog.resolve(schema);
  final allowed = <String>{};
  void collect(Map<String, dynamic> sch, int depth) {
    final r = catalog.resolve(sch);
    final props = r['properties'] as Map<String, dynamic>?;
    if (props != null) {
      for (final e in props.entries) {
        final ps = catalog.resolve(e.value as Map<String, dynamic>);
        if (ps['readOnly'] != true) allowed.add(e.key);
      }
    }
    if (depth > 3) return;
    for (final k in const ['oneOf', 'anyOf']) {
      final v = r[k];
      if (v is List) {
        for (final x in v) {
          collect(x as Map<String, dynamic>, depth + 1);
        }
      }
    }
  }

  collect(s, 0);
  if (allowed.isEmpty) return Map<String, dynamic>.from(item);
  const drop = {'id', 'created_at', 'created_on', 'modified_on', 'updated_at', 'uid'};
  return {
    for (final e in item.entries)
      if (allowed.contains(e.key) && !(drop.contains(e.key) && !allowed.contains(e.key))) e.key: e.value,
  };
}

const _secretKeys = ['client_secret', 'secret', 'token', 'value', 'tunnel_token', 'key'];

Map<String, String> _secretsIn(Object? result) {
  final out = <String, String>{};
  if (result is Map) {
    for (final k in _secretKeys) {
      final v = result[k];
      if (v is String && v.length >= 16) out[k] = v;
    }
    if (out.isNotEmpty) {
      for (final k in const ['client_id', 'sitekey', 'id', 'name']) {
        final v = result[k];
        if (v is String) out[k] = v;
      }
    }
  }
  return out;
}

Future<void> _showResultOrSecret(BuildContext context, String title, Object? result) async {
  final secrets = _secretsIn(result);
  if (secrets.isNotEmpty) {
    await showSecretDialog(context, title: title, values: secrets);
  } else if (result != null) {
    await showJsonDialog(context, result, title: title);
  }
}

Future<void> _openCreate(
  BuildContext context,
  WidgetRef ref,
  ResourceSpec spec, {
  String? parent,
  VoidCallback? onDone,
}) async {
  final catalog = await ref.read(catalogProvider.future);
  if (!context.mounted) return;
  final ids = ref.read(scopeIdsProvider);
  final path = fillPath(spec.createPath ?? spec.listPath, ids, parent: parent);
  final op = catalog.find('POST', path);
  final body = await showSchemaEditor(
    context,
    title: context.tr('Create · ${spec.title.en}', '新建 · ${spec.title.zh}'),
    catalog: catalog,
    schema: op?.body?.schema,
    submitLabel: context.tr('Create', '创建'),
    hiddenFields: spec.hiddenCreateFields,
  );
  if (body == null || !context.mounted) return;
  final client = ref.read(clientProvider)!;
  final res = await runAction(
    context,
    () => client.send('POST', path, data: body),
    success: context.tr('Created', '已创建'),
  );
  if (res == null) return;
  QueryCache.instance.invalidate(spec.listPath.split('{').first);
  onDone?.call();
  if (context.mounted) {
    final secrets = _secretsIn(res.result);
    if (secrets.isNotEmpty) {
      await showSecretDialog(context, title: context.tr('Created', '已创建'), values: secrets);
    }
  }
}

Future<bool> _openEdit(
  BuildContext context,
  WidgetRef ref,
  ResourceSpec spec,
  Map<String, dynamic> item, {
  String? parent,
}) async {
  final method = spec.updateMethod;
  if (method == null) return false;
  final catalog = await ref.read(catalogProvider.future);
  if (!context.mounted) return false;
  final ids = ref.read(scopeIdsProvider);
  final id = itemIdOf(spec, item)!;
  final path = fillPath(spec.resolvedItemPath, ids, id: id, parent: parent);
  final op = catalog.find(method, path);
  final body = await showSchemaEditor(
    context,
    title: context.tr('Edit · ${itemTitleOf(spec, item)}', '编辑 · ${itemTitleOf(spec, item)}'),
    catalog: catalog,
    schema: op?.body?.schema,
    initial: filterForSchema(catalog, op?.body?.schema, item),
  );
  if (body == null || !context.mounted) return false;
  final client = ref.read(clientProvider)!;
  final r = await runAction(
    context,
    () => client.send(method, path, data: body),
    success: context.tr('Saved', '已保存'),
  );
  QueryCache.instance.invalidate(spec.listPath.split('{').first);
  return r != null;
}

Future<bool> _delete(
  BuildContext context,
  WidgetRef ref,
  ResourceSpec spec,
  Map<String, dynamic> item, {
  String? parent,
}) async {
  final title = itemTitleOf(spec, item);
  final name = spec.dangerNameField == null ? null : pick(item, spec.dangerNameField!)?.toString();
  final ok = await confirmDanger(
    context,
    title: context.tr('Delete ${spec.title.en}?', '删除${spec.title.zh}？'),
    message: context.tr('"$title" will be permanently deleted.', '“$title” 将被永久删除。'),
    typeToConfirm: name,
  );
  if (!ok || !context.mounted) return false;
  final ids = ref.read(scopeIdsProvider);
  final path = fillPath(spec.resolvedItemPath, ids, id: itemIdOf(spec, item), parent: parent);
  final client = ref.read(clientProvider)!;
  final r = await runAction(context, () async {
    await client.send('DELETE', path);
    return true;
  }, success: context.tr('Deleted', '已删除'));
  QueryCache.instance.invalidate(spec.listPath.split('{').first);
  return r == true;
}

Future<void> runItemAction(
  BuildContext context,
  WidgetRef ref,
  ItemAction action, {
  Map<String, dynamic>? item,
  ResourceSpec? spec,
  String? parent,
  VoidCallback? onDone,
}) async {
  if (action.confirm) {
    final ok = await confirm(
      context,
      title: action.label.of(context),
      message: item == null || spec == null ? null : itemTitleOf(spec, item),
      destructive: action.danger,
    );
    if (!ok || !context.mounted) return;
  }
  final ids = ref.read(scopeIdsProvider);
  final id = item == null || spec == null ? null : itemIdOf(spec, item);
  final path = fillPath(action.path, ids, id: id, parent: parent);
  Object? body = item == null ? null : action.bodyBuilder?.call(item);
  if (action.withBody) {
    final catalog = await ref.read(catalogProvider.future);
    if (!context.mounted) return;
    final op = catalog.find(action.method, path);
    final b = await showSchemaEditor(
      context,
      title: action.label.of(context),
      catalog: catalog,
      schema: op?.body?.schema,
      submitLabel: context.tr('Run', '执行'),
    );
    if (b == null || !context.mounted) return;
    body = b;
  }
  final client = ref.read(clientProvider)!;
  final res = await runAction(context, () => client.send(action.method, path, data: body));
  if (res == null || !context.mounted) return;
  onDone?.call();
  if (action.showResult) {
    await _showResultOrSecret(context, action.label.of(context), res.result);
  } else {
    showToast(context, context.tr('Done', '完成'));
  }
}

// ---------------------------------------------------------------------------
// List

/// Embeddable list for a [ResourceSpec].
class ResourceListView extends ConsumerStatefulWidget {
  const ResourceListView({super.key, required this.spec, this.parentId, this.showToolbar = true});

  final ResourceSpec spec;
  final String? parentId;
  final bool showToolbar;

  @override
  ConsumerState<ResourceListView> createState() => _ResourceListViewState();
}

class _ResourceListViewState extends ConsumerState<ResourceListView> {
  String _q = '';

  ResourceSpec get spec => widget.spec;

  @override
  Widget build(BuildContext context) {
    final ids = ref.watch(scopeIdsProvider);
    if (spec.scope == SpecScope.account && ids['account_id'] == null) {
      return AccountRequired(builder: (_, _) => const SizedBox());
    }
    if (spec.scope == SpecScope.zone && ids['zone_id'] == null) {
      return ZoneRequired(builder: (_, _, _) => const SizedBox());
    }
    final path = fillPath(spec.listPath, ids, parent: widget.parentId);
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'list:$path',
      load: (c) => c.list(
        path,
        query: spec.listQuery,
        perPage: spec.perPage,
        paginate: spec.paginate,
        maxItems: 5000,
      ),
      builder: (context, items, handle) {
        final q = _q.toLowerCase();
        final filtered = q.isEmpty
            ? items
            : items.where((i) => i.toString().toLowerCase().contains(q)).toList();
        return Column(
          children: [
            if (widget.showToolbar)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(
                  children: [
                    Expanded(child: SearchField(onChanged: (v) => setState(() => _q = v.trim()))),
                    const SizedBox(width: 8),
                    Text('${filtered.length}', style: Theme.of(context).textTheme.labelLarge),
                    IconButton(
                      tooltip: context.tr('Refresh', '刷新'),
                      icon: const Icon(Icons.refresh),
                      onPressed: handle.reload,
                    ),
                    for (final a in spec.listActions)
                      IconButton(
                        tooltip: a.label.of(context),
                        icon: Icon(a.icon),
                        onPressed: () => runItemAction(context, ref, a, parent: widget.parentId, onDone: handle.reload),
                      ),
                    if (spec.canCreate)
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.add),
                        label: Text(context.tr('Create', '新建')),
                        onPressed: () => _openCreate(context, ref, spec, parent: widget.parentId, onDone: handle.reload),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: filtered.isEmpty
                  ? EmptyView(
                      icon: spec.icon,
                      title: context.tr('Nothing here yet', '暂无数据'),
                      subtitle: spec.canCreate ? context.tr('Use "Create" to add one.', '点击“新建”添加。') : null,
                    )
                  : RefreshIndicator(
                      onRefresh: handle.reload,
                      child: ListView.separated(
                        padding: const EdgeInsets.only(bottom: 80),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                        itemBuilder: (context, i) => _ResourceTile(
                          spec: spec,
                          item: filtered[i],
                          parentId: widget.parentId,
                          onChanged: handle.reload,
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _ResourceTile extends ConsumerWidget {
  const _ResourceTile({required this.spec, required this.item, required this.onChanged, this.parentId});

  final ResourceSpec spec;
  final Map<String, dynamic> item;
  final String? parentId;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = itemStatusOf(spec, item);
    final subtitle = itemSubtitleOf(spec, item);
    final id = itemIdOf(spec, item);
    final canOpen = id != null && parentId == null;
    return ListTile(
      leading: Icon(spec.icon, size: 22),
      title: Text(itemTitleOf(spec, item), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null) StatusChip(status.$1, tone: status.$2),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'json':
                  await showJsonDialog(context, item, title: itemTitleOf(spec, item));
                case 'copy':
                  await copyText(context, id ?? '');
                case 'edit':
                  if (await _openEdit(context, ref, spec, item, parent: parentId)) await onChanged();
                case 'delete':
                  if (await _delete(context, ref, spec, item, parent: parentId)) await onChanged();
                default:
                  if (v.startsWith('action:')) {
                    final a = spec.actions[int.parse(v.substring(7))];
                    if (context.mounted) {
                      await runItemAction(context, ref, a, item: item, spec: spec, parent: parentId, onDone: onChanged);
                    }
                  }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'json', child: _menu(Icons.data_object, context.tr('View JSON', '查看 JSON'))),
              if (id != null) PopupMenuItem(value: 'copy', child: _menu(Icons.copy, context.tr('Copy ID', '复制 ID'))),
              if (spec.updateMethod != null)
                PopupMenuItem(value: 'edit', child: _menu(Icons.edit_outlined, context.tr('Edit', '编辑'))),
              for (var i = 0; i < spec.actions.length; i++)
                PopupMenuItem(value: 'action:$i', child: _menu(spec.actions[i].icon, spec.actions[i].label.of(context))),
              if (spec.canDelete)
                PopupMenuItem(
                  value: 'delete',
                  child: _menu(Icons.delete_outline, context.tr('Delete', '删除'), color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ],
      ),
      onTap: () {
        if (canOpen && (spec.children.isNotEmpty || spec.itemPath != null || spec.updateMethod != null || spec.canDelete)) {
          context.push('/r/${spec.id}/${Uri.encodeComponent(id)}', extra: item);
        } else {
          showJsonDialog(context, item, title: itemTitleOf(spec, item));
        }
      },
    );
  }
}

Widget _menu(IconData icon, String label, {Color? color}) => Row(
  children: [
    Icon(icon, size: 18, color: color),
    const SizedBox(width: 12),
    Text(label, style: TextStyle(color: color)),
  ],
);

/// Full page for a spec (`/r/:specId`).
class ResourcePage extends StatelessWidget {
  const ResourcePage({super.key, required this.spec});

  final ResourceSpec spec;

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: spec.title.of(context),
      subtitle: spec.description?.of(context),
      body: ResourceListView(spec: spec),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail

class ResourceDetailPage extends ConsumerStatefulWidget {
  const ResourceDetailPage({super.key, required this.spec, required this.id, this.initial});

  final ResourceSpec spec;
  final String id;
  final Map<String, dynamic>? initial;

  @override
  ConsumerState<ResourceDetailPage> createState() => _ResourceDetailPageState();
}

class _ResourceDetailPageState extends ConsumerState<ResourceDetailPage> {
  int _reload = 0;

  ResourceSpec get spec => widget.spec;

  Future<Map<String, dynamic>> _load(CfClient c) async {
    final ids = ref.read(scopeIdsProvider);
    if (spec.hasItemPath) {
      try {
        final r = await c.get(fillPath(spec.resolvedItemPath, ids, id: widget.id));
        if (r is Map) return Map<String, dynamic>.from(r);
      } catch (e) {
        if (widget.initial == null) rethrow;
      }
    }
    return widget.initial ?? <String, dynamic>{'id': widget.id};
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.initial == null ? widget.id : itemTitleOf(spec, widget.initial!);
    final tabs = spec.children;
    final body = ApiQuery<Map<String, dynamic>>(
      cacheKey: 'detail:${spec.id}:${widget.id}:$_reload',
      load: _load,
      builder: (context, item, handle) {
        final overview = _DetailOverview(
          spec: spec,
          item: item,
          onEdit: spec.updateMethod == null
              ? null
              : () async {
                  if (await _openEdit(context, ref, spec, item)) setState(() => _reload++);
                },
          onDelete: !spec.canDelete
              ? null
              : () async {
                  if (await _delete(context, ref, spec, item) && context.mounted) context.pop();
                },
          onChanged: () => setState(() => _reload++),
        );
        if (tabs.isEmpty) return overview;
        return DefaultTabController(
          length: tabs.length + 1,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: context.tr('Overview', '概览')),
                  for (final t in tabs) Tab(text: t.title.of(context)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    overview,
                    for (final t in tabs) ResourceListView(spec: t, parentId: widget.id),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    return PageScaffold(title: title, subtitle: spec.title.of(context), body: body);
  }
}

class _DetailOverview extends ConsumerWidget {
  const _DetailOverview({
    required this.spec,
    required this.item,
    required this.onChanged,
    this.onEdit,
    this.onDelete,
  });

  final ResourceSpec spec;
  final Map<String, dynamic> item;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scalars = item.entries.where((e) => e.value is! Map && e.value is! List && e.value != null).toList();
    final status = itemStatusOf(spec, item);
    return ContentList(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (status != null) StatusChip(status.$1, tone: status.$2),
            if (onEdit != null)
              FilledButton.tonalIcon(onPressed: onEdit, icon: const Icon(Icons.edit_outlined), label: Text(context.tr('Edit', '编辑'))),
            for (final a in spec.actions)
              OutlinedButton.icon(
                onPressed: () => runItemAction(context, ref, a, item: item, spec: spec, onDone: onChanged),
                icon: Icon(a.icon, size: 18),
                label: Text(a.label.of(context)),
              ),
            if (onDelete != null)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(context.tr('Delete', '删除')),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (scalars.isNotEmpty)
          SectionCard(
            title: context.tr('Properties', '属性'),
            children: [
              for (final e in scalars)
                InfoRow(e.key, _fmt(e.value).isEmpty ? e.value.toString() : _fmt(e.value), copy: e.key.contains('id')),
            ],
          ),
        SectionCard(
          title: 'JSON',
          trailing: IconButton(
            icon: const Icon(Icons.open_in_full, size: 18),
            onPressed: () => showJsonDialog(context, item, title: itemTitleOf(spec, item)),
          ),
          children: [JsonTreeView(item, shrinkWrap: true, initiallyExpandedDepth: 1)],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Documents

class DocumentView extends ConsumerStatefulWidget {
  const DocumentView({super.key, required this.spec});

  final DocumentSpec spec;

  @override
  ConsumerState<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends ConsumerState<DocumentView> {
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final ids = ref.watch(scopeIdsProvider);
    final spec = widget.spec;
    if (spec.scope == SpecScope.account && ids['account_id'] == null) {
      return AccountRequired(builder: (_, _) => const SizedBox());
    }
    if (spec.scope == SpecScope.zone && ids['zone_id'] == null) {
      return ZoneRequired(builder: (_, _, _) => const SizedBox());
    }
    final path = expandPath(spec.path, ids);
    return ApiQuery<Object?>(
      cacheKey: 'doc:$path:$_reload',
      load: (c) => c.get(path),
      builder: (context, data, handle) {
        return ContentList(
          onRefresh: handle.reload,
          children: [
            if (spec.description != null)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(spec.description!.of(context))),
            Row(
              children: [
                if (spec.method != null)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(context.tr('Edit', '编辑')),
                    onPressed: () async {
                      final catalog = await ref.read(catalogProvider.future);
                      if (!context.mounted) return;
                      final op = catalog.find(spec.method!, path);
                      Map<String, dynamic>? body;
                      if (data is List) {
                        // List documents (e.g. split tunnels) are edited as JSON.
                        final text = await promptText(
                          context,
                          title: spec.title.of(context),
                          initial: prettyJson(data),
                          multiline: true,
                          monospace: true,
                          confirmLabel: context.tr('Save', '保存'),
                        );
                        if (text == null || !context.mounted) return;
                        final client = ref.read(clientProvider)!;
                        await runAction(
                          context,
                          () => client.send(spec.method!, path, data: text),
                          success: context.tr('Saved', '已保存'),
                        );
                        setState(() => _reload++);
                        return;
                      }
                      body = await showSchemaEditor(
                        context,
                        title: spec.title.of(context),
                        catalog: catalog,
                        schema: op?.body?.schema,
                        initial: data is Map
                            ? filterForSchema(catalog, op?.body?.schema, Map<String, dynamic>.from(data))
                            : null,
                      );
                      if (body == null || !context.mounted) return;
                      final client = ref.read(clientProvider)!;
                      await runAction(
                        context,
                        () => client.send(spec.method!, path, data: body),
                        success: context.tr('Saved', '已保存'),
                      );
                      setState(() => _reload++);
                    },
                  ),
                const Spacer(),
                IconButton(icon: const Icon(Icons.refresh), onPressed: handle.reload),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: data == null
                    ? Text(context.tr('Empty', '空'))
                    : JsonTreeView(data, shrinkWrap: true, initiallyExpandedDepth: 2),
              ),
            ),
          ],
        );
      },
    );
  }
}

class DocumentPage extends StatelessWidget {
  const DocumentPage({super.key, required this.spec});

  final DocumentSpec spec;

  @override
  Widget build(BuildContext context) =>
      PageScaffold(title: spec.title.of(context), body: DocumentView(spec: spec));
}

// ---------------------------------------------------------------------------
// Hubs

/// Grid of cards linking to specs and documents.
class ResourceHubPage extends StatelessWidget {
  const ResourceHubPage({
    super.key,
    required this.title,
    this.specs = const [],
    this.documents = const [],
    this.links = const [],
  });

  final String title;
  final List<ResourceSpec> specs;
  final List<DocumentSpec> documents;
  final List<HubLink> links;

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      for (final l in links) _HubCard(icon: l.icon, title: l.title.of(context), subtitle: l.subtitle?.of(context), onTap: () => context.push(l.path)),
      for (final s in specs)
        _HubCard(icon: s.icon, title: s.title.of(context), subtitle: s.group.of(context), onTap: () => context.push('/r/${s.id}')),
      for (final d in documents)
        _HubCard(icon: d.icon, title: d.title.of(context), subtitle: d.group.of(context), onTap: () => context.push('/doc/${d.id}')),
    ];
    return PageScaffold(
      title: title,
      body: ContentList(children: [ResponsiveGrid(minItemWidth: 250, children: cards)]),
    );
  }
}

class HubLink {
  const HubLink({required this.icon, required this.title, required this.path, this.subtitle});

  final IconData icon;
  final L10nText title;
  final L10nText? subtitle;
  final String path;
}

class _HubCard extends StatelessWidget {
  const _HubCard({required this.icon, required this.title, required this.onTap, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: scheme.onPrimaryContainer, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(subtitle!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tabs of lists/documents in one page (e.g. Access, Gateway, Devices).
class TabbedResourcesPage extends StatelessWidget {
  const TabbedResourcesPage({super.key, required this.title, required this.tabs});

  final String title;
  final List<Object> tabs; // ResourceSpec | DocumentSpec | (L10nText, Widget)

  @override
  Widget build(BuildContext context) {
    String label(Object t) => switch (t) {
      final ResourceSpec s => s.title.of(context),
      final DocumentSpec d => d.title.of(context),
      final (L10nText, Widget) p => p.$1.of(context),
      _ => '?',
    };
    Widget view(Object t) => switch (t) {
      final ResourceSpec s => ResourceListView(spec: s),
      final DocumentSpec d => DocumentView(spec: d),
      final (L10nText, Widget) p => p.$2,
      _ => const SizedBox(),
    };
    return DefaultTabController(
      length: tabs.length,
      child: PageScaffold(
        title: title,
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in tabs) Tab(text: label(t))],
        ),
        body: TabBarView(children: [for (final t in tabs) view(t)]),
      ),
    );
  }
}
