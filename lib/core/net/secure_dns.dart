import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Domains whose names Cirrus looks up itself (comma separated; each also
/// covers its subdomains).
const _domains = String.fromEnvironment('CIRRUS_HTTPDNS_DOMAINS', defaultValue: 'routeforge.zone');

/// Token of the Tencent Cloud HTTPDNS HTTPS interface (console → 开发配置).
/// It only resolves the domains added in that console; empty disables it.
const _tencentToken = String.fromEnvironment('CIRRUS_HTTPDNS_TOKEN', defaultValue: '312242666');

/// The addresses of a name and how long they may be cached.
class DnsAnswer {
  const DnsAnswer(this.addresses, {this.ttl = const Duration(minutes: 1), required this.source});

  final List<InternetAddress> addresses;
  final Duration ttl;

  /// Which resolver answered: a [DnsSource.name], `system` or `fixed`.
  final String source;
}

/// A resolver queried over HTTPS.
abstract class DnsSource {
  String get name;

  /// The addresses of [host], or null when it has none.
  Future<DnsAnswer?> lookup(String host);
}

/// Tencent Cloud HTTPDNS over HTTPS
/// (https://cloud.tencent.com/document/product/379/95498). Its certificate
/// names the entry IP, so it is verified as usual.
class TencentHttpDns implements DnsSource {
  TencentHttpDns(this.token, {Uri? endpoint, HttpClient Function()? client})
    : endpoint = endpoint ?? Uri.parse('https://119.29.29.99/d'),
      _client = client ?? HttpClient.new;

  final String token;
  final Uri endpoint;
  final HttpClient Function() _client;

  @override
  String get name => 'tencent';

  @override
  Future<DnsAnswer?> lookup(String host) async {
    final uri = endpoint.replace(queryParameters: {'dn': host, 'token': token, 'type': 'addrs', 'ttl': '1'});
    return parse(await _getText(_client(), uri), source: name);
  }

  /// Parses `ip;ip,ttl-ip6;ip6,ttl|clientip`, where a missing family is `0`.
  static DnsAnswer? parse(String body, {String source = 'tencent'}) {
    var text = body.trim();
    final bar = text.indexOf('|');
    if (bar >= 0) text = text.substring(0, bar);
    final addresses = <InternetAddress>[];
    int? ttl;
    // IPv6 addresses contain ':' but never '-' or ','.
    for (final family in text.split('-')) {
      final comma = family.lastIndexOf(',');
      if (comma >= 0) {
        final t = int.tryParse(family.substring(comma + 1).trim());
        if (t != null && t > 0) ttl = ttl == null || t < ttl ? t : ttl;
      }
      for (final ip in (comma >= 0 ? family.substring(0, comma) : family).split(';')) {
        final address = InternetAddress.tryParse(ip.trim());
        if (address != null && !address.isLoopback && !_isUnspecified(address)) addresses.add(address);
      }
    }
    if (addresses.isEmpty) return null;
    return DnsAnswer(
      addresses,
      ttl: Duration(seconds: ttl ?? 60),
      source: source,
    );
  }
}

/// AliDNS's JSON API over HTTPS, reached at its anycast addresses
/// (223.5.5.5 / 223.6.6.6) rather than through the system resolver.
class AliDns implements DnsSource {
  AliDns({Uri? endpoint, HttpClient Function()? client})
    : endpoint = endpoint ?? Uri.parse('https://$host/resolve'),
      _client = client ?? HttpClient.new;

  static const host = 'dns.alidns.com';
  static final addresses = [
    InternetAddress('223.5.5.5'),
    InternetAddress('223.6.6.6'),
    InternetAddress('2400:3200::1'),
    InternetAddress('2400:3200:baba::1'),
  ];

  final Uri endpoint;
  final HttpClient Function() _client;

  @override
  String get name => 'alidns';

  @override
  Future<DnsAnswer?> lookup(String host) async {
    Future<String?> query(int type, {required bool required}) async {
      try {
        return await _getText(_client(), endpoint.replace(queryParameters: {'name': host, 'type': '$type'}));
      } catch (_) {
        if (required) rethrow;
        return null;
      }
    }

    final bodies = await Future.wait([query(1, required: true), query(28, required: false)]);
    return parse(bodies.nonNulls, source: name);
  }

  /// Collects the A and AAAA records of DNS JSON responses.
  static DnsAnswer? parse(Iterable<String> bodies, {String source = 'alidns'}) {
    final addresses = <InternetAddress>[];
    int? ttl;
    for (final body in bodies) {
      final Object? json;
      try {
        json = jsonDecode(body);
      } on FormatException {
        continue;
      }
      if (json is! Map || json['Status'] != 0 || json['Answer'] is! List) continue;
      for (final record in json['Answer'] as List) {
        if (record is! Map || (record['type'] != 1 && record['type'] != 28)) continue;
        final address = InternetAddress.tryParse('${record['data']}');
        if (address == null || address.isLoopback || _isUnspecified(address)) continue;
        addresses.add(address);
        final t = record['TTL'];
        if (t is int && t > 0) ttl = ttl == null || t < ttl ? t : ttl;
      }
    }
    if (addresses.isEmpty) return null;
    return DnsAnswer(
      addresses,
      ttl: Duration(seconds: ttl ?? 60),
      source: source,
    );
  }
}

bool _isUnspecified(InternetAddress a) => a.rawAddress.every((b) => b == 0);

Future<String> _getText(HttpClient client, Uri uri) async {
  client.connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/plain');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != HttpStatus.ok) throw HttpException('HTTP ${res.statusCode}', uri: uri);
    return body;
  } finally {
    client.close(force: true);
  }
}

