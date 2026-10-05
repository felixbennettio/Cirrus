import 'dart:io';

import 'package:cirrus/app/feature_routes.dart';
import 'package:cirrus/core/catalog/catalog.dart';
import 'package:cirrus/features/generic/resource_page.dart';
import 'package:cirrus/features/generic/resource_specs.dart';
import 'package:cirrus/ui/shell/nav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _ids = {
  'account_id': 'acc0000',
  'account_identifier': 'acc0000',
  'account_tag': 'acc0000',
  'zone_id': 'zone0000',
  'zone_identifier': 'zone0000',
};

void main() {
  late ApiCatalog catalog;

  setUpAll(() {
    catalog = CatalogLoader.decode(File('assets/api/catalog.json.gz').readAsBytesSync());
  });

  void expectOp(String method, String template, {String? id, String? parent, required String spec}) {
    final path = fillPath(template, _ids, id: id ?? 'item0000', parent: parent ?? 'parent0000');
    expect(catalog.find(method, path), isNotNull, reason: '$spec: no $method $template in the API catalog');
  }

  void checkSpec(ResourceSpec s, {bool child = false}) {
    expectOp('GET', s.listPath, spec: s.id);
    if (s.canCreate) expectOp('POST', s.createPath ?? s.listPath, spec: s.id);
    if (s.updateMethod != null) expectOp(s.updateMethod!, s.resolvedItemPath, spec: s.id);
    if (s.canDelete) expectOp('DELETE', s.resolvedItemPath, spec: s.id);
    for (final a in [...s.actions, ...s.listActions]) {
      expectOp(a.method, a.path, spec: '${s.id}/${a.label.en}');
    }
    for (final c in s.children) {
      checkSpec(c, child: true);
    }
  }

  test('every resource spec maps to real API operations', () {
    for (final s in resourceSpecs) {
      checkSpec(s);
    }
  });

  test('every document spec maps to real API operations', () {
    for (final d in documentSpecs) {
      expectOp('GET', d.path, spec: d.id);
      if (d.method != null) expectOp(d.method!, d.path, spec: d.id);
    }
  });

  test('spec ids are unique', () {
    final ids = [for (final s in resourceSpecs) ...[s.id, for (final c in s.children) c.id]];
    expect(ids.toSet().length, ids.length);
  });

  test('every navigation entry has a route', () {
    final paths = <String>{'/', '/domains', '/settings'};
    void collect(List<RouteBase> routes, String prefix) {
      for (final r in routes) {
        if (r is GoRoute) {
          final full = r.path.startsWith('/') ? r.path : '$prefix/${r.path}';
          paths.add(full);
          collect(r.routes, full);
        }
      }
    }

    collect(featureRoutes, '');
    for (final item in allNavItems) {
      expect(paths, contains(item.path), reason: 'No route for nav item ${item.id} (${item.path})');
    }
  });
}
