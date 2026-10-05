import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/util/tr.dart';
import 'feedback.dart';

/// Saves bytes through the native "save as" dialog, falling back to the
/// share sheet where saving is not supported.
Future<void> saveBytes(
  BuildContext context, {
  required String fileName,
  required Uint8List bytes,
  String mimeType = 'application/octet-stream',
}) async {
  try {
    final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mimeType);
    if (uri != null && context.mounted) {
      showToast(context, context.tr('Saved $fileName', '已保存 $fileName'));
    }
  } catch (_) {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: fileName, mimeType: mimeType)],
        fileNameOverrides: [fileName],
      ),
    );
  }
}

Future<void> saveText(
  BuildContext context, {
  required String fileName,
  required String text,
  String mimeType = 'text/plain',
}) => saveBytes(context, fileName: fileName, bytes: Uint8List.fromList(utf8.encode(text)), mimeType: mimeType);

/// A picked file's name and contents.
class PickedFile {
  PickedFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

Future<PickedFile?> pickFile({List<String>? extensions}) async {
  final f = await FilePicker.pickFile(
    type: extensions == null ? FileType.any : FileType.custom,
    allowedExtensions: extensions,
  );
  if (f == null) return null;
  return PickedFile(f.name, await f.readAsBytes());
}

Future<List<PickedFile>> pickFiles() async {
  final list = await FilePicker.pickFiles();
  return [for (final f in list) PickedFile(f.name, await f.readAsBytes())];
}