/// Resolves Cirrus's own servers (`routeforge.zone` and its subdomains)
/// without trusting the system resolver, which some networks poison:
/// Tencent Cloud HTTPDNS first, then AliDNS, then the system resolver.
///
/// Connections still verify the server's certificate against the host name,
/// so a wrong answer can only make a connection fail, never redirect it.
/// When every address of an answer fails, the system resolver's addresses
/// are tried last.
class SecureDns {
  SecureDns({
    required List<String> domains,
    required this.sources,
    Map<String, List<InternetAddress>> fixed = const {},
    this.timeout = const Duration(seconds: 4),
    this.connectTimeout = const Duration(seconds: 6),
    this.maxStale = const Duration(days: 1),
    Future<List<InternetAddress>> Function(String host)? systemLookup,
    DateTime Function()? now,
  }) : domains = [for (final d in domains) _normalize(d)].where((d) => d.isNotEmpty).toList(),
       fixed = {for (final e in fixed.entries) _normalize(e.key): e.value},
       _systemLookup = systemLookup ?? InternetAddress.lookup,
       _now = now ?? DateTime.now;

  /// The build's configuration: `CIRRUS_HTTPDNS_DOMAINS` and
  /// `CIRRUS_HTTPDNS_TOKEN`.
  factory SecureDns.standard() {
    late final SecureDns dns;
    dns = SecureDns(
      domains: _domains.split(','),
      sources: [
        if (_tencentToken.trim().isNotEmpty) TencentHttpDns(_tencentToken.trim()),
        AliDns(client: () => dns.createHttpClient()),
      ],
      fixed: {AliDns.host: AliDns.addresses},
    );
    return dns;
  }

  static final instance = SecureDns.standard();

  /// Names this resolver handles, with their subdomains.
  final List<String> domains;

  /// Queried in order until one answers.
  final List<DnsSource> sources;

  /// Names with known addresses (the resolvers' own).
  final Map<String, List<InternetAddress>> fixed;

  /// How long each source may take.
  final Duration timeout;

  /// How long each address may take to accept a connection.
  final Duration connectTimeout;

  /// How long an expired answer is preferred to the system resolver when no
  /// source answers.
  final Duration maxStale;

  final Future<List<InternetAddress>> Function(String host) _systemLookup;
  final DateTime Function() _now;
  final _cache = <String, ({DnsAnswer answer, DateTime expires})>{};
  final _pending = <String, Future<DnsAnswer>>{};

  static String _normalize(String host) {
    final h = host.trim().toLowerCase();
    return h.endsWith('.') ? h.substring(0, h.length - 1) : h;
  }

