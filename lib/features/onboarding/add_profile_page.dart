import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/credential.dart';
import '../../core/auth/verify.dart';
import '../../core/cache/query_cache.dart';
import '../../core/session/session.dart';
import '../../core/util/tr.dart';

/// Add (or edit) a credential profile. Used for first run and from
/// settings. The credential is verified before it is saved.
class AddProfilePage extends ConsumerStatefulWidget {
  const AddProfilePage({super.key, this.firstRun = false, this.editing});

  final bool firstRun;
  final Profile? editing;

  @override
  ConsumerState<AddProfilePage> createState() => _AddProfilePageState();
}

class _AddProfilePageState extends ConsumerState<AddProfilePage> {
  late AuthKind _kind = widget.editing?.kind ?? AuthKind.apiToken;
  late final _name = TextEditingController(text: widget.editing?.name);
  late final _token = TextEditingController(text: widget.editing?.token);
  late final _email = TextEditingController(text: widget.editing?.email);
  late final _key = TextEditingController(text: widget.editing?.apiKey);
  late final _accountId = TextEditingController(text: widget.editing?.accountId);
  late final _originCa = TextEditingController(text: widget.editing?.originCaKey);
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _token, _email, _key, _accountId, _originCa]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _clean(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final base = widget.editing;
    final profile = Profile(
      id: base?.id ?? Profile.newId(),
      name: _clean(_name) ?? (_kind == AuthKind.globalKey ? (_clean(_email) ?? 'Cloudflare') : 'Cloudflare'),
      kind: _kind,
      token: _kind == AuthKind.apiToken ? _clean(_token) : null,
      email: _kind == AuthKind.globalKey ? _clean(_email) : null,
      apiKey: _kind == AuthKind.globalKey ? _clean(_key) : null,
      accountId: _kind == AuthKind.apiToken ? _clean(_accountId) : null,
      originCaKey: _clean(_originCa),
      createdAt: base?.createdAt ?? DateTime.now(),
    );
    if (_kind == AuthKind.apiToken && profile.token == null) {
      setState(() {
        _busy = false;
        _error = context.tr('Enter an API token.', '请输入 API Token。');
      });
      return;
    }
    if (_kind == AuthKind.globalKey && (profile.email == null || profile.apiKey == null)) {
      setState(() {
        _busy = false;
        _error = context.tr('Enter your e-mail and Global API Key.', '请输入邮箱和 Global API Key。');
      });
      return;
    }
    final result = await verifyProfile(profile);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = result.error ?? context.tr('Verification failed', '验证失败');
      });
      return;
    }
    var named = profile;
    if (_clean(_name) == null && result.accounts.isNotEmpty) {
      named = profile.copyWith(name: result.accounts.first['name'] as String? ?? profile.name);
    }
    await ref.read(profilesProvider.notifier).upsert(named);
    QueryCache.instance.clear();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr(
            'Verified. ${result.accounts.length} account(s) available.',
            '验证成功，可访问 ${result.accounts.length} 个账户。',
          ),
        ),
      ),
    );
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.firstRun) ...[
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset('assets/branding/cirrus_256.png', width: 96, height: 96),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Cirrus',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('A fast, native client for the Cloudflare API.', '快速、原生的 Cloudflare API 客户端。'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
        ],
        SegmentedButton<AuthKind>(
          segments: [
            ButtonSegment(
              value: AuthKind.apiToken,
              label: const Text('API Token'),
              icon: const Icon(Icons.vpn_key_outlined),
            ),
            ButtonSegment(value: AuthKind.globalKey, label: const Text('Global API Key'), icon: const Icon(Icons.key)),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _kind == AuthKind.apiToken
              ? context.tr(
                  'Recommended. Create a token with the permissions you need under My Profile → API Tokens (or an account-owned token under Manage Account → API Tokens).',
                  '推荐方式。在「我的个人资料 → API 令牌」中创建带所需权限的 Token（也可以在「管理账户 → API 令牌」中创建账户 Token）。',
                )
              : context.tr(
                  'The legacy Global API Key has full access to everything your user can do. Prefer scoped API tokens when possible.',
                  'Global API Key 拥有该用户的全部权限，请尽量使用有范围限制的 API Token。',
                ),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          decoration: InputDecoration(
            labelText: context.tr('Name (optional)', '名称（可选）'),
            hintText: context.tr('e.g. Personal, Company', '例如：个人、公司'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (_kind == AuthKind.apiToken)
          TextField(
            controller: _token,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'API Token',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _submit(),
          )
        else ...[
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.tr('Account e-mail', '账户邮箱'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Global API Key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
        const SizedBox(height: 8),
        Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(context.tr('Advanced', '高级选项')),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              if (_kind == AuthKind.apiToken) ...[
                TextField(
                  controller: _accountId,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: context.tr('Account ID (account-owned tokens)', '账户 ID（账户 Token 需要）'),
                    helperText: context.tr(
                      'Only needed if verification fails for an account-owned token.',
                      '仅当账户 Token 验证失败时需要填写。',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _originCa,
                obscureText: true,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: context.tr('Origin CA Key (optional)', 'Origin CA Key（可选）'),
                  helperText: context.tr('Used only for Origin CA certificate endpoints.', '仅用于 Origin CA 证书相关接口。'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: theme.colorScheme.errorContainer, borderRadius: BorderRadius.circular(8)),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.verified_outlined),
          label: Text(context.tr('Verify & save', '验证并保存')),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => launchUrl(
            Uri.parse('https://dash.cloudflare.com/profile/api-tokens'),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(context.tr('Create a token in the Cloudflare dashboard', '在 Cloudflare 面板中创建 Token')),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.tr(
                  'Credentials are stored only on this device, in the system keychain. Cirrus talks directly to api.cloudflare.com — there is no intermediate server.',
                  '凭据只保存在本设备的系统钥匙串中。Cirrus 直接连接 api.cloudflare.com，没有任何中间服务器。',
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
    return Scaffold(
      appBar: widget.firstRun
          ? null
          : AppBar(
              title: Text(
                widget.editing == null ? context.tr('Add credential', '添加凭据') : context.tr('Edit credential', '编辑凭据'),
              ),
            ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: form),
          ),
        ),
      ),
    );
  }
}
