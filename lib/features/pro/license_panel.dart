import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/licensing/license_api.dart';
import '../../core/licensing/license_config.dart';
import '../../core/licensing/license_controller.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';

/// The paywall's purchase section in licence builds: buy a key on the
/// website, then activate this device with it.
class LicensePanel extends ConsumerStatefulWidget {
  const LicensePanel({super.key});

  @override
  ConsumerState<LicensePanel> createState() => _LicensePanelState();
}

class _LicensePanelState extends ConsumerState<LicensePanel> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    FocusScope.of(context).unfocus();
    if (await ref.read(licenseProvider.notifier).activate(_key.text)) _key.clear();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text != null && text.isNotEmpty) _key.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final license = ref.watch(licenseProvider);
    final config = ref.watch(licenseConfigProvider);
    final platform = ref.watch(licensePlatformProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = license.active;
    if (active != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.tonalIcon(
            onPressed: null,
            icon: const Icon(Icons.verified),
            label: Text(context.tr('Activated', '已激活')),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
          const SizedBox(height: 8),
          Text(
            [
              if (active.payload.owner.isNotEmpty)
                context.tr('Licensed to ${active.payload.owner}', '授权给 ${active.payload.owner}'),
              licensePlatformLabel(active.payload.platform),
            ].join(' · '),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    final canActivate = config.canActivate && platform != null;
    final ready = canActivate && !license.loading && !license.busy;
    final error = canActivate ? license.error : const LicenseException(LicenseError.notConfigured);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _key,
          enabled: canActivate,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
          decoration: InputDecoration(
            labelText: context.tr('Licence key', '许可证密钥'),
            hintText: 'CIRRUS-XXXXX-XXXXX-XXXXX-XXXXX',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: context.tr('Paste', '粘贴'),
              icon: const Icon(Icons.content_paste),
              onPressed: canActivate ? _paste : null,
            ),
          ),
          onSubmitted: ready ? (_) => _activate() : null,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: ready ? _activate : null,
          icon: license.busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.key),
          label: Text(context.tr('Activate', '激活')),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: platform == null
              ? null
              : () => launchUrl(config.buyUri(platform), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.shopping_cart_outlined),
          label: Text(context.tr('Buy a licence', '购买许可证')),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        if (error != null) ...[const SizedBox(height: 12), LicenseErrorView(error: error)],
        const SizedBox(height: 12),
        Text(
          context.tr(
            'A one-time purchase, not a subscription. Each licence is for one platform and a set number of devices; deactivate it in Settings to move it to another device.',
            '一次性购买，不是订阅。每个许可证对应一个平台，可激活的设备数量有限；在设置中停用后即可转移到其他设备。',
          ),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// `Windows`, `Linux` or `Android` for a token's platform name.
String licensePlatformLabel(String name) => LicensePlatform.fromName(name)?.label ?? name;

/// A licence error in words, with the devices holding the licence and the
/// website's reset link when the activation limit is reached.
class LicenseErrorView extends ConsumerWidget {
  const LicenseErrorView({super.key, required this.error});

  final LicenseException error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final platform = ref.watch(licensePlatformProvider);
    final style = TextStyle(color: scheme.error);
    if (error.code != LicenseError.activationLimit) {
      return Text(licenseErrorText(context, error, platform), textAlign: TextAlign.center, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(licenseErrorText(context, error, platform), style: style),
        const SizedBox(height: 4),
        for (final d in error.devices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.devices_outlined, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(d.name.isEmpty ? context.tr('Unnamed device', '未命名设备') : d.name)),
                if (d.activatedAt != null)
                  Text(
                    formatDate(d.activatedAt, withTime: false),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        TextButton.icon(
          onPressed: () => launchUrl(ref.read(licenseConfigProvider).manageUri, mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(context.tr('Lost or reinstalled a device? Reset it on the website', '设备丢失或重装？在网站上重置')),
        ),
      ],
    );
  }
}

String licenseErrorText(BuildContext context, LicenseException e, LicensePlatform? platform) {
  final here = platform?.label ?? context.tr('this platform', '此平台');
  final other = platform == LicensePlatform.linux ? 'Windows' : 'Linux';
  return switch (e.code) {
    LicenseError.invalidKey => context.tr('This licence key is not valid. Check it and try again.', '许可证密钥无效，请检查后重试。'),
    LicenseError.wrongPlatform => context.tr(
      'This key is a licence for another platform (a $other licence, for example) and cannot be activated on $here. Buy a $here licence instead.',
      '此密钥是其他平台（例如 $other）的许可证，无法在 $here 上激活。请购买 $here 版许可证。',
    ),
    LicenseError.revoked => context.tr(
      'This licence has been revoked. Contact us if you think this is a mistake.',
      '此许可证已被吊销。如有疑问，请联系我们。',
    ),
    LicenseError.activationLimit => context.tr(
      'This licence is already active on as many devices as it allows. Deactivate it on one of them first:',
      '此许可证的激活设备数已达上限，请先在以下设备之一上停用：',
    ),
    LicenseError.notActivated => context.tr(
      'This device is no longer activated. Enter your licence key to activate it again.',
      '本设备的激活已失效，请重新输入许可证密钥激活。',
    ),
    LicenseError.network => context.tr(
      'Could not reach the licence server. Check your connection and try again.',
      '无法连接许可证服务器，请检查网络后重试。',
    ),
    LicenseError.invalidToken => context.tr(
      'The licence server\'s reply could not be verified. Update Cirrus and try again.',
      '无法验证许可证服务器的响应，请更新 Cirrus 后重试。',
    ),
    LicenseError.deviceUnavailable => context.tr(
      'Could not read this device\'s ID, so it cannot be activated.',
      '无法读取本设备的标识，因此无法激活。',
    ),
    LicenseError.notConfigured => context.tr(
      'Licence activation is not available in this build: it has no licence public key.',
      '此版本未内置许可证公钥，无法激活许可证。',
    ),
    _ => e.message.isNotEmpty ? e.message : context.tr('Something went wrong (${e.code}).', '操作失败（${e.code}）。'),
  };
}
