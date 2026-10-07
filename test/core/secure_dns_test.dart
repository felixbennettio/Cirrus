import 'dart:convert';
import 'dart:io';

import 'package:cirrus/core/net/secure_dns.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/tls_fixture.dart';

class _FakeSource implements DnsSource {
  _FakeSource(this.name, this.answer);

  @override
  final String name;
  DnsAnswer? Function(String host) answer;
  final asked = <String>[];

  @override
  Future<DnsAnswer?> lookup(String host) async {
    asked.add(host);
    return answer(host);
  }
}

DnsAnswer _answer(List<String> ips, {String source = 'fake', int ttl = 120}) => DnsAnswer(
  [for (final ip in ips) InternetAddress(ip)],
  ttl: Duration(seconds: ttl),
  source: source,
);

List<String> _ips(DnsAnswer? a) => [for (final x in a?.addresses ?? const <InternetAddress>[]) x.address];

void main() {
  group('Tencent HTTPDNS responses', () {
    test('IPv4 with TTL', () {
      final a = TencentHttpDns.parse('2.3.3.4;2.3.3.5;2.3.3.6,120');
      expect(_ips(a), ['2.3.3.4', '2.3.3.5', '2.3.3.6']);
      expect(a!.ttl, const Duration(seconds: 120));
    });

    test('A and AAAA with client IP', () {
      final a = TencentHttpDns.parse(
        '2.3.3.4;2.3.3.5,120-2402:4e00:123:4567::2345;2403:4e00:123:4567::2346,60|1.2.3.4',
      );
      expect(_ips(a), hasLength(4));
      expect(a!.addresses.where((x) => x.type == InternetAddressType.IPv6), hasLength(2));
      expect(a.ttl, const Duration(seconds: 60));
    });

    test('only one family', () {
      expect(_ips(TencentHttpDns.parse('43.174.246.104,60-0')), ['43.174.246.104']);
      expect(_ips(TencentHttpDns.parse('0-2402:4e00::1,60')), ['2402:4e00::1']);
    });

    test('no records', () {
      for (final body in ['', '0', '0-0', '0-0|1.2.3.4', 'not an address', '127.0.0.1,60', '0.0.0.0']) {
        expect(TencentHttpDns.parse(body), isNull, reason: body);
      }
    });

    test('without TTL', () {
      expect(TencentHttpDns.parse('1.2.3.4;5.6.7.8')!.ttl, const Duration(seconds: 60));
    });
  });

  group('AliDNS responses', () {
    test('follows the CNAME chain to A and AAAA records', () {
      final a = AliDns.parse([
        jsonEncode({
          'Status': 0,
          'Answer': [
            {'name': 'cirrus.routeforge.zone.', 'TTL': 600, 'type': 5, 'data': 'cirrus.routeforge.zone.eo.dnse2.com.'},
            {'name': 'cirrus.routeforge.zone.eo.dnse2.com.', 'TTL': 60, 'type': 1, 'data': '43.174.246.104'},
            {'name': 'cirrus.routeforge.zone.eo.dnse2.com.', 'TTL': 90, 'type': 1, 'data': '43.174.247.104'},
          ],
        }),
        jsonEncode({
          'Status': 0,
          'Answer': [
            {'TTL': 30, 'type': 28, 'data': '2402:4e00::1'},
          ],
        }),
      ]);
      expect(_ips(a), ['43.174.246.104', '43.174.247.104', '2402:4e00::1']);
      expect(a!.ttl, const Duration(seconds: 30));
    });

    test('errors and empty answers', () {
      expect(
        AliDns.parse([
          jsonEncode({'Status': 3}),
        ]),
        isNull,
      );
      expect(
        AliDns.parse([
          jsonEncode({'Status': 0, 'Answer': []}),
        ]),
        isNull,
      );
      expect(AliDns.parse(['<html>']), isNull);
    });
  });

  group('SecureDns', () {
    late DateTime now;
    late _FakeSource first;
    late _FakeSource second;
    late List<String> systemAsked;
    late SecureDns dns;

    setUp(() {
      now = DateTime(2026, 10, 7);
      first = _FakeSource('first', (_) => _answer(['10.0.0.1'], source: 'first'));
      second = _FakeSource('second', (_) => _answer(['10.0.0.2'], source: 'second'));
      systemAsked = [];
      dns = SecureDns(
        domains: ['routeforge.zone'],
        sources: [first, second],
        fixed: {
          'dns.example': [InternetAddress('192.0.2.53')],
        },
        systemLookup: (host) async {
          systemAsked.add(host);
          return [InternetAddress('10.0.0.3')];
        },
        now: () => now,
      );
    });

    test('handles the domain, its subdomains and the fixed names only', () {
      expect(dns.handles('routeforge.zone'), isTrue);
      expect(dns.handles('cirrus.routeforge.zone'), isTrue);
      expect(dns.handles('A.B.RouteForge.Zone.'), isTrue);
      expect(dns.handles('dns.example'), isTrue);
      expect(dns.handles('evilrouteforge.zone'), isFalse);
      expect(dns.handles('api.cloudflare.com'), isFalse);
    });

    test('asks the sources in order and caches for the TTL', () async {
      first.answer = (_) => throw const SocketException('down');
      expect(_ips(await dns.resolve('cirrus.routeforge.zone')), ['10.0.0.2']);
      expect(first.asked, hasLength(1));

      first.answer = (_) => _answer(['10.0.0.1']);
      now = now.add(const Duration(seconds: 119));
      expect(_ips(await dns.resolve('cirrus.routeforge.zone')), ['10.0.0.2']);
      expect(second.asked, hasLength(1));

      now = now.add(const Duration(seconds: 2));
      expect(_ips(await dns.resolve('cirrus.routeforge.zone')), ['10.0.0.1']);
      expect(systemAsked, isEmpty);
    });

    test('a source with no records falls through to the next', () async {
      first.answer = (_) => null;
      expect((await dns.resolve('cirrus.routeforge.zone')).source, 'second');
    });

    test('concurrent lookups share one query', () async {
      await Future.wait([for (var i = 0; i < 5; i++) dns.resolve('cirrus.routeforge.zone')]);
      expect(first.asked, hasLength(1));
    });

    test('prefers a stale answer to the system resolver, for a while', () async {
      await dns.resolve('cirrus.routeforge.zone');
      first.answer = (_) => throw const SocketException('down');
      second.answer = (_) => throw const SocketException('down');

      now = now.add(const Duration(hours: 2));
      expect(_ips(await dns.resolve('cirrus.routeforge.zone')), ['10.0.0.1']);
      expect(systemAsked, isEmpty);

      now = now.add(const Duration(days: 2));
      final a = await dns.resolve('cirrus.routeforge.zone');
      expect(a.source, 'system');
      expect(systemAsked, ['cirrus.routeforge.zone']);
    });

    test('fixed names never reach the sources', () async {
      expect(_ips(await dns.resolve('dns.example')), ['192.0.2.53']);
      expect(first.asked, isEmpty);
    });
  });

  group('connections', () {
    late HttpServer server;
    late SecurityContext clientContext;

    SecureDns dnsFor(Map<String, String> answers, {List<String> system = const []}) => SecureDns(
      domains: ['cirrus.test', 'wrong.test'],
      sources: [
        _FakeSource('fake', (host) => answers[host] == null ? null : _answer([answers[host]!])),
      ],
      systemLookup: (_) async => [for (final ip in system) InternetAddress(ip)],
    );

    Future<String> get(HttpClient client, String url) async {
      client.findProxy = (_) => 'DIRECT';
      try {
        final res = await (await client.getUrl(Uri.parse(url))).close();
        return await res.transform(utf8.decoder).join();
      } finally {
        client.close(force: true);
      }
    }

    setUp(() async {
      final serverContext = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(testServerCertPem))
        ..usePrivateKeyBytes(utf8.encode(testServerKeyPem));
      server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverContext);
      server.listen((req) {
        req.response
          ..write('host=${req.headers.host}')
          ..close();
      });
      clientContext = SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(testCaPem));
    });

    tearDown(() => server.close(force: true));

    test('connects to the resolved address and verifies the certificate against the name', () async {
      final dns = dnsFor({'api.cirrus.test': '127.0.0.1'});
      final body = await get(dns.createHttpClient(context: clientContext), 'https://api.cirrus.test:${server.port}/');
      expect(body, 'host=api.cirrus.test');
    });

    test('a certificate for another name is rejected', () async {
      final dns = dnsFor({'api.wrong.test': '127.0.0.1'});
      await expectLater(
        get(dns.createHttpClient(context: clientContext), 'https://api.wrong.test:${server.port}/'),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('falls back to the system resolver when the answer does not connect', () async {
      // 192.0.2.0/24 is reserved for documentation; nothing answers there.
      final dns = SecureDns(
        domains: ['cirrus.test'],
        sources: [
          _FakeSource('fake', (_) => _answer(['192.0.2.1'])),
        ],
        connectTimeout: const Duration(milliseconds: 300),
        systemLookup: (_) async => [InternetAddress.loopbackIPv4],
      );
      final body = await get(dns.createHttpClient(context: clientContext), 'https://cirrus.test:${server.port}/');
      expect(body, 'host=cirrus.test');
    });

    test('other hosts connect as usual', () async {
      final dns = dnsFor({});
      final body = await get(
        dns.createHttpClient(context: clientContext),
        'https://localhost:${server.port}/',
      ).then((b) => b, onError: (Object e) => '$e');
      // localhost is not on the certificate: the usual verification ran.
      expect(body, contains('HandshakeException'));
    });
  });
}
