import 'dart:convert';
import 'dart:typed_data';

/// One part of a `multipart/form-data` body.
class MultipartPart {
  MultipartPart({required this.headers, required this.bytes});

  final Map<String, String> headers;
  final Uint8List bytes;

  String? get contentType => headers['content-type'];

  String? _dispositionParam(String key) {
    final d = headers['content-disposition'];
    if (d == null) return null;
    final m = RegExp('$key="([^"]*)"').firstMatch(d) ?? RegExp('$key=([^;]+)').firstMatch(d);
    return m?.group(1)?.trim();
  }

  String? get name => _dispositionParam('name');
  String? get filename => _dispositionParam('filename');
  String get text => utf8.decode(bytes, allowMalformed: true);
}

/// Extracts the boundary from a `Content-Type` header value.
String? multipartBoundary(String? contentType) {
  if (contentType == null) return null;
  final m = RegExp(r'boundary="?([^";]+)"?', caseSensitive: false).firstMatch(contentType);
  return m?.group(1);
}

/// Minimal RFC 7578 parser (enough for Workers script downloads).
List<MultipartPart> parseMultipart(Uint8List body, String boundary) {
  final delimiter = utf8.encode('--$boundary');
  final parts = <MultipartPart>[];
  int indexOf(List<int> pattern, int start) {
    outer:
    for (var i = start; i <= body.length - pattern.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (body[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  var pos = indexOf(delimiter, 0);
  while (pos >= 0) {
    var start = pos + delimiter.length;
    // "--" after the delimiter marks the end.
    if (start + 1 < body.length && body[start] == 45 && body[start + 1] == 45) break;
    // Skip CRLF.
    if (start < body.length && body[start] == 13) start++;
    if (start < body.length && body[start] == 10) start++;
    final next = indexOf(delimiter, start);
    if (next < 0) break;
    var end = next;
    // Strip the CRLF preceding the next delimiter.
    if (end > start && body[end - 1] == 10) end--;
    if (end > start && body[end - 1] == 13) end--;
    final chunk = Uint8List.sublistView(body, start, end);
    // Split headers and content at the first blank line.
    var split = -1;
    for (var i = 0; i + 3 < chunk.length; i++) {
      if (chunk[i] == 13 && chunk[i + 1] == 10 && chunk[i + 2] == 13 && chunk[i + 3] == 10) {
        split = i;
        break;
      }
    }
    var sepLen = 4;
    if (split < 0) {
      for (var i = 0; i + 1 < chunk.length; i++) {
        if (chunk[i] == 10 && chunk[i + 1] == 10) {
          split = i;
          sepLen = 2;
          break;
        }
      }
    }
    final headers = <String, String>{};
    Uint8List content;
    if (split < 0) {
      content = Uint8List.fromList(chunk);
    } else {
      final headerText = latin1.decode(chunk.sublist(0, split));
      for (final line in headerText.split(RegExp(r'\r?\n'))) {
        final i = line.indexOf(':');
        if (i > 0) headers[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
      }
      content = Uint8List.fromList(chunk.sublist(split + sepLen));
    }
    parts.add(MultipartPart(headers: headers, bytes: content));
    pos = next;
  }
  return parts;
}
