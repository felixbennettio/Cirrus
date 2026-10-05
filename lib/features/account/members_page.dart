import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session/session.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';

class MembersPage extends ConsumerWidget {
  const MembersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: context.tr('Members', '成员'),
      builder: (context, accountId) {
        final base = '/accounts/$accountId/members';
        return ApiQuery<(List<Map<String, dynamic>>, List<Map<String, dynamic>>)>(
          cacheKey: 'members:$accountId',
          frame: (w) => PageScaffold(title: context.tr('Members', '成员'), body: w),
          load: (c) async {
            final members = await c.list(base, perPage: 50);
            final roles = await c.list('/accounts/$accountId/roles', perPage: 50).catchError((_) => <Map<String, dynamic>>[]);
            return (members, roles);
          },
          builder: (context, data, h) {
            final (members, roles) = data;
            final c = ref.read(clientProvider)!;
            Future<void> editRoles(Map<String, dynamic>? member) async {
              final email = TextEditingController();
              final current = {for (final r in ((member?['roles'] as List?) ?? const []).cast<Map>()) r['id'] as String};
              final selected = {...current};
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => StatefulBuilder(
                  builder: (ctx, setState) => AlertDialog(
                    title: Text(member == null ? ctx.tr('Invite member', '邀请成员') : ctx.tr('Edit roles', '编辑角色')),
                    content: SizedBox(
                      width: 520,
                      height: 480,
                      child: Column(
                        children: [
                          if (member == null)
                            TextField(
                              controller: email,
                              decoration: InputDecoration(labelText: ctx.tr('Email', '邮箱'), border: const OutlineInputBorder()),
                            ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView(
                              children: [
                                for (final r in roles)
                                  CheckboxListTile(
                                    dense: true,
                                    value: selected.contains(r['id']),
                                    title: Text('${r['name']}'),
                                    subtitle: Text('${r['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                                    onChanged: (v) => setState(() => v == true ? selected.add(r['id'] as String) : selected.remove(r['id'])),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(member == null ? ctx.tr('Invite', '邀请') : ctx.tr('Save', '保存'))),
                    ],
                  ),
                ),
              );
              final mail = email.text.trim();
              email.dispose();
              if (ok != true || selected.isEmpty || !context.mounted) return;
              if (member == null) {
                if (mail.isEmpty) return;
                await runAction(context, () => c.post(base, data: {'email': mail, 'roles': selected.toList(), 'status': 'pending'}), success: context.tr('Invitation sent', '邀请已发送'));
              } else {
                await runAction(
                  context,
                  () => c.put('$base/${member['id']}', data: {
                    'roles': [for (final id in selected) {'id': id}],
                  }),
                  success: context.tr('Roles updated', '角色已更新'),
                );
              }
              await h.reload();
            }

            return PageScaffold(
              title: context.tr('Members', '成员'),
              actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload)],
              floatingActionButton: FloatingActionButton.extended(
                icon: const Icon(Icons.person_add_alt),
                label: Text(context.tr('Invite', '邀请')),
                onPressed: () => editRoles(null),
              ),
              body: ListView.separated(
                padding: const EdgeInsets.only(bottom: 96, top: 8),
                itemCount: members.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                itemBuilder: (context, i) {
                  final m = members[i];
                  final user = m['user'] as Map? ?? const {};
                  final name = [user['first_name'], user['last_name']].whereType<String>().join(' ');
                  final roleNames = ((m['roles'] as List?) ?? const []).map((r) => (r as Map)['name']).join(', ');
                  return ListTile(
                    leading: CircleAvatar(child: Text((user['email'] as String? ?? '?').characters.first.toUpperCase())),
                    title: Text('${user['email'] ?? m['email'] ?? m['id']}'),
                    subtitle: Text([
                      if (name.isNotEmpty) name,
                      if (roleNames.isNotEmpty) roleNames,
                      if (user['two_factor_authentication_enabled'] == true) '2FA ✓',
                    ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusChip('${m['status']}', tone: StatusChip.toneFor(m['status'] == 'accepted' ? 'active' : m['status'] as String?)),
                        PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'roles') {
                              await editRoles(m);
                            } else if (v == 'json') {
                              await showJsonDialog(context, m);
                            } else if (v == 'remove') {
                              final ok = await confirmDanger(
                                context,
                                title: context.tr('Remove member?', '移除成员？'),
                                message: '${user['email']}',
                                confirmLabel: context.tr('Remove', '移除'),
                              );
                              if (!ok || !context.mounted) return;
                              await runAction(context, () => c.delete('$base/${m['id']}'), success: context.tr('Removed', '已移除'));
                              await h.reload();
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(value: 'roles', child: Text(context.tr('Edit roles', '编辑角色'))),
                            PopupMenuItem(value: 'json', child: Text(context.tr('Details', '详情'))),
                            PopupMenuItem(value: 'remove', child: Text(context.tr('Remove', '移除'))),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
