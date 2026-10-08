import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/credential.dart';
import '../../core/billing/billing.dart';
import '../../core/cache/query_cache.dart';
import '../../core/catalog/catalog.dart';
import '../../core/catalog/catalog_builder.dart';
import '../../core/licensing/license_controller.dart';
import '../../core/session/session.dart';
import '../../core/settings/app_settings.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/cirrus_theme.dart';
import '../../ui/shell/sign_out.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../onboarding/add_profile_page.dart';
import '../pro/license_panel.dart';
import '../pro/pro_page.dart';
import '../../ui/widgets/glass.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final ctl = ref.read(settingsProvider.notifier);
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final active = ref.watch(activeProfileProvider);
    final store = ref.watch(credentialStoreProvider);
    final catalog = ref.watch(catalogProvider);
    final pro = ref.watch(proProvider);
    return PageScaffold(
      title: context.tr('Settings', '设置'),
      body: ContentList(
        maxWidth: 820,
        children: [
          if (pro.enforced) _ProSection(pro: pro),
          SectionCard(
            title: context.tr('Credentials', '凭据'),
            subtitle: context.tr('Stored in the system keychain on this device.', '保存在本设备的系统钥匙串中。'),
            trailing: TextButton.icon(
              onPressed: () => context.push('/profiles/add'),
              icon: const Icon(Icons.add),
              label: Text(context.tr('Add', '添加')),
            ),
            children: [
              if (store.usingFallback)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    context.tr(
                      'No system keychain (Secret Service) is available, so credentials are stored in a file readable only by your user. Install/enable GNOME Keyring or KWallet for encrypted storage.',
                      '系统钥匙串（Secret Service）不可用，凭据被保存在仅当前用户可读的文件中。安装或启用 GNOME Keyring / KWallet 即可加密存储。',
                    ),
                    style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                ),
              for (final p in profiles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(p.id == active?.id ? Icons.check_circle : Icons.person_outline),
                  title: Text(p.name),
                  subtitle: Text(
                    p.kind == AuthKind.globalKey
                        ? 'Global API Key · ${p.email ?? ''} · ${p.secretHint}'
                        : '${p.kindLabel} · ${p.secretHint}',
                  ),
                  onTap: () => ctl.setActiveProfile(p.id),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'edit') {
                        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddProfilePage(editing: p)));
                      } else if (v == 'delete') {
                        await confirmRemoveProfile(context, ref, p);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'edit', child: Text(context.tr('Edit', '编辑'))),
                      PopupMenuItem(value: 'delete', child: Text(context.tr('Remove', '移除'))),
                    ],
                  ),
                ),
            ],
          ),
          SectionCard(
            title: context.tr('Appearance', '外观'),
            children: [
              const SizedBox(height: 4),
              Text(context.tr('Theme', '主题')),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(context.tr('System', '跟随系统')),
                    icon: const Icon(Icons.brightness_auto),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(context.tr('Light', '浅色')),
                    icon: const Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(context.tr('Dark', '深色')),
                    icon: const Icon(Icons.dark_mode),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (s) => ctl.setThemeMode(s.first),
              ),
              const SizedBox(height: 8),
              _DynamicColorTile(enabled: settings.dynamicColor),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr('Liquid glass', '液态玻璃效果')),
                subtitle: Text(
                  MediaQuery.highContrastOf(context)
                      ? context.tr('Off while high contrast is on.', '高对比度模式下不使用。')
                      : context.tr('Translucent, blurred app bars, sidebar and dialogs.', '半透明、带模糊效果的标题栏、侧边栏和对话框。'),
                ),
                value: settings.glassEnabled,
                onChanged: ctl.setLiquidGlass,
              ),
              const SizedBox(height: 8),
              Text(context.tr('Language', '语言')),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'system', label: Text(context.tr('System', '跟随系统'))),
                  const ButtonSegment(value: 'en', label: Text('English')),
                  const ButtonSegment(value: 'zh', label: Text('简体中文')),
                ],
                selected: {settings.localeCode ?? 'system'},
                onSelectionChanged: (s) => ctl.setLocale(s.first == 'system' ? null : s.first),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr('Compact sidebar', '紧凑侧边栏')),
                value: settings.compactSidebar,
                onChanged: (v) => ctl.update((s) => s.copyWith(compactSidebar: v)),
              ),
            ],
          ),
          SectionCard(
            title: context.tr('Security', '安全'),
            children: [
              _AppLockTile(enabled: settings.appLock),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.tr('Confirm write requests in the API console', '在 API 控制台发送写请求前确认')),
                subtitle: Text(context.tr('POST, PUT, PATCH and DELETE', 'POST、PUT、PATCH 和 DELETE')),
                value: settings.confirmMutations,
                onChanged: (v) => ctl.update((s) => s.copyWith(confirmMutations: v)),
              ),
            ],
          ),
          SectionCard(
            title: context.tr('API catalog', 'API 目录'),
            subtitle: context.tr(
              'Index of every Cloudflare API endpoint, generated from the official OpenAPI schema.',
              '由官方 OpenAPI 规范生成的全部 Cloudflare API 接口索引。',
            ),
            children: [
              catalog.when(
                data: (c) => Column(
                  children: [
                    InfoRow(context.tr('Endpoints', '接口数量'), formatNumber(c.operations.length)),
                    InfoRow(context.tr('Products', '产品数量'), formatNumber(c.byProduct.length)),
                    InfoRow(context.tr('Generated', '生成时间'), formatDate(c.generated?.toIso8601String())),
                  ],
                ),
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text(e.toString()),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: Text(context.tr('Update from Cloudflare', '从 Cloudflare 更新')),
                    onPressed: () => _refreshCatalog(context, ref),
                  ),
                  TextButton(
                    onPressed: () async {
                      await CatalogLoader.resetToBundled();
                      ref.invalidate(catalogProvider);
                    },
                    child: Text(context.tr('Use bundled version', '使用内置版本')),
                  ),
                ],
              ),
            ],
          ),
          SectionCard(
            title: context.tr('Data', '数据'),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cleaning_services_outlined),
                title: Text(context.tr('Clear cached data', '清除缓存数据')),
                subtitle: Text(context.tr('Cached lists are only used to render instantly.', '缓存仅用于加快页面显示。')),
                onTap: () async {
                  QueryCache.instance.clear();
                  await DiskCache.clear();
                  ref.invalidate(accountsProvider);
                  ref.invalidate(zonesProvider);
                  if (context.mounted) showToast(context, context.tr('Cache cleared', '缓存已清除'));
                },
              ),
            ],
          ),
          const _AboutCard(),
        ],
      ),
    );
  }

  Future<void> _refreshCatalog(BuildContext context, WidgetRef ref) async {
    final ok = await runAction(context, () async {
      final dio = Dio();
      final res = await dio.get<String>(openApiSchemaUrl, options: Options(responseType: ResponseType.plain));
      final raw = res.data ?? '';
      final built = await Isolate.run(() => buildCatalog(jsonDecode(raw) as Map<String, dynamic>));
      await CatalogLoader.saveRefreshed(built);
      return true;
    }, success: context.tr('API catalog updated', 'API 目录已更新'));
    if (ok == true) ref.invalidate(catalogProvider);
  }
}

