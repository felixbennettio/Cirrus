import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/cache/query_cache.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';
import '../../ui/widgets/glass.dart';

String _projects(String accountId) => '/accounts/$accountId/pages/projects';

void _open(String? url) {
  if (url == null || url.isEmpty) return;
  launchUrl(Uri.parse(url.startsWith('http') ? url : 'https://$url'), mode: LaunchMode.externalApplication);
}

class PagesListPage extends ConsumerWidget {
  const PagesListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: 'Pages',
      builder: (context, accountId) => PageScaffold(
        title: 'Pages',
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: Text(context.tr('Create project', '创建项目')),
          onPressed: () async {
            final name = await promptText(
              context,
              title: context.tr('New Pages project (direct upload)', '新建 Pages 项目（直接上传）'),
              hint: 'my-site',
            );
            if (name == null || name.trim().isEmpty || !context.mounted) return;
            final c = ref.read(clientProvider)!;
            final r = await runAction(
              context,
              () => c.send('POST', _projects(accountId), data: {'name': name.trim(), 'production_branch': 'main'}),
              success: context.tr('Project created', '项目已创建'),
            );
            if (r != null) QueryCache.instance.invalidate('pages:');
            if (r != null && context.mounted) context.push('/pages/${Uri.encodeComponent(name.trim())}');
          },
        ),
        body: ApiQuery<List<Map<String, dynamic>>>(
          cacheKey: 'pages:$accountId',
          load: (c) => c.list(_projects(accountId), perPage: 10, maxItems: 1000),
          empty: EmptyView(icon: Icons.web, title: context.tr('No Pages projects', '没有 Pages 项目')),
          builder: (context, projects, h) => RefreshIndicator(
            onRefresh: h.reload,
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 96, top: 8),
              itemCount: projects.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, i) {
                final p = projects[i];
                final latest = p['latest_deployment'] as Map? ?? const {};
                final stage = latest['latest_stage'] as Map? ?? const {};
                final trigger = ((latest['deployment_trigger'] as Map?)?['metadata'] as Map?) ?? const {};
                final source = p['source'] as Map?;
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.web)),
                  title: Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    [
                      p['subdomain'],
                      if (source != null)
                        '${(source['config'] as Map?)?['owner'] ?? ''}/${(source['config'] as Map?)?['repo_name'] ?? ''}',
                      if (trigger['branch'] != null) '⎇ ${trigger['branch']}',
                      if (latest['created_on'] != null) formatRelative(latest['created_on'], zh: context.isZh),
                    ].whereType<String>().join(' · '),
                  ),
                  trailing: stage.isEmpty
                      ? null
                      : StatusChip('${stage['status']}', tone: StatusChip.toneFor(stage['status'] as String?)),
                  onTap: () => context.push('/pages/${Uri.encodeComponent(p['name'] as String)}'),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class PagesProjectPage extends ConsumerWidget {
  const PagesProjectPage({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: name,
      builder: (context, accountId) => DefaultTabController(
        length: 4,
        child: PageScaffold(
          title: name,
          subtitle: 'Pages',
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) async {
                final c = ref.read(clientProvider)!;
                final base = '${_projects(accountId)}/${Uri.encodeComponent(name)}';
                if (v == 'purge') {
                  await runAction(
                    context,
                    () => c.post('$base/purge_build_cache'),
                    success: context.tr('Build cache purged', '构建缓存已清除'),
                  );
                } else if (v == 'delete') {
                  final ok = await confirmDanger(
                    context,
                    title: context.tr('Delete project?', '删除项目？'),
                    message: context.tr(
                      'All deployments and domains of $name will be removed.',
                      '$name 的所有部署和域名都将被删除。',
                    ),
                    typeToConfirm: name,
                  );
                  if (!ok || !context.mounted) return;
                  final r = await runAction(
                    context,
                    () => c.send('DELETE', base),
                    success: context.tr('Deleted', '已删除'),
                  );
                  if (r != null && context.mounted) {
                    QueryCache.instance.invalidate('pages:');
                    context.go('/pages');
                  }
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'purge', child: Text(context.tr('Purge build cache', '清除构建缓存'))),
                PopupMenuItem(value: 'delete', child: Text(context.tr('Delete project', '删除项目'))),
              ],
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: context.tr('Deployments', '部署')),
              Tab(text: context.tr('Custom domains', '自定义域')),
              Tab(text: context.tr('Settings', '设置')),
              const Tab(text: 'JSON'),
            ],
          ),
          body: TabBarView(
            children: [
              _Deployments(accountId: accountId, project: name),
              _Domains(accountId: accountId, project: name),
              _Settings(accountId: accountId, project: name),
              ApiQuery<Object?>(
                cacheKey: 'pages-project:$accountId:$name',
                load: (c) => c.get('${_projects(accountId)}/${Uri.encodeComponent(name)}'),
                builder: (context, p, _) => JsonTreeView(p),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Deployments extends ConsumerWidget {
  const _Deployments({required this.accountId, required this.project});

  final String accountId;
  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = '${_projects(accountId)}/${Uri.encodeComponent(project)}/deployments';
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'pages-deployments:$accountId:$project',
      load: (c) => c.list(base, perPage: 25, maxItems: 100),
      builder: (context, deps, h) {
        final c = ref.read(clientProvider)!;
        return RefreshIndicator(
          onRefresh: h.reload,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: deps.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = deps[i];
              final stage = d['latest_stage'] as Map? ?? const {};
              final meta = ((d['deployment_trigger'] as Map?)?['metadata'] as Map?) ?? const {};
              final id = d['id'] as String;
              return ListTile(
                leading: Icon(d['environment'] == 'production' ? Icons.public : Icons.preview_outlined),
                title: Text(
                  (meta['commit_message'] as String?)?.split('\n').first ?? id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    d['environment'],
                    if (meta['branch'] != null) '⎇ ${meta['branch']}',
                    if (meta['commit_hash'] != null) (meta['commit_hash'] as String).substring(0, 7),
                    formatRelative(d['created_on'], zh: context.isZh),
                  ].whereType<String>().join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusChip(
                      '${stage['name'] ?? ''} ${stage['status'] ?? ''}'.trim(),
                      tone: StatusChip.toneFor(stage['status'] as String?),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        switch (v) {
                          case 'open':
                            _open(d['url'] as String?);
                          case 'logs':
                            await showAppDialog<void>(
                              context: context,
                              builder: (_) => _LogsDialog(path: '$base/$id/history/logs'),
                            );
                          case 'retry':
                            await runAction(
                              context,
                              () => c.post('$base/$id/retry'),
                              success: context.tr('Retry started', '已开始重试'),
                            );
                            await h.reload();
                          case 'rollback':
                            final ok = await confirm(
                              context,
                              title: context.tr('Roll back production to this deployment?', '将生产环境回滚到此部署？'),
                            );
                            if (!ok || !context.mounted) return;
                            await runAction(
                              context,
                              () => c.post('$base/$id/rollback'),
                              success: context.tr('Rolled back', '已回滚'),
                            );
                            await h.reload();
                          case 'delete':
                            final ok = await confirmDanger(
                              context,
                              title: context.tr('Delete deployment?', '删除部署？'),
                              message: id,
                            );
                            if (!ok || !context.mounted) return;
                            await runAction(context, () => c.send('DELETE', '$base/$id', query: {'force': true}));
                            await h.reload();
                          case 'json':
                            await showJsonDialog(context, d);
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(value: 'open', child: Text(context.tr('Open', '打开'))),
                        PopupMenuItem(value: 'logs', child: Text(context.tr('Build logs', '构建日志'))),
                        PopupMenuItem(value: 'retry', child: Text(context.tr('Retry', '重试'))),
                        if (d['environment'] == 'production')
                          PopupMenuItem(value: 'rollback', child: Text(context.tr('Rollback to this', '回滚到此版本'))),
                        PopupMenuItem(value: 'json', child: Text(context.tr('Details', '详情'))),
                        PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'))),
                      ],
                    ),
                  ],
                ),
                onTap: () => _open(d['url'] as String?),
              );
            },
          ),
        );
      },
    );
  }
}

