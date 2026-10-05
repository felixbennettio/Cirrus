import 'dart:io';

import 'package:cirrus/core/catalog/catalog.dart';
import 'package:cirrus/core/catalog/catalog_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ApiCatalog catalog;

  setUpAll(() {
    catalog = CatalogLoader.decode(File('assets/api/catalog.json.gz').readAsBytesSync());
  });

  test('bundled catalog covers the whole API', () {
    expect(catalog.operations.length, greaterThan(3000));
    expect(catalog.byProduct.keys, containsAll(['dns', 'workers', 'zero-trust', 'r2']));
  });

  test('finds operations by concrete path', () {
    final op = catalog.find('POST', '/zones/023e105f4ecef8ad9ca31a8372d0c353/dns_records');
    expect(op, isNotNull);
    expect(op!.permissions, contains('DNS Write'));
    expect(op.body?.isJson, isTrue);
    // The more specific template wins over a parameterised one.
    final batch = catalog.find('POST', '/zones/abc/dns_records/batch');
    expect(batch?.path, '/zones/{zone_id}/dns_records/batch');
  });

  test('search ranks relevant endpoints', () {
    final results = catalog.search('create dns record');
    expect(results.take(5).map((o) => o.path), contains('/zones/{zone_id}/dns_records'));
  });

  test('builds request skeletons from schemas', () {
    final op = catalog.find('POST', '/accounts/a/storage/kv/namespaces')!;
    final sk = catalog.skeleton(op.body!.schema);
    expect(sk, isA<Map>());
    expect((sk as Map).containsKey('title'), isTrue);
  });

  test('resolve merges allOf parts', () {
    final s = catalog.resolve({
      'allOf': [
        {
          'properties': {
            'a': {'type': 'string'},
          },
          'required': ['a'],
        },
        {
          'properties': {
            'b': {'type': 'integer'},
          },
        },
      ],
    });
    expect((s['properties'] as Map).keys, containsAll(['a', 'b']));
    expect(s['required'], ['a']);
    expect(s['type'], 'object');
  });

  test('builder keeps referenced schemas and drops credential headers', () {
    final built = buildCatalog({
      'info': {'title': 't', 'version': '1'},
      'paths': {
        '/zones/{zone_id}/things': {
          'post': {
            'operationId': 'things-create',
            'summary': 'Create thing',
            'x-api-token-group': ['Thing Write'],
            'parameters': [
              {
                'name': 'zone_id',
                'in': 'path',
                'schema': {'type': 'string'},
              },
              {
                'name': 'X-Auth-Key',
                'in': 'header',
                'schema': {'type': 'string'},
              },
            ],
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {r'$ref': '#/components/schemas/Thing'},
                },
              },
            },
          },
        },
      },
      'components': {
        'schemas': {
          'Thing': {
            'type': 'object',
            'properties': {
              'part': {r'$ref': '#/components/schemas/Part'},
            },
          },
          'Part': {'type': 'string', 'example': 'x'},
          'Unused': {'type': 'string'},
        },
      },
    });
    final op = (built['ops'] as List).single as Map;
    expect(op['perm'], ['Thing Write']);
    expect((op['params'] as List).map((p) => (p as Map)['n']), ['zone_id']);
    expect((built['schemas'] as Map).keys, containsAll(['Thing', 'Part']));
    expect((built['schemas'] as Map).containsKey('Unused'), isFalse);
  });
}
