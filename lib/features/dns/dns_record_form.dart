import 'package:flutter/material.dart';

import '../../core/util/tr.dart';
import '../../ui/widgets/glass.dart';

/// Every DNS record type the API supports.
const dnsTypes = [
  'A',
  'AAAA',
  'CNAME',
  'MX',
  'TXT',
  'NS',
  'SRV',
  'CAA',
  'HTTPS',
  'SVCB',
  'PTR',
  'TLSA',
  'SSHFP',
  'URI',
  'LOC',
  'CERT',
  'DS',
  'DNSKEY',
  'NAPTR',
  'SMIMEA',
  'OPENPGPKEY',
];

const proxiableTypes = {'A', 'AAAA', 'CNAME'};

class _F {
  const _F(this.key, this.label, {this.numeric = false, this.options, this.hint});

  final String key;
  final L10nText label;
  final bool numeric;
  final List<String>? options;
  final String? hint;
}

const _dataFields = <String, List<_F>>{
  'CAA': [
    _F('flags', L10nText('Flags', '标志'), numeric: true, hint: '0'),
    _F('tag', L10nText('Tag', '标签'), options: ['issue', 'issuewild', 'iodef']),
    _F('value', L10nText('CA domain / URL', 'CA 域名 / URL'), hint: 'letsencrypt.org'),
  ],
  'SRV': [
    _F('priority', L10nText('Priority', '优先级'), numeric: true, hint: '10'),
    _F('weight', L10nText('Weight', '权重'), numeric: true, hint: '5'),
    _F('port', L10nText('Port', '端口'), numeric: true, hint: '443'),
    _F('target', L10nText('Target', '目标'), hint: 'service.example.com'),
  ],
  'HTTPS': [
    _F('priority', L10nText('Priority', '优先级'), numeric: true, hint: '1'),
    _F('target', L10nText('Target', '目标'), hint: '.'),
    _F('value', L10nText('Value', '值'), hint: 'alpn="h3,h2" ipv4hint="203.0.113.1"'),
  ],
  'SVCB': [
    _F('priority', L10nText('Priority', '优先级'), numeric: true, hint: '1'),
    _F('target', L10nText('Target', '目标'), hint: '.'),
    _F('value', L10nText('Value', '值'), hint: 'alpn="h2"'),
  ],
  'TLSA': [
    _F('usage', L10nText('Usage', '用途'), numeric: true, hint: '3'),
    _F('selector', L10nText('Selector', '选择器'), numeric: true, hint: '1'),
    _F('matching_type', L10nText('Matching type', '匹配类型'), numeric: true, hint: '1'),
    _F('certificate', L10nText('Certificate', '证书'), hint: 'hex digest'),
  ],
  'SMIMEA': [
    _F('usage', L10nText('Usage', '用途'), numeric: true),
    _F('selector', L10nText('Selector', '选择器'), numeric: true),
    _F('matching_type', L10nText('Matching type', '匹配类型'), numeric: true),
    _F('certificate', L10nText('Certificate', '证书')),
  ],
  'SSHFP': [
    _F('algorithm', L10nText('Algorithm', '算法'), numeric: true, hint: '4'),
    _F('type', L10nText('Fingerprint type', '指纹类型'), numeric: true, hint: '2'),
    _F('fingerprint', L10nText('Fingerprint', '指纹')),
  ],
  'DS': [
    _F('key_tag', L10nText('Key tag', '密钥标签'), numeric: true),
    _F('algorithm', L10nText('Algorithm', '算法'), numeric: true),
    _F('digest_type', L10nText('Digest type', '摘要类型'), numeric: true),
    _F('digest', L10nText('Digest', '摘要')),
  ],
  'DNSKEY': [
    _F('flags', L10nText('Flags', '标志'), numeric: true, hint: '257'),
    _F('protocol', L10nText('Protocol', '协议'), numeric: true, hint: '3'),
    _F('algorithm', L10nText('Algorithm', '算法'), numeric: true, hint: '13'),
    _F('public_key', L10nText('Public key', '公钥')),
  ],
  'CERT': [
    _F('type', L10nText('Cert type', '证书类型'), numeric: true),
    _F('key_tag', L10nText('Key tag', '密钥标签'), numeric: true),
    _F('algorithm', L10nText('Algorithm', '算法'), numeric: true),
    _F('certificate', L10nText('Certificate', '证书')),
  ],
  'NAPTR': [
    _F('order', L10nText('Order', '顺序'), numeric: true),
    _F('preference', L10nText('Preference', '偏好'), numeric: true),
    _F('flags', L10nText('Flags', '标志'), hint: 'U'),
    _F('service', L10nText('Service', '服务'), hint: 'E2U+sip'),
    _F('regex', L10nText('Regex', '正则')),
    _F('replacement', L10nText('Replacement', '替换'), hint: '.'),
  ],
  'URI': [
    _F('weight', L10nText('Weight', '权重'), numeric: true, hint: '1'),
    _F('target', L10nText('Target URI', '目标 URI'), hint: 'https://example.com'),
  ],
  'LOC': [
    _F('lat_degrees', L10nText('Latitude °', '纬度 °'), numeric: true),
    _F('lat_minutes', L10nText('Latitude ′', '纬度 ′'), numeric: true),
    _F('lat_seconds', L10nText('Latitude ″', '纬度 ″'), numeric: true),
    _F('lat_direction', L10nText('N/S', '南/北'), options: ['N', 'S']),
    _F('long_degrees', L10nText('Longitude °', '经度 °'), numeric: true),
    _F('long_minutes', L10nText('Longitude ′', '经度 ′'), numeric: true),
    _F('long_seconds', L10nText('Longitude ″', '经度 ″'), numeric: true),
    _F('long_direction', L10nText('E/W', '东/西'), options: ['E', 'W']),
    _F('altitude', L10nText('Altitude (m)', '海拔（米）'), numeric: true),
    _F('size', L10nText('Size (m)', '大小（米）'), numeric: true),
    _F('precision_horz', L10nText('Horizontal precision', '水平精度'), numeric: true),
    _F('precision_vert', L10nText('Vertical precision', '垂直精度'), numeric: true),
  ],
};

