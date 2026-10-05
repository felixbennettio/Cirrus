import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart' as bu;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/files.dart';
import '../../ui/widgets/json_view.dart';
import '../generic/resource_page.dart';
import '../generic/resource_specs.dart';
import '../zone_settings/zone_settings.dart';

const _customCertsSpec = ResourceSpec(
  id: 'custom_certificates',
  title: L10nText('Custom certificates', '自定义证书'),
  group: gZone,
  icon: Icons.upload_file,
  scope: SpecScope.zone,
  listPath: '/zones/{zone_id}/custom_certificates',
  titleFields: ['hosts', 'id'],
  subtitleFields: ['issuer', 'expires_on', 'bundle_method'],
  statusField: 'status',
  updateMethod: 'PATCH',
);

const _clientCertsSpec = ResourceSpec(
  id: 'client_certificates',
  title: L10nText('Client certificates', '客户端证书'),
  group: gZone,
  icon: Icons.badge_outlined,
  scope: SpecScope.zone,
  listPath: '/zones/{zone_id}/client_certificates',
  titleFields: ['common_name', 'id'],
  subtitleFields: ['expires_on', 'serial_number'],
  statusField: 'status',
  updateMethod: 'PATCH',
);

class SslPage extends StatelessWidget {
  const SslPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: PageScaffold(
        title: 'SSL/TLS',
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: context.tr('Overview', '概览')),
            Tab(text: context.tr('Edge certificates', '边缘证书')),
            Tab(text: context.tr('Origin server', '源服务器')),
            Tab(text: context.tr('Custom certificates', '自定义证书')),
            Tab(text: context.tr('Client certificates', '客户端证书')),
          ],
        ),
        body: const TabBarView(
          children: [
            _Overview(),
            _EdgeCertificates(),
            _OriginCertificates(),
            ResourceListView(spec: _customCertsSpec),
            ResourceListView(spec: _clientCertsSpec),
          ],
        ),
      ),
    );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZoneRequired(
      builder: (context, zoneId, _) => ApiQuery<Map<String, Map<String, dynamic>>>(
        cacheKey: 'zone-settings:$zoneId',
        load: (c) => loadZoneSettings(c, zoneId),
        builder: (context, settings, h) {
          final mode = settings['ssl']?['value'] as String?;
          void update(Map<String, dynamic> s) => h.setData({...settings, s['id'] as String: s});
          final client = ref.read(clientProvider)!;
          Widget modeCard(String value, IconData icon, L10nText title, L10nText desc) {
            final selected = mode == value;
            final scheme = Theme.of(context).colorScheme;
            return Card(
              margin: EdgeInsets.zero,
              color: selected ? scheme.primaryContainer : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () async {
                  final r = await runAction(
                    context,
                    () => client.send('PATCH', '/zones/$zoneId/settings/ssl', data: {'value': value}),
                    success: context.tr('Encryption mode updated', '加密模式已更新'),
                  );
                  if (r?.result is Map) update(Map<String, dynamic>.from(r!.result as Map));
                },
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(icon, color: selected ? scheme.onPrimaryContainer : scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(title.of(context), style: const TextStyle(fontWeight: FontWeight.w600))),
                          if (selected) const Icon(Icons.check_circle, size: 18),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(desc.of(context), style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            );
          }

          return ContentList(
            maxWidth: 900,
            onRefresh: h.reload,
            children: [
              SectionCard(
                title: context.tr('Encryption mode', '加密模式'),
                children: [
                  const SizedBox(height: 4),
                  ResponsiveGrid(
                    minItemWidth: 190,
                    children: [
                      modeCard('off', Icons.lock_open, const L10nText('Off', '关闭'), const L10nText('No encryption. Not recommended.', '不加密，不推荐。')),
                      modeCard('flexible', Icons.lock_outline, const L10nText('Flexible', '灵活'), const L10nText('HTTPS to visitors, HTTP to origin.', '访客到 Cloudflare 加密，回源 HTTP。')),
                      modeCard('full', Icons.lock, const L10nText('Full', '完全'), const L10nText('HTTPS to origin, any certificate.', '回源 HTTPS，接受任意证书。')),
                      modeCard('strict', Icons.verified_user, const L10nText('Full (strict)', '完全（严格）'), const L10nText('HTTPS to origin with a valid certificate.', '回源 HTTPS，要求有效证书。')),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
              SectionCard(
                title: context.tr('Edge settings', '边缘设置'),
                children: [
                  for (final id in const [
                    'always_use_https',
                    'min_tls_version',
                    'tls_1_3',
                    'automatic_https_rewrites',
                    'opportunistic_encryption',
                    'tls_client_auth',
                    'ssl_automatic_mode',
                    'ciphers',
                  ])
                    if (settings[id] != null) ZoneSettingTile(zoneId: zoneId, setting: settings[id]!, onChanged: update),
                ],
              ),
              if (settings['security_header'] != null)
                _HstsCard(zoneId: zoneId, setting: settings['security_header']!, onChanged: update),
            ],
          );
        },
      ),
    );
  }
}

class _HstsCard extends ConsumerStatefulWidget {
  const _HstsCard({required this.zoneId, required this.setting, required this.onChanged});

  final String zoneId;
  final Map<String, dynamic> setting;
  final ValueChanged<Map<String, dynamic>> onChanged;

  @override
  ConsumerState<_HstsCard> createState() => _HstsCardState();
}

class _HstsCardState extends ConsumerState<_HstsCard> {
  late Map<String, dynamic> _hsts = Map<String, dynamic>.from(
    ((widget.setting['value'] as Map?)?['strict_transport_security'] as Map?) ?? const {},
  );

  Future<void> _save() async {
    final client = ref.read(clientProvider)!;
    final r = await runAction(
      context,
      () => client.send('PATCH', '/zones/${widget.zoneId}/settings/security_header', data: {
        'value': {'strict_transport_security': _hsts},
      }),
      success: context.tr('HSTS saved', 'HSTS 已保存'),
    );
    if (r?.result is Map) widget.onChanged(Map<String, dynamic>.from(r!.result as Map));
  }

  @override
  Widget build(BuildContext context) {
    const ages = [0, 2592000, 5184000, 7776000, 10368000, 12960000, 15552000, 31536000, 63072000];
    final maxAge = (_hsts['max_age'] as num?)?.toInt() ?? 0;
    return SectionCard(
      title: context.tr('HTTP Strict Transport Security (HSTS)', 'HTTP 严格传输安全 (HSTS)'),
      subtitle: context.tr(
        'Browsers will refuse plain HTTP for your domain. Disabling later only takes effect after max-age expires.',
        '浏览器将拒绝以 HTTP 访问该域名。关闭后需等 max-age 过期才生效。',
      ),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.tr('Enable HSTS', '启用 HSTS')),
          value: _hsts['enabled'] == true,
          onChanged: (v) => setState(() => _hsts = {..._hsts, 'enabled': v}),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Max-Age'),
          trailing: DropdownButton<int>(
            value: ages.contains(maxAge) ? maxAge : null,
            hint: Text('$maxAge'),
            underline: const SizedBox(),
            items: [for (final a in ages) DropdownMenuItem(value: a, child: Text(a == 0 ? '0 (disable)' : '${a ~/ 2592000} ${context.tr('months', '个月')}'))],
            onChanged: (v) => setState(() => _hsts = {..._hsts, 'max_age': v}),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.tr('Include subdomains', '包含子域名')),
          value: _hsts['include_subdomains'] == true,
          onChanged: (v) => setState(() => _hsts = {..._hsts, 'include_subdomains': v}),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Preload'),
          value: _hsts['preload'] == true,
          onChanged: (v) => setState(() => _hsts = {..._hsts, 'preload': v}),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.tr('No-Sniff header', 'No-Sniff 头')),
          value: _hsts['nosniff'] == true,
          onChanged: (v) => setState(() => _hsts = {..._hsts, 'nosniff': v}),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: _save, child: Text(context.tr('Save HSTS', '保存 HSTS'))),
        ),
      ],
    );
  }
}

