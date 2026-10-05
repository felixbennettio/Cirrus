import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/cf_exception.dart';
import '../../core/util/tr.dart';

void showToast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, maxLines: 6, overflow: TextOverflow.ellipsis),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? scheme.errorContainer : null,
        showCloseIcon: true,
        closeIconColor: error ? scheme.onErrorContainer : null,
        duration: Duration(seconds: error ? 8 : 3),
      ),
    );
}

String errorText(Object e) => switch (e) {
  final CfApiException c => c.summary,
  _ => e.toString(),
};

/// Runs a mutation with a blocking progress indicator and reports the
/// outcome. Returns the result, or `null` if it failed.
Future<T?> runAction<T>(
  BuildContext context,
  Future<T> Function() action, {
  String? success,
  bool blocking = true,
}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  var dialogShown = false;
  if (blocking) {
    dialogShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      ),
    );
  }
  try {
    final r = await action();
    if (dialogShown) nav.pop();
    if (context.mounted && success != null) showToast(context, success);
    return r;
  } catch (e) {
    if (dialogShown) nav.pop();
    if (context.mounted) showToast(context, errorText(e), error: true);
    return null;
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  String? confirmLabel,
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.tr('Cancel', '取消')),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel ?? ctx.tr('Confirm', '确认')),
        ),
      ],
    ),
  );
  return r == true;
}

/// Confirmation for destructive operations. When [typeToConfirm] is given
/// the user must type it (e.g. a zone or bucket name) before confirming.
Future<bool> confirmDanger(
  BuildContext context, {
  required String title,
  required String message,
  String? typeToConfirm,
  String? confirmLabel,
}) async {
  final controller = TextEditingController();
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final ok = typeToConfirm == null || controller.text.trim() == typeToConfirm;
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                if (typeToConfirm != null) ...[
                  const SizedBox(height: 16),
                  Text.rich(
                    TextSpan(
                      text: ctx.tr('Type ', '请输入 '),
                      children: [
                        TextSpan(
                          text: typeToConfirm,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                        ),
                        TextSpan(text: ctx.tr(' to confirm.', ' 以确认。')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.tr('Cancel', '取消')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: ok ? () => Navigator.pop(ctx, true) : null,
              child: Text(confirmLabel ?? ctx.tr('Delete', '删除')),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
  return r == true;
}

/// Simple single-field prompt.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? label,
  String? initial,
  String? hint,
  bool multiline = false,
  bool monospace = false,
  String? confirmLabel,
}) async {
  final controller = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: multiline ? 4 : 1,
          maxLines: multiline ? 14 : 1,
          style: monospace ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: multiline ? null : (v) => Navigator.pop(ctx, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.tr('Cancel', '取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirmLabel ?? ctx.tr('OK', '确定')),
        ),
      ],
    ),
  );
  controller.dispose();
  return r;
}

Future<void> copyText(BuildContext context, String text, {String? label}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    showToast(context, label ?? context.tr('Copied to clipboard', '已复制到剪贴板'));
  }
}

/// Shows a secret (e.g. a newly created token) once, with copy.
Future<void> showSecretDialog(
  BuildContext context, {
  required String title,
  required Map<String, String> values,
  String? note,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                note ??
                    ctx.tr(
                      'Copy these values now. They will not be shown again.',
                      '请立即复制这些值，之后将不会再次显示。',
                    ),
              ),
              const SizedBox(height: 12),
              for (final e in values.entries) ...[
                Text(e.key, style: Theme.of(ctx).textTheme.labelMedium),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          e.value,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => copyText(ctx, e.value),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.tr('Done', '完成')),
        ),
      ],
    ),
  );
}
