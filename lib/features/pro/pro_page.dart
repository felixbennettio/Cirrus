import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/billing/billing.dart';
import '../../core/session/session.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/common.dart';
import 'pro_features.dart';

/// Explains Cirrus Pro and offers the purchase. [feature] is what the user
/// just tried to open, if any.
class ProPaywall extends ConsumerWidget {
  const ProPaywall({super.key, this.feature});

  final ProFeature? feature;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pro = ref.watch(proProvider);
    final ctl = ref.read(proProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final product = pro.product;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.workspace_premium, size: 56, color: scheme.primary),
              const SizedBox(height: 12),
              Text(
                'Cirrus Pro',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                feature == null
                    ? context.tr('One purchase, yours for good.', '一次购买，永久使用。')
                    : context.tr(
                        '${feature!.label.en} is part of Cirrus Pro.',
                        '「${feature!.label.zh}」属于 Cirrus Pro 功能。',
                      ),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              for (final f in ProFeature.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(f.icon, size: 20, color: f == feature ? scheme.primary : scheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          f.label.of(context),
                          style: f == feature ? const TextStyle(fontWeight: FontWeight.w600) : null,
                        ),
                      ),
                      Icon(Icons.check, size: 18, color: scheme.primary),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              if (pro.unlocked)
                FilledButton.tonalIcon(
                  onPressed: null,
                  icon: const Icon(Icons.verified),
                  label: Text(context.tr('Cirrus Pro is unlocked', '已解锁 Cirrus Pro')),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                )
              else
                FilledButton.icon(
                  onPressed: pro.busy || product == null ? null : ctl.buy,
                  icon: pro.busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lock_open),
                  label: Text(
                    product != null
                        ? context.tr('Unlock for ${product.price}', '以 ${product.price} 解锁')
                        : pro.storeAvailable
                        ? context.tr('Loading…', '正在加载…')
                        : context.tr('Store unavailable', '商店暂不可用'),
                  ),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
              const SizedBox(height: 8),
              if (!pro.unlocked)
                TextButton(
                  onPressed: pro.busy ? null : ctl.restore,
                  child: Text(context.tr('Restore purchase', '恢复购买')),
                ),
              if (pro.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  pro.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                context.tr(
                  'A one-time purchase, not a subscription. Paid through ${_storeName(ref)}; restore it on any device signed in to the same account.',
                  '一次性购买，不是订阅。通过 ${_storeName(ref)} 付款，在登录同一账号的设备上都可以恢复购买。',
                ),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _storeName(WidgetRef ref) => switch (ref.read(storeChannelProvider)) {
    StoreChannel.googlePlay => 'Google Play',
    _ => 'App Store',
  };
}

/// A whole page shown in place of a Pro section.
class ProPaywallPage extends StatelessWidget {
  const ProPaywallPage({super.key, required this.feature});

  final ProFeature feature;

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: feature.label.of(context),
    body: ProPaywall(feature: feature),
  );
}

/// Shows the paywall in a dialog. Returns whether Pro is available
/// afterwards (it may have just been bought).
Future<bool> requirePro(BuildContext context, WidgetRef ref, ProFeature feature) async {
  if (ref.read(proProvider).hasPro) return true;
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: Stack(
          children: [
            ProPaywall(feature: feature),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
            ),
          ],
        ),
      ),
    ),
  );
  return ref.read(proProvider).hasPro;
}

/// Lets the first credential through and asks for Pro for more.
class CredentialGate extends ConsumerWidget {
  const CredentialGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPro = ref.watch(proProvider.select((s) => s.hasPro));
    final count = ref.watch(profilesProvider).value?.length ?? 0;
    if (hasPro || count == 0) return child;
    return Scaffold(
      appBar: AppBar(title: Text(ProFeature.credentials.label.of(context))),
      body: const ProPaywall(feature: ProFeature.credentials),
    );
  }
}