class _EdgeCertificates extends ConsumerWidget {
  const _EdgeCertificates();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZoneRequired(
      builder: (context, zoneId, zone) => ApiQuery<(List<Map<String, dynamic>>, Map<String, dynamic>?)>(
        cacheKey: 'edge-certs:$zoneId',
        load: (c) async {
          final packs = await c.list('/zones/$zoneId/ssl/certificate_packs', query: {'status': 'all'}, perPage: 50);
          Map<String, dynamic>? universal;
          try {
            universal = Map<String, dynamic>.from(await c.get('/zones/$zoneId/ssl/universal/settings') as Map);
          } catch (_) {}
          return (packs, universal);
        },
        builder: (context, data, h) {
          final (packs, universal) = data;
          final client = ref.read(clientProvider)!;
          return ContentList(
            onRefresh: h.reload,
            children: [
              if (universal != null)
                SectionCard(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.tr('Universal SSL', '通用 SSL')),
                      subtitle: Text(context.tr('Free certificate covering the apex and first-level subdomains.', '覆盖根域名和一级子域名的免费证书。')),
                      value: universal['enabled'] == true,
                      onChanged: (v) async {
                        if (!v &&
                            !await confirm(
                              context,
                              title: context.tr('Disable Universal SSL?', '关闭通用 SSL？'),
                              message: context.tr('Visitors may see certificate errors.', '访客可能会看到证书错误。'),
                              destructive: true,
                            )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await runAction(context, () => client.patch('/zones/$zoneId/ssl/universal/settings', data: {'enabled': v}));
                        await h.reload();
                      },
                    ),
                  ],
                ),
              SectionCard(
                title: context.tr('Certificate packs', '证书包'),
                trailing: FilledButton.tonalIcon(
                  icon: const Icon(Icons.add),
                  label: Text(context.tr('Order advanced certificate', '订购高级证书')),
                  onPressed: () async {
                    final ok = await _orderAdvanced(context, ref, zoneId, zone['name'] as String);
                    if (ok) await h.reload();
                  },
                ),
                children: [
                  if (packs.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(context.tr('No certificates', '没有证书'))),
                  for (final p in packs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.workspace_premium_outlined),
                      title: Text(((p['hosts'] as List?) ?? const []).join(', ')),
                      subtitle: Text([
                        p['type'],
                        p['certificate_authority'],
                        if (p['validity_days'] != null) '${p['validity_days']}d',
                        if ((p['certificates'] as List?)?.isNotEmpty ?? false)
                          '${context.tr('expires', '到期')} ${formatDate(((p['certificates'] as List).first as Map)['expires_on'], withTime: false)}',
                      ].whereType<Object>().join(' · ')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StatusChip('${p['status']}', tone: StatusChip.toneFor(p['status'] as String?)),
                          PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'json') {
                                await showJsonDialog(context, p);
                              } else if (v == 'delete') {
                                final ok = await confirmDanger(
                                  context,
                                  title: context.tr('Delete certificate pack?', '删除证书包？'),
                                  message: ((p['hosts'] as List?) ?? const []).join(', '),
                                );
                                if (!ok || !context.mounted) return;
                                await runAction(context, () => client.delete('/zones/$zoneId/ssl/certificate_packs/${p['id']}'));
                                await h.reload();
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(value: 'json', child: Text(context.tr('Details', '详情'))),
                              if (p['type'] != 'universal') PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'))),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> _orderAdvanced(BuildContext context, WidgetRef ref, String zoneId, String zoneName) async {
    final hosts = TextEditingController(text: '$zoneName\n*.$zoneName');
    var ca = 'lets_encrypt';
    var validation = 'txt';
    var days = 90;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(ctx.tr('Order advanced certificate', '订购高级证书')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: hosts,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(labelText: ctx.tr('Hostnames (one per line)', '主机名（每行一个）'), border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: ca,
                  decoration: InputDecoration(labelText: ctx.tr('Certificate authority', '证书颁发机构'), border: const OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'lets_encrypt', child: Text("Let's Encrypt")),
                    DropdownMenuItem(value: 'google', child: Text('Google Trust Services')),
                    DropdownMenuItem(value: 'ssl_com', child: Text('SSL.com')),
                  ],
                  onChanged: (v) => setState(() => ca = v ?? ca),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: validation,
                  decoration: InputDecoration(labelText: ctx.tr('Validation method', '验证方式'), border: const OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'txt', child: Text('TXT')),
                    DropdownMenuItem(value: 'http', child: Text('HTTP')),
                    DropdownMenuItem(value: 'email', child: Text('Email')),
                  ],
                  onChanged: (v) => setState(() => validation = v ?? validation),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: days,
                  decoration: InputDecoration(labelText: ctx.tr('Validity', '有效期'), border: const OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 14, child: Text('14 days')),
                    DropdownMenuItem(value: 30, child: Text('30 days')),
                    DropdownMenuItem(value: 90, child: Text('90 days')),
                    DropdownMenuItem(value: 365, child: Text('365 days')),
                  ],
                  onChanged: (v) => setState(() => days = v ?? days),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('Order', '订购'))),
          ],
        ),
      ),
    );
    final list = hosts.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    hosts.dispose();
    if (ok != true || !context.mounted) return false;
    final client = ref.read(clientProvider)!;
    final r = await runAction(
      context,
      () => client.send('POST', '/zones/$zoneId/ssl/certificate_packs/order', data: {
        'type': 'advanced',
        'hosts': list,
        'certificate_authority': ca,
        'validation_method': validation,
        'validity_days': days,
      }),
      success: context.tr('Certificate ordered', '证书已订购'),
    );
    return r != null;
  }
}