/// Dynamic colour can only be switched on where the platform offers it; the
/// tile stays visible (disabled, with a hint) everywhere else.
class _DynamicColorTile extends ConsumerWidget {
  const _DynamicColorTile({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = CirrusTheme.of(context).dynamicColorAvailable;
    final android = Theme.of(context).platform == TargetPlatform.android;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.tr('Dynamic colour', '动态取色')),
      subtitle: Text(
        !available
            ? context.tr('Not available on this device: Cirrus uses its own colours.', '此设备不支持，使用 Cirrus 默认配色。')
            : android
            ? context.tr('Colours from your wallpaper.', '使用壁纸颜色。')
            : context.tr('Colours from the system accent colour.', '使用系统强调色。'),
      ),
      value: enabled && available,
      onChanged: available ? ref.read(settingsProvider.notifier).setDynamicColor : null,
    );
  }
}

class _AppLockTile extends ConsumerStatefulWidget {
  const _AppLockTile({required this.enabled});

  final bool enabled;

  @override
  ConsumerState<_AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends ConsumerState<_AppLockTile> {
  bool? _supported;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    var ok = false;
    if (!Platform.isLinux) {
      try {
        ok = await LocalAuthentication().isDeviceSupported();
      } catch (_) {}
    }
    if (mounted) setState(() => _supported = ok);
  }

  @override
  Widget build(BuildContext context) {
    final supported = _supported ?? false;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.tr('App lock', '应用锁')),
      subtitle: Text(
        supported
            ? context.tr('Require biometrics or device passcode to open Cirrus.', '打开 Cirrus 时需要生物识别或设备密码。')
            : context.tr('Not available on this device.', '此设备不支持。'),
      ),
      value: widget.enabled && supported,
      onChanged: !supported
          ? null
          : (v) async {
              try {
                final ok = await LocalAuthentication().authenticate(
                  localizedReason: context.tr('Confirm to change app lock', '确认以修改应用锁'),
                );
                if (ok) ref.read(settingsProvider.notifier).update((s) => s.copyWith(appLock: v));
              } catch (e) {
                if (context.mounted) showToast(context, e.toString(), error: true);
              }
            },
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.tr('About', '关于'),
      children: [
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snap) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/branding/cirrus_256.png', width: 40, height: 40),
            ),
            title: const Text('Cirrus'),
            subtitle: Text(
              '${context.tr('Version', '版本')} ${snap.data?.version ?? '…'} (${snap.data?.buildNumber ?? ''})',
            ),
          ),
        ),
        Text(
          context.tr(
            'Cirrus is an unofficial client and is not affiliated with, endorsed or sponsored by Cloudflare, Inc. "Cloudflare" is a trademark of Cloudflare, Inc.',
            'Cirrus 是非官方客户端，与 Cloudflare, Inc. 没有任何关联，也未获其认可或赞助。“Cloudflare”是 Cloudflare, Inc. 的商标。',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () =>
                  launchUrl(Uri.parse('https://developers.cloudflare.com/api/'), mode: LaunchMode.externalApplication),
              child: Text(context.tr('API documentation', 'API 文档')),
            ),
            TextButton(
              onPressed: () =>
                  launchUrl(Uri.parse('https://www.cloudflarestatus.com/'), mode: LaunchMode.externalApplication),
              child: Text(context.tr('Cloudflare status', 'Cloudflare 服务状态')),
            ),
            TextButton(
              onPressed: () => showLicensePage(context: context, applicationName: 'Cirrus'),
              child: Text(context.tr('Open-source licenses', '开源许可')),
            ),
          ],
        ),
      ],
    );
  }
}