const _ttls = [1, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18000, 43200, 86400];

String ttlLabel(BuildContext context, Object? ttl) {
  if (ttl == 1 || ttl == null) return context.tr('Auto', '自动');
  final t = ttl is num ? ttl.toInt() : int.tryParse(ttl.toString()) ?? 0;
  if (t % 86400 == 0) return '${t ~/ 86400}d';
  if (t % 3600 == 0) return '${t ~/ 3600}h';
  if (t % 60 == 0) return '${t ~/ 60}m';
  return '${t}s';
}

/// Dialog to create or edit a DNS record. Returns the request body.
Future<Map<String, dynamic>?> showDnsRecordDialog(
  BuildContext context, {
  required String zoneName,
  Map<String, dynamic>? record,
}) {
  return showAppDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => _DnsRecordDialog(zoneName: zoneName, record: record),
  );
}

class _DnsRecordDialog extends StatefulWidget {
  const _DnsRecordDialog({required this.zoneName, this.record});

  final String zoneName;
  final Map<String, dynamic>? record;

  @override
  State<_DnsRecordDialog> createState() => _DnsRecordDialogState();
}

class _DnsRecordDialogState extends State<_DnsRecordDialog> {
  final _form = GlobalKey<FormState>();
  late String _type = widget.record?['type'] as String? ?? 'A';
  late final _name = TextEditingController(text: _relativeName(widget.record?['name'] as String?));
  late final _content = TextEditingController(text: widget.record?['content']?.toString());
  late final _priority = TextEditingController(text: widget.record?['priority']?.toString());
  late final _comment = TextEditingController(text: widget.record?['comment'] as String?);
  late final _tags = TextEditingController(text: ((widget.record?['tags'] as List?) ?? const []).join(', '));
  late bool _proxied = widget.record?['proxied'] as bool? ?? true;
  late int _ttl = (widget.record?['ttl'] as num?)?.toInt() ?? 1;
  late final _customTtl = TextEditingController(text: _ttls.contains(_ttl) ? '' : '$_ttl');
  late final Map<String, TextEditingController> _data = {};
  late final Map<String, String?> _dataOptions = {};
  late bool _flatten = (widget.record?['settings'] as Map?)?['flatten_cname'] == true;

