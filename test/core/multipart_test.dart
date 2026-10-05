import 'dart:convert';
import 'dart:typed_data';

import 'package:cirrus/core/api/multipart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts boundary from content type', () {
    expect(multipartBoundary('multipart/form-data; boundary=abc123'), 'abc123');
    expect(multipartBoundary('multipart/form-data; boundary="quoted-b"; charset=utf-8'), 'quoted-b');
    expect(multipartBoundary('application/json'), isNull);
  });

  test('parses Workers module parts', () {
    const body =
        '--XYZ\r\n'
        'Content-Disposition: form-data; name="worker.js"; filename="worker.js"\r\n'
        'Content-Type: application/javascript+module\r\n'
        '\r\n'
        'export default { fetch() { return new Response("hi") } }\r\n'
        '--XYZ\r\n'
        'Content-Disposition: form-data; name="lib/util.js"; filename="lib/util.js"\r\n'
        'Content-Type: application/javascript+module\r\n'
        '\r\n'
        'export const x = 1;\n\r\n'
        '--XYZ--\r\n';
    final parts = parseMultipart(Uint8List.fromList(utf8.encode(body)), 'XYZ');
    expect(parts, hasLength(2));
    expect(parts[0].name, 'worker.js');
    expect(parts[0].filename, 'worker.js');
    expect(parts[0].contentType, 'application/javascript+module');
    expect(parts[0].text, 'export default { fetch() { return new Response("hi") } }');
    expect(parts[1].name, 'lib/util.js');
    expect(parts[1].text, 'export const x = 1;\n');
  });

  test('keeps binary content intact', () {
    final bytes = [0, 1, 2, 13, 10, 255];
    final body = <int>[
      ...utf8.encode(
        '--b\r\nContent-Disposition: form-data; name="m.wasm"; filename="m.wasm"\r\nContent-Type: application/wasm\r\n\r\n',
      ),
      ...bytes,
      ...utf8.encode('\r\n--b--'),
    ];
    final parts = parseMultipart(Uint8List.fromList(body), 'b');
    expect(parts.single.bytes, bytes);
  });
}
