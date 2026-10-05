// Builds the compact Cloudflare API catalog bundled with Cirrus.
//
// The official OpenAPI document (~26 MB) is reduced to the parts the app
// needs to browse, describe and call every endpoint: operations, parameters,
// request bodies and the component schemas they reference.
//
// Usage:
//   dart run tool/build_catalog.dart                 # download + build
//   dart run tool/build_catalog.dart --input api.json
//   dart run tool/build_catalog.dart --output assets/api/catalog.json.gz
import 'dart:convert';
import 'dart:io';

import 'package:cirrus/core/catalog/catalog_builder.dart';

Future<void> main(List<String> args) async {
  String? input;
  var output = 'assets/api/catalog.json.gz';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--input':
        input = args[++i];
      case '--output':
        output = args[++i];
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        exit(64);
    }
  }

  final raw = input != null ? await File(input).readAsString() : await _download(openApiSchemaUrl);
  final doc = jsonDecode(raw) as Map<String, dynamic>;
  final catalog = buildCatalog(doc);

  final json = utf8.encode(jsonEncode(catalog));
  final gz = gzip.encode(json);
  final file = File(output);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(gz);
  final ops = (catalog['ops'] as List).length;
  final schemas = (catalog['schemas'] as Map).length;
  stdout.writeln(
    'Catalog: $ops operations, $schemas schemas, '
    '${(json.length / 1024 / 1024).toStringAsFixed(2)} MB json, '
    '${(gz.length / 1024).toStringAsFixed(0)} KB gzip -> $output',
  );
}

Future<String> _download(String url) async {
  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    for (var attempt = 1; ; attempt++) {
      try {
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        if (res.statusCode != 200) {
          throw HttpException('HTTP ${res.statusCode} for $url');
        }
        return await res.transform(utf8.decoder).join();
      } catch (e) {
        if (attempt >= 4) rethrow;
        stderr.writeln('Download failed ($e), retrying...');
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
  } finally {
    client.close();
  }
}