class _OriginCertificates extends ConsumerWidget {
  const _OriginCertificates();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZoneRequired(
      builder: (context, zoneId, zone) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'origin-certs:$zoneId',
        load: (c) => c.list('/certificates', query: {'zone_id': zoneId}, perPage: 50),
        builder: (context, certs, h) {
          final client = ref.read(clientProvider)!;
          return ContentList(
            onRefresh: h.reload,
            children: [
              SectionCard(
                title: context.tr('Origin CA certificates', 'Origin CA 证书'),
                subtitle: context.tr(
                  'Free certificates trusted by Cloudflare for encrypting traffic to your origin (Full strict).',
                  '受 Cloudflare 信任的免费证书，用于加密回源流量（完全严格模式）。',
                ),
                trailing: FilledButton.tonalIcon(
                  icon: const Icon(Icons.add),
                  label: Text(context.tr('Create', '创建')),
                  onPressed: () async {
                    if (await _createOriginCert(context, ref, zone['name'] as String)) await h.reload();
                  },
                ),
                children: [
                  if (certs.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(context.tr('No origin certificates', '没有源站证书'))),
                  for (final cert in certs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.verified_outlined),
                      title: Text(((cert['hostnames'] as List?) ?? const []).join(', ')),
                      subtitle: Text('${cert['request_type'] ?? ''} · ${context.tr('expires', '到期')} ${formatDate(cert['expires_on'], withTime: false)}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'download') {
                            await saveText(context, fileName: 'origin-${cert['id']}.pem', text: '${cert['certificate'] ?? ''}');
                          } else if (v == 'revoke') {
                            final ok = await confirmDanger(
                              context,
                              title: context.tr('Revoke certificate?', '吊销证书？'),
                              message: context.tr('Origins using it will stop working with Full (strict).', '使用该证书的源站在完全（严格）模式下将无法工作。'),
                              confirmLabel: context.tr('Revoke', '吊销'),
                            );
                            if (!ok || !context.mounted) return;
                            await runAction(context, () => client.delete('/certificates/${cert['id']}'), success: context.tr('Revoked', '已吊销'));
                            await h.reload();
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(value: 'download', child: Text(context.tr('Download certificate', '下载证书'))),
                          PopupMenuItem(value: 'revoke', child: Text(context.tr('Revoke', '吊销'))),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Generates an ECDSA P-256 key and CSR locally (the private key never
/// leaves the device), then requests an Origin CA certificate.
Future<bool> _createOriginCert(BuildContext context, WidgetRef ref, String zoneName) async {
  final hosts = TextEditingController(text: '$zoneName\n*.$zoneName');
  final csrController = TextEditingController();
  var validity = 5475;
  var ownCsr = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(ctx.tr('Create Origin CA certificate', '创建 Origin CA 证书')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: hosts,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(labelText: ctx.tr('Hostnames (one per line)', '主机名（每行一个）'), border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: validity,
                  decoration: InputDecoration(labelText: ctx.tr('Validity', '有效期'), border: const OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 7, child: Text('7 days')),
                    DropdownMenuItem(value: 30, child: Text('30 days')),
                    DropdownMenuItem(value: 90, child: Text('90 days')),
                    DropdownMenuItem(value: 365, child: Text('1 year')),
                    DropdownMenuItem(value: 730, child: Text('2 years')),
                    DropdownMenuItem(value: 1095, child: Text('3 years')),
                    DropdownMenuItem(value: 5475, child: Text('15 years')),
                  ],
                  onChanged: (v) => setState(() => validity = v ?? validity),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(ctx.tr('Use my own CSR', '使用我自己的 CSR')),
                  subtitle: Text(ctx.tr('Otherwise an ECDSA key is generated on this device.', '否则将在本设备上生成 ECDSA 私钥。')),
                  value: ownCsr,
                  onChanged: (v) => setState(() => ownCsr = v),
                ),
                if (ownCsr)
                  TextField(
                    controller: csrController,
                    minLines: 4,
                    maxLines: 10,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    decoration: const InputDecoration(labelText: 'CSR (PEM)', border: OutlineInputBorder()),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('Create', '创建'))),
        ],
      ),
    ),
  );
  final hostnames = hosts.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final ownCsrText = csrController.text.trim();
  hosts.dispose();
  csrController.dispose();
  if (ok != true || !context.mounted) return false;
  final client = ref.read(clientProvider)!;
  String? privateKeyPem;
  final res = await runAction(context, () async {
    var csr = ownCsrText;
    if (!ownCsr) {
      final first = hostnames.first;
      final generated = await Isolate.run(() {
        final pair = bu.CryptoUtils.generateEcKeyPair();
        final priv = pair.privateKey as bu.ECPrivateKey;
        final pub = pair.publicKey as bu.ECPublicKey;
        final csrPem = bu.X509Utils.generateEccCsrPem({'CN': first}, priv, pub, san: hostnames);
        return (csrPem, bu.CryptoUtils.encodeEcPrivateKeyToPem(priv));
      });
      csr = generated.$1;
      privateKeyPem = generated.$2;
    }
    return client.send('POST', '/certificates', data: {
      'hostnames': hostnames,
      'requested_validity': validity,
      'request_type': 'origin-ecc',
      'csr': csr,
    });
  });
  if (res == null || !context.mounted) return false;
  final cert = (res.result as Map?)?['certificate'] as String? ?? '';
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.tr('Origin certificate created', '源站证书已创建')),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (privateKeyPem != null)
              Text(
                ctx.tr(
                  'Save the private key now — it was generated on this device and is not stored anywhere else.',
                  '请立即保存私钥——它是在本设备上生成的，不会保存在其他任何地方。',
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.save_alt),
                  label: Text(ctx.tr('Save certificate', '保存证书')),
                  onPressed: () => saveText(ctx, fileName: '$zoneName.origin.pem', text: cert),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: Text(ctx.tr('Copy certificate', '复制证书')),
                  onPressed: () => copyText(ctx, cert),
                ),
                if (privateKeyPem != null) ...[
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.key),
                    label: Text(ctx.tr('Save private key', '保存私钥')),
                    onPressed: () => saveText(ctx, fileName: '$zoneName.origin.key', text: privateKeyPem!),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy),
                    label: Text(ctx.tr('Copy private key', '复制私钥')),
                    onPressed: () => copyText(ctx, privateKeyPem!),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('Done', '完成')))],
    ),
  );
  return true;
}