/// Cirrus Pro status, purchase and restore (store and licence builds only).
class _ProSection extends ConsumerWidget {
  const _ProSection({required this.pro});

  final ProState pro;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(storeChannelProvider) == StoreChannel.license) return const _LicenseSection();
    final ctl = ref.read(proProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Cirrus Pro',
      subtitle: pro.unlocked
          ? context.tr('Unlocked on this device. Thank you!', '已在本设备解锁，感谢支持！')
          : context.tr('A one-time purchase that unlocks every feature.', '一次性购买，解锁全部功能。'),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(pro.unlocked ? Icons.verified : Icons.workspace_premium_outlined, color: scheme.primary),
          title: Text(
            pro.unlocked
                ? context.tr('Cirrus Pro (lifetime)', 'Cirrus Pro（终身）')
                : pro.product?.price ?? context.tr('Price unavailable', '价格暂不可用'),
          ),
          trailing: pro.unlocked
              ? null
              : Wrap(
                  spacing: 8,
                  children: [
                    TextButton(onPressed: pro.busy ? null : ctl.restore, child: Text(context.tr('Restore', '恢复购买'))),
                    FilledButton(
                      onPressed: pro.busy
                          ? null
                          : () => showAppDialog<void>(
                              context: context,
                              builder: (ctx) => const Dialog(child: ProPaywall()),
                            ),
                      child: Text(context.tr('Unlock', '解锁')),
                    ),
                  ],
                ),
        ),
        if (pro.error != null) Text(pro.error!, style: TextStyle(color: scheme.error)),
      ],
    );
  }
}

/// Licence status and deactivation (licence builds).
class _LicenseSection extends ConsumerWidget {
  const _LicenseSection();

  Future<void> _deactivate(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: context.tr('Deactivate on this device?', '在此设备上停用？'),
      message: context.tr(
        'Cirrus Pro will be locked on this device, and the activation freed so the key can be used on another device.',
        '本设备上的 Cirrus Pro 将被锁定，并释放该激活名额，之后可以在其他设备上使用此密钥。',
      ),
      confirmLabel: context.tr('Deactivate', '停用'),
      destructive: true,
    );
    if (!ok) return;
    final done = await ref.read(licenseProvider.notifier).deactivate();
    if (done && context.mounted) showToast(context, context.tr('Deactivated on this device', '已在此设备上停用'));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final license = ref.watch(licenseProvider);
    final active = license.active;
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Cirrus Pro',
      subtitle: active != null
          ? context.tr('Activated on this device. Thank you!', '已在本设备激活，感谢支持！')
          : context.tr('Activate a licence key bought on the Cirrus website.', '使用在 Cirrus 网站购买的许可证密钥激活。'),
      children: [
        if (active != null) ...[
          InfoRow(context.tr('Status', '状态'), context.tr('Activated', '已激活')),
          InfoRow(context.tr('Licence key', '许可证密钥'), active.maskedKey, mono: true),
          if (active.payload.owner.isNotEmpty) InfoRow(context.tr('Owner', '所有者'), active.payload.owner),
          InfoRow(context.tr('Platform', '平台'), licensePlatformLabel(active.payload.platform)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: license.busy ? null : () => _deactivate(context, ref),
              icon: license.busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link_off),
              label: Text(context.tr('Deactivate on this device', '在此设备上停用')),
            ),
          ),
        ] else
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.workspace_premium_outlined, color: scheme.primary),
            title: Text(context.tr('Not activated', '未激活')),
            trailing: FilledButton(
              onPressed: license.busy
                  ? null
                  : () => showAppDialog<void>(
                      context: context,
                      builder: (ctx) => const Dialog(child: ProPaywall()),
                    ),
              child: Text(context.tr('Activate', '激活')),
            ),
          ),
        if (license.error != null) ...[const SizedBox(height: 8), LicenseErrorView(error: license.error!)],
      ],
    );
  }
}
