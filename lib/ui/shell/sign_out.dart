import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/credential.dart';
import '../../core/session/session.dart';
import '../../core/util/tr.dart';
import '../widgets/feedback.dart';

/// Asks, then removes [p] from this device: an OAuth sign-in is also revoked
/// on Cloudflare, an API token is only forgotten. With no credential left
/// the app returns to the welcome page. [signOut] words it as signing out
/// (the sidebar's button) rather than removing (Settings).
Future<void> confirmRemoveProfile(BuildContext context, WidgetRef ref, Profile p, {bool signOut = false}) async {
  final ok = await confirmDanger(
    context,
    title: signOut
        ? context.tr('Sign out of "${p.name}"?', '退出“${p.name}”？')
        : context.tr('Remove credential?', '移除凭据？'),
    message: p.kind == AuthKind.oauth
        ? context.tr(
            '"${p.name}" will be signed out and Cirrus\'s access to the account revoked.',
            '“${p.name}” 将退出登录，并撤销 Cirrus 对该账户的授权。',
          )
        : context.tr(
            '"${p.name}" will be removed from this device. The token itself is not revoked.',
            '“${p.name}” 将从本设备移除，Token 本身不会被吊销。',
          ),
    confirmLabel: signOut ? context.tr('Sign out', '退出登录') : context.tr('Remove', '移除'),
  );
  if (!ok) return;
  await ref.read(profilesProvider.notifier).remove(p.id);
  if (context.mounted && (ref.read(profilesProvider).value ?? []).isEmpty) {
    context.go('/welcome');
  }
}