class _LogsDialog extends StatelessWidget {
  const _LogsDialog({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 760),
        child: Column(
          children: [
            ListTile(
              title: Text(context.tr('Build logs', '构建日志')),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ),
            Expanded(
              child: ApiQuery<Object?>(
                cacheKey: 'logs:$path',
                cache: false,
                load: (c) => c.get(path),
                builder: (context, data, _) {
                  final lines = ((data as Map?)?['data'] as List? ?? const []).cast<Map>();
                  return Container(
                    color: Colors.black,
                    child: ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: lines.length,
                      itemBuilder: (context, i) => Text(
                        '${lines[i]['line']}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFD0D0D0)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Domains extends ConsumerWidget {
  const _Domains({required this.accountId, required this.project});

  final String accountId;
  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = '${_projects(accountId)}/${Uri.encodeComponent(project)}/domains';
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'pages-domains:$accountId:$project',
      load: (c) => c.list(base, paginate: false),
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
                    label: Text(context.tr('Add domain', '添加域名')),
                    onPressed: () async {
                      final name = await promptText(
                        context,
                        title: context.tr('Custom domain', '自定义域名'),
                        hint: 'www.example.com',
                      );
                      if (name == null || name.trim().isEmpty || !context.mounted) return;
                      await runAction(
                        context,
                        () => c.post(base, data: {'name': name.trim()}),
                        success: context.tr('Domain added', '域名已添加'),
                      );
                      await h.reload();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final d in domains)
                    ListTile(
                      leading: const Icon(Icons.language),
                      title: Text('${d['name']}'),
                      subtitle: Text(
                        '${(d['validation_data'] as Map?)?['status'] ?? ''} · ${(d['verification_data'] as Map?)?['status'] ?? ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StatusChip('${d['status']}', tone: StatusChip.toneFor(d['status'] as String?)),
                          IconButton(
                            tooltip: context.tr('Retry validation', '重新验证'),
                            icon: const Icon(Icons.refresh),
                            onPressed: () async {
                              await runAction(context, () => c.patch('$base/${d['name']}'));
                              await h.reload();
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await confirmDanger(
                                context,
                                title: context.tr('Remove domain?', '移除域名？'),
                                message: '${d['name']}',
                              );
                              if (!ok || !context.mounted) return;
                              await runAction(context, () => c.delete('$base/${d['name']}'));
                              await h.reload();
                            },
                          ),
                        ],
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

class _Settings extends ConsumerWidget {
  const _Settings({required this.accountId, required this.project});

  final String accountId;
  final String project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = '${_projects(accountId)}/${Uri.encodeComponent(project)}';
    return ApiQuery<Map<String, dynamic>>(
      cacheKey: 'pages-project:$accountId:$project:settings',
      load: (c) async => Map<String, dynamic>.from(await c.get(base) as Map),
      builder: (context, p, h) {
        final c = ref.read(clientProvider)!;
        final build = p['build_config'] as Map? ?? const {};
        final configs = p['deployment_configs'] as Map? ?? const {};
        Future<void> patch(Map<String, dynamic> body) async {
          await runAction(context, () => c.patch(base, data: body), success: context.tr('Saved', '已保存'));
          await h.reload();
        }

        Widget envCard(String env) {
          final cfg = configs[env] as Map? ?? const {};
          final vars = (cfg['env_vars'] as Map? ?? const {}).cast<String, dynamic>();
          return SectionCard(
            title: env == 'production'
                ? context.tr('Production variables', '生产环境变量')
                : context.tr('Preview variables', '预览环境变量'),
            trailing: TextButton.icon(
              icon: const Icon(Icons.add),
              label: Text(context.tr('Add', '添加')),
              onPressed: () async {
                final name = await promptText(context, title: context.tr('Variable name', '变量名'));
                if (name == null || name.trim().isEmpty || !context.mounted) return;
                final value = await promptText(context, title: name.trim(), label: context.tr('Value', '值'));
                if (value == null) return;
                await patch({
                  'deployment_configs': {
                    env: {
                      'env_vars': {
                        name.trim(): {'type': 'plain_text', 'value': value},
                      },
                    },
                  },
                });
              },
            ),
            children: [
              if (vars.isEmpty) Text(context.tr('No variables', '没有变量')),
              for (final e in vars.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.key, style: const TextStyle(fontFamily: 'monospace')),
                  subtitle: Text(
                    (e.value as Map?)?['type'] == 'secret_text' ? '••••••' : '${(e.value as Map?)?['value'] ?? ''}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => patch({
                      'deployment_configs': {
                        env: {
                          'env_vars': {e.key: null},
                        },
                      },
                    }),
                  ),
                ),
            ],
          );
        }

        return ContentList(
          onRefresh: h.reload,
          children: [
            SectionCard(
              title: context.tr('Build', '构建'),
              children: [
                InfoRow(context.tr('Production branch', '生产分支'), str(p['production_branch'])),
                InfoRow(context.tr('Build command', '构建命令'), str(build['build_command']), mono: true),
                InfoRow(context.tr('Output directory', '输出目录'), str(build['destination_dir']), mono: true),
                InfoRow(context.tr('Root directory', '根目录'), str(build['root_dir']), mono: true),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      final cmd = await promptText(
                        context,
                        title: context.tr('Build command', '构建命令'),
                        initial: build['build_command'] as String?,
                        monospace: true,
                      );
                      if (cmd == null || !context.mounted) return;
                      final out = await promptText(
                        context,
                        title: context.tr('Output directory', '输出目录'),
                        initial: build['destination_dir'] as String?,
                        monospace: true,
                      );
                      if (out == null) return;
                      await patch({
                        'build_config': {'build_command': cmd, 'destination_dir': out},
                      });
                    },
                    child: Text(context.tr('Edit build settings', '编辑构建设置')),
                  ),
                ),
              ],
            ),
            envCard('production'),
            envCard('preview'),
          ],
        );
      },
    );
  }
}
