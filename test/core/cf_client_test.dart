import 'package:cirrus/core/api/cf_client.dart';
import 'package:cirrus/core/api/cf_exception.dart';
import 'package:cirrus/core/auth/credential.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_api.dart';

const tokenProfile = Profile(id: 't', name: 'Token', kind: AuthKind.apiToken, token: 'tok_1234567890abcdef');
const keyProfile = Profile(
  id: 'k',
  name: 'Key',
  kind: AuthKind.globalKey,
  email: 'me@example.com',
  apiKey: 'globalkey1234567890',
  originCaKey: 'v1.0-origin-ca-key',
);

(CfClient, FakeApi) client(FakeHandler handler, {Profile profile = tokenProfile}) {
  final api = FakeApi(handler);
  final dio = Dio()..httpClientAdapter = api;
  return (CfClient(profile, dio: dio), api);
}

void main() {
  group('envelope', () {
    test('returns result and result_info', () {
      final r = CfClient.parseEnvelope(
        method: 'GET',
        path: '/zones',
        statusCode: 200,
        body: FakeApi.ok([1, 2], info: {'page': 1, 'total_pages': 3}),
      );
      expect(r.result, [1, 2]);
      expect(r.resultInfo?['total_pages'], 3);
    });

    test('throws CfApiException with API errors', () {
      expect(
        () => CfClient.parseEnvelope(
          method: 'GET',
          path: '/zones/x',
          statusCode: 403,
          body: FakeApi.fail(9109, 'Unauthorized to access requested resource'),
        ),
        throwsA(
          isA<CfApiException>()
              .having((e) => e.statusCode, 'status', 403)
              .having((e) => e.errors.single.code, 'code', 9109)
              .having((e) => e.isAuthError, 'auth', true)
              .having((e) => e.summary, 'summary', contains('Unauthorized')),
        ),
      );
    });

    test('success:false with HTTP 200 still throws', () {
      expect(
        () => CfClient.parseEnvelope(
          method: 'POST',
          path: '/x',
          statusCode: 200,
          body: FakeApi.fail(1004, 'DNS Validation Error'),
        ),
        throwsA(isA<CfApiException>()),
      );
    });

    test('non-envelope JSON is returned as-is', () {
      final r = CfClient.parseEnvelope(method: 'GET', path: '/raw', statusCode: 200, body: {'data': 1});
      expect(r.result, {'data': 1});
    });

    test('non-2xx text body throws with body', () {
      expect(
        () => CfClient.parseEnvelope(method: 'GET', path: '/x', statusCode: 502, body: 'Bad gateway'),
        throwsA(isA<CfApiException>().having((e) => e.summary, 'summary', 'Bad gateway')),
      );
    });
  });

  group('auth headers', () {
    test('API token uses bearer auth', () async {
      final (c, api) = client((m, u, b) => (200, FakeApi.ok({}), const {}));
      await c.get('/user/tokens/verify');
      expect(api.calls.single.headers['Authorization'], 'Bearer tok_1234567890abcdef');
      expect(api.calls.single.headers['User-Agent'], startsWith('Cirrus/'));
    });

    test('global key uses email + key, Origin CA key for /certificates', () async {
      final (c, api) = client((m, u, b) => (200, FakeApi.ok([]), const {}), profile: keyProfile);
      await c.get('/user');
      await c.get('/certificates');
      expect(api.calls[0].headers['X-Auth-Email'], 'me@example.com');
      expect(api.calls[0].headers['X-Auth-Key'], 'globalkey1234567890');
      expect(api.calls[1].headers['X-Auth-User-Service-Key'], 'v1.0-origin-ca-key');
      expect(api.calls[1].headers.containsKey('X-Auth-Key'), isFalse);
    });
  });

  group('pagination', () {
    test('follows page numbers', () async {
      final (c, api) = client((m, u, b) {
        final page = int.parse(u.queryParameters['page'] ?? '1');
        return (
          200,
          FakeApi.ok(
            [
              {'id': 'p$page'},
            ],
            info: {'page': page, 'per_page': 1, 'total_pages': 3},
          ),
          const {},
        );
      });
      final list = await c.list('/zones', perPage: 1);
      expect(list.map((e) => e['id']), ['p1', 'p2', 'p3']);
      expect(api.calls, hasLength(3));
    });

    test('follows cursors', () async {
      final (c, api) = client((m, u, b) {
        final cursor = u.queryParameters['cursor'];
        expect(u.queryParameters.containsKey('page'), isFalse);
        if (cursor == null) {
          return (
            200,
            FakeApi.ok(
              [
                {'id': 'a'},
              ],
              info: {
                'cursors': {'after': 'c2'},
              },
            ),
            const {},
          );
        }
        if (cursor == 'c2') {
          return (
            200,
            FakeApi.ok(
              [
                {'id': 'b'},
              ],
              info: {'cursors': <String, String>{}},
            ),
            const {},
          );
        }
        return null;
      });
      final list = await c.list('/accounts/x/rules/lists/y/items', cursorPagination: true);
      expect(list.map((e) => e['id']), ['a', 'b']);
      expect(api.calls, hasLength(2));
    });

    test('stops when the server ignores the page parameter', () async {
      final (c, api) = client(
        (m, u, b) => (
          200,
          FakeApi.ok(
            [
              {'id': 'same'},
            ],
            info: {'page': 1, 'per_page': 1, 'total_pages': 5},
          ),
          const {},
        ),
      );
      final list = await c.list('/x', perPage: 1);
      expect(list, hasLength(2));
      expect(api.calls, hasLength(2));
    });

    test('unwraps result.buckets lists', () async {
      final (c, _) = client(
        (m, u, b) => (
          200,
          FakeApi.ok({
            'buckets': [
              {'name': 'assets'},
            ],
          }),
          const {},
        ),
      );
      final p = await c.page('/accounts/x/r2/buckets');
      expect(p.items.single, {'name': 'assets'});
    });
  });

  test('retries rate-limited requests', () async {
    var n = 0;
    final (c, api) = client((m, u, b) {
      n++;
      if (n == 1) {
        return (
          429,
          FakeApi.fail(10000, 'Rate limited'),
          const {
            'retry-after': ['1'],
          },
        );
      }
      return (200, FakeApi.ok('done'), const <String, List<String>>{});
    });
    expect(await c.get('/zones'), 'done');
    expect(api.calls, hasLength(2));
  });

  test('graphql errors are raised', () async {
    final (c, _) = client(
      (m, u, b) => (
        200,
        {
          'data': null,
          'errors': [
            {'message': 'unknown field'},
          ],
        },
        const {},
      ),
    );
    expect(
      () => c.graphql('{ viewer { x } }'),
      throwsA(isA<CfApiException>().having((e) => e.summary, 's', contains('unknown field'))),
    );
  });

  test('cURL export masks credentials by default', () {
    final (c, _) = client((m, u, b) => null);
    final masked = c.curl('POST', '/zones/z/dns_records', body: {'type': 'A'});
    expect(masked, contains(r'Bearer $CLOUDFLARE_API_TOKEN'));
    expect(masked, isNot(contains('tok_1234567890abcdef')));
    expect(masked, contains('"type": "A"'));
    expect(c.curl('GET', '/zones', includeSecrets: true), contains('tok_1234567890abcdef'));
  });
}