  bool handles(String host) {
    final h = _normalize(host);
    return fixed.containsKey(h) || domains.any((d) => h == d || h.endsWith('.$d'));
  }

  /// The addresses of [host] (which [handles]).
  Future<DnsAnswer> resolve(String host) {
    final h = _normalize(host);
    final pinned = fixed[h];
    if (pinned != null) return Future.value(DnsAnswer(pinned, ttl: Duration.zero, source: 'fixed'));
    final hit = _cache[h];
    if (hit != null && _now().isBefore(hit.expires)) return Future.value(hit.answer);
    return _pending[h] ??= _lookup(h).whenComplete(() {
      _pending.remove(h);
    });
  }

  Future<DnsAnswer> _lookup(String host) async {
    for (final source in sources) {
      try {
        final answer = await source.lookup(host).timeout(timeout);
        if (answer != null && answer.addresses.isNotEmpty) return _remember(host, answer);
      } catch (_) {
        // Try the next one.
      }
    }
    final stale = _cache[host];
    if (stale != null && _now().difference(stale.expires) < maxStale) return stale.answer;
    return _remember(host, DnsAnswer(await _systemLookup(host), source: 'system'));
  }

  DnsAnswer _remember(String host, DnsAnswer answer) {
    final seconds = answer.ttl.inSeconds.clamp(30, 3600);
    _cache[host] = (answer: answer, expires: _now().add(Duration(seconds: seconds)));
    return answer;
  }

  /// Opens a connection to [host]:[port] at an address from [resolve], with
  /// TLS verified against [host] when [secure].
  Future<Socket> connect(String host, int port, {bool secure = false, SecurityContext? context}) async {
    final answer = await resolve(host);
    try {
      return await _connectAny(answer.addresses, host, port, secure, context);
    } on Object catch (error, stack) {
      if (answer.source == 'system') rethrow;
      _cache.remove(_normalize(host));
      final others = await _systemLookup(host).then(
        (all) => all.where((a) => !answer.addresses.contains(a)).toList(),
        onError: (Object _) => const <InternetAddress>[],
      );
      if (others.isEmpty) Error.throwWithStackTrace(error, stack);
      return _connectAny(others, host, port, secure, context);
    }
  }

  Future<Socket> _connectAny(
    List<InternetAddress> addresses,
    String host,
    int port,
    bool secure,
    SecurityContext? context,
  ) async {
    final ordered = [
      ...addresses.where((a) => a.type == InternetAddressType.IPv4),
      ...addresses.where((a) => a.type != InternetAddressType.IPv4),
    ];
    Object error = SocketException('No address for $host');
    for (final address in ordered) {
      Socket? socket;
      try {
        socket = await Socket.connect(address, port, timeout: connectTimeout);
        if (!secure) return socket;
        return await SecureSocket.secure(socket, host: host, context: context);
      } catch (e) {
        socket?.destroy();
        error = e;
      }
    }
    throw error;
  }

  /// An [HttpClient] that connects to the hosts this resolver [handles] at
  /// the addresses it finds, and to any other host as usual.
  HttpClient createHttpClient({SecurityContext? context}) {
    final client = HttpClient(context: context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      // Through a proxy, the proxy resolves the name.
      if (proxyHost != null && proxyPort != null) return Socket.startConnect(proxyHost, proxyPort);
      final secure = uri.isScheme('https');
      if (!handles(uri.host)) {
        return secure
            ? SecureSocket.startConnect(uri.host, uri.port, context: context)
            : Socket.startConnect(uri.host, uri.port);
      }
      var cancelled = false;
      final socket = connect(uri.host, uri.port, secure: secure, context: context).then((s) {
        if (!cancelled) return s;
        s.destroy();
        throw const SocketException('Connection attempt cancelled');
      });
      return Future.value(ConnectionTask.fromSocket(socket, () => cancelled = true));
    };
    return client;
  }
}

/// A Dio adapter whose connections to Cirrus's own servers use [SecureDns].
HttpClientAdapter secureDnsAdapter([SecureDns? dns]) =>
    IOHttpClientAdapter(createHttpClient: () => (dns ?? SecureDns.instance).createHttpClient());