  bool get _isEdit => widget.record != null;

  String _relativeName(String? name) {
    if (name == null) return '';
    if (name == widget.zoneName) return '@';
    final suffix = '.${widget.zoneName}';
    return name.endsWith(suffix) ? name.substring(0, name.length - suffix.length) : name;
  }

  TextEditingController _dataController(String key) {
    return _data.putIfAbsent(key, () {
      final v = (widget.record?['data'] as Map?)?[key];
      return TextEditingController(text: v?.toString());
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _content, _priority, _comment, _tags, _customTtl, ..._data.values]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _usesData => _dataFields.containsKey(_type);
  bool get _hasPriority => _type == 'MX' || _type == 'URI';

  Map<String, dynamic> _build() {
    final name = _name.text.trim();
    final body = <String, dynamic>{
      'type': _type,
      'name': name.isEmpty || name == '@' ? widget.zoneName : name,
      'ttl': _ttl == -1 ? (int.tryParse(_customTtl.text.trim()) ?? 1) : _ttl,
      'comment': _comment.text.trim(),
      'tags': _tags.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
    };
    if (proxiableTypes.contains(_type)) body['proxied'] = _proxied;
    if (_hasPriority) body['priority'] = int.tryParse(_priority.text.trim()) ?? 10;
    if (_usesData) {
      final data = <String, dynamic>{};
      for (final f in _dataFields[_type]!) {
        if (f.options != null) {
          final v = _dataOptions[f.key] ?? (widget.record?['data'] as Map?)?[f.key]?.toString() ?? f.options!.first;
          data[f.key] = v;
        } else {
          final t = _dataController(f.key).text.trim();
          if (t.isEmpty) continue;
          data[f.key] = f.numeric ? (num.tryParse(t) ?? t) : t;
        }
      }
      body['data'] = data;
    } else {
      body['content'] = _content.text.trim();
    }
    if (_type == 'CNAME') body['settings'] = {'flatten_cname': _flatten};
    return body;
  }

  String? _contentHint() => switch (_type) {
    'A' => '203.0.113.10',
    'AAAA' => '2001:db8::1',
    'CNAME' => 'target.example.net',
    'MX' => 'mail.example.com',
    'TXT' => 'v=spf1 include:_spf.example.com ~all',
    'NS' => 'ns1.example.net',
    'PTR' => 'host.example.com',
    'OPENPGPKEY' => 'base64 key',
    _ => null,
  };

  String? _validateContent(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return context.tr('Required', '必填');
    if (_type == 'A' && !RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(t)) {
      return context.tr('Must be an IPv4 address', '必须是 IPv4 地址');
    }
    if (_type == 'AAAA' && !t.contains(':')) return context.tr('Must be an IPv6 address', '必须是 IPv6 地址');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      Row(
        children: [
          SizedBox(
            width: 140,
            child: DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: InputDecoration(labelText: context.tr('Type', '类型'), border: const OutlineInputBorder()),
              items: [for (final t in dnsTypes) DropdownMenuItem(value: t, child: Text(t))],
              onChanged: _isEdit ? null : (v) => setState(() => _type = v ?? 'A'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _name,
              decoration: InputDecoration(
                labelText: context.tr('Name', '名称'),
                hintText: _type == 'SRV' ? '_sip._tcp' : context.tr('@ for root', '根域名填 @'),
                suffixText: _name.text.trim() == '@' || _name.text.trim().endsWith(widget.zoneName)
                    ? null
                    : '.${widget.zoneName}',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (!_usesData)
        TextFormField(
          controller: _content,
          minLines: 1,
          maxLines: _type == 'TXT' ? 6 : 1,
          style: const TextStyle(fontFamily: 'monospace'),
          validator: _validateContent,
          decoration: InputDecoration(
            labelText: switch (_type) {
              'A' => context.tr('IPv4 address', 'IPv4 地址'),
              'AAAA' => context.tr('IPv6 address', 'IPv6 地址'),
              'CNAME' => context.tr('Target', '目标'),
              'MX' => context.tr('Mail server', '邮件服务器'),
              'NS' => context.tr('Nameserver', '名称服务器'),
              _ => context.tr('Content', '内容'),
            },
            hintText: _contentHint(),
            border: const OutlineInputBorder(),
          ),
        )
      else
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final f in _dataFields[_type]!)
              SizedBox(
                width: f.numeric || f.options != null ? 150 : 480,
                child: f.options != null
                    ? DropdownButtonFormField<String>(
                        initialValue:
                            _dataOptions[f.key] ??
                            (widget.record?['data'] as Map?)?[f.key]?.toString() ??
                            f.options!.first,
                        decoration: InputDecoration(labelText: f.label.of(context), border: const OutlineInputBorder()),
                        items: [for (final o in f.options!) DropdownMenuItem(value: o, child: Text(o))],
                        onChanged: (v) => _dataOptions[f.key] = v,
                      )
                    : TextFormField(
                        controller: _dataController(f.key),
                        keyboardType: f.numeric ? TextInputType.number : TextInputType.text,
                        decoration: InputDecoration(
                          labelText: f.label.of(context),
                          hintText: f.hint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
              ),
          ],
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_hasPriority)
            SizedBox(
              width: 130,
              child: TextFormField(
                controller: _priority,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.tr('Priority', '优先级'),
                  hintText: '10',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<int>(
              initialValue: _ttls.contains(_ttl) ? _ttl : -1,
              decoration: const InputDecoration(labelText: 'TTL', border: OutlineInputBorder()),
              items: [
                for (final t in _ttls) DropdownMenuItem(value: t, child: Text(ttlLabel(context, t))),
                DropdownMenuItem(value: -1, child: Text(context.tr('Custom', '自定义'))),
              ],
              onChanged: (_proxied && proxiableTypes.contains(_type)) ? null : (v) => setState(() => _ttl = v ?? 1),
            ),
          ),
          if (_ttl == -1 && !(_proxied && proxiableTypes.contains(_type)))
            SizedBox(
              width: 130,
              child: TextFormField(
                controller: _customTtl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: context.tr('Seconds', '秒'), border: const OutlineInputBorder()),
              ),
            ),
          if (proxiableTypes.contains(_type))
            FilterChip(
              avatar: Icon(Icons.cloud, color: _proxied ? const Color(0xFFF38020) : null, size: 18),
              label: Text(_proxied ? context.tr('Proxied', '已代理') : context.tr('DNS only', '仅 DNS')),
              selected: _proxied,
              onSelected: (v) => setState(() {
                _proxied = v;
                if (v) _ttl = 1;
              }),
            ),
          if (_type == 'CNAME')
            FilterChip(
              label: Text(context.tr('Flatten CNAME', 'CNAME 拉平')),
              selected: _flatten,
              onSelected: (v) => setState(() => _flatten = v),
            ),
        ],
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _comment,
        decoration: InputDecoration(labelText: context.tr('Comment', '备注'), border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _tags,
        decoration: InputDecoration(
          labelText: context.tr('Tags', '标签'),
          hintText: 'env:prod, team:web',
          border: const OutlineInputBorder(),
        ),
      ),
    ];
    return AlertDialog(
      title: Text(_isEdit ? context.tr('Edit record', '编辑记录') : context.tr('Add record', '添加记录')),
      content: SizedBox(
        width: 620,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: fields),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel', '取消'))),
        FilledButton(
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.pop(context, _build());
          },
          child: Text(context.tr('Save', '保存')),
        ),
      ],
    );
  }
}
