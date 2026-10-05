import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/files.dart';
import '../../ui/widgets/json_view.dart';

Future<List<Map<String, dynamic>>> _models(CfClient c, String accountId) =>
    c.list('/accounts/$accountId/ai/models/search', perPage: 100, maxItems: 1000);

String _taskOf(Map m) => '${(m['task'] as Map?)?['name'] ?? ''}';

class AiPage extends StatelessWidget {
  const AiPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: PageScaffold(
        title: 'Workers AI',
        bottom: TabBar(tabs: [
          Tab(text: context.tr('Chat', '对话')),
          Tab(text: context.tr('Image', '图像生成')),
          Tab(text: context.tr('Models', '模型')),
        ]),
        body: AccountRequired(
          builder: (context, accountId) => TabBarView(
            children: [
              _Chat(accountId: accountId),
              _ImageGen(accountId: accountId),
              _Models(accountId: accountId),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chat extends ConsumerStatefulWidget {
  const _Chat({required this.accountId});

  final String accountId;

  @override
  ConsumerState<_Chat> createState() => _ChatState();
}

class _ChatState extends ConsumerState<_Chat> with AutomaticKeepAliveClientMixin {
  final _input = TextEditingController();
  final _system = TextEditingController(text: 'You are a helpful assistant.');
  final List<Map<String, String>> _messages = [];
  String? _model;
  bool _busy = false;
  final _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _input.dispose();
    _system.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _model == null || _busy) return;
    setState(() {
      _messages.add({'role': 'user', 'content': text});
      _input.clear();
      _busy = true;
    });
    try {
      final c = ref.read(clientProvider)!;
      final r = await c.post('/accounts/${widget.accountId}/ai/run/$_model', data: {
        'messages': [
          if (_system.text.trim().isNotEmpty) {'role': 'system', 'content': _system.text.trim()},
          ..._messages,
        ],
        'max_tokens': 2048,
      });
      final reply = r is Map ? (r['response'] ?? (r['choices'] as List?)?.firstOrNull?['message']?['content'] ?? prettyJson(r)) : '$r';
      setState(() => _messages.add({'role': 'assistant', 'content': reply is String ? reply : prettyJson(reply)}));
    } catch (e) {
      setState(() => _messages.add({'role': 'error', 'content': errorText(e)}));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'ai-models:${widget.accountId}',
      load: (c) => _models(c, widget.accountId),
      builder: (context, models, _) {
        final textModels = models.where((m) => _taskOf(m) == 'Text Generation').map((m) => m['name'] as String).toList()..sort();
        _model ??= textModels.firstWhere((m) => m.contains('llama-3.3-70b'), orElse: () => textModels.firstOrNull ?? '');
        if (_model!.isEmpty) _model = null;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _model,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: context.tr('Model', '模型'), border: const OutlineInputBorder(), isDense: true),
                      items: [for (final m in textModels) DropdownMenuItem(value: m, child: Text(m, overflow: TextOverflow.ellipsis))],
                      onChanged: (v) => setState(() => _model = v),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('System prompt', '系统提示词'),
                    icon: const Icon(Icons.tune),
                    onPressed: () async {
                      final t = await promptText(context, title: context.tr('System prompt', '系统提示词'), initial: _system.text, multiline: true);
                      if (t != null) _system.text = t;
                    },
                  ),
                  IconButton(tooltip: context.tr('New chat', '新对话'), icon: const Icon(Icons.add_comment_outlined), onPressed: () => setState(_messages.clear)),
                ],
              ),
            ),
            Expanded(
              child: _messages.isEmpty
                  ? EmptyView(icon: Icons.auto_awesome, title: context.tr('Chat with models running on Cloudflare', '与运行在 Cloudflare 上的模型对话'))
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        final user = m['role'] == 'user';
                        final err = m['role'] == 'error';
                        return Align(
                          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 720),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: err
                                  ? theme.colorScheme.errorContainer
                                  : user
                                  ? theme.colorScheme.primaryContainer
                                  : theme.colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: SelectableText(m['content'] ?? ''),
                          ),
                        );
                      },
                    ),
            ),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(hintText: context.tr('Message', '输入消息'), border: const OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(onPressed: _busy ? null : _send, icon: const Icon(Icons.send)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ImageGen extends ConsumerStatefulWidget {
  const _ImageGen({required this.accountId});

  final String accountId;

  @override
  ConsumerState<_ImageGen> createState() => _ImageGenState();
}

class _ImageGenState extends ConsumerState<_ImageGen> with AutomaticKeepAliveClientMixin {
  final _prompt = TextEditingController(text: 'A cirrus cloud over a mountain lake at sunrise, watercolor');
  String? _model;
  Uint8List? _image;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_model == null) return;
    setState(() => _busy = true);
    try {
      final c = ref.read(clientProvider)!;
      final r = await c.raw('POST', '/accounts/${widget.accountId}/ai/run/$_model', data: {'prompt': _prompt.text.trim()});
      final ct = r.header('content-type') ?? '';
      Uint8List? bytes;
      if (ct.startsWith('image/')) {
        bytes = r.bytes;
      } else {
        final body = jsonDecode(r.text);
        if (body is Map && body['success'] == false) throw Exception((body['errors'] as List?)?.map((e) => (e as Map)['message']).join('\n') ?? r.text);
        String? img;
        if (body is Map) {
          final result = body['result'];
          if (result is Map) img = result['image'] as String?;
        }
        if (img != null) bytes = base64Decode(img);
      }
      setState(() => _image = bytes);
      if (bytes == null && mounted) showToast(context, context.tr('Model returned no image', '模型未返回图像'), error: true);
    } catch (e) {
      if (mounted) showToast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'ai-models:${widget.accountId}',
      load: (c) => _models(c, widget.accountId),
      builder: (context, models, _) {
        final imageModels = models.where((m) => _taskOf(m) == 'Text-to-Image').map((m) => m['name'] as String).toList()..sort();
        _model ??= imageModels.firstWhere((m) => m.contains('flux'), orElse: () => imageModels.firstOrNull ?? '');
        if (_model!.isEmpty) _model = null;
        return ContentList(
          maxWidth: 900,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _model,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.tr('Model', '模型'), border: const OutlineInputBorder()),
              items: [for (final m in imageModels) DropdownMenuItem(value: m, child: Text(m))],
              onChanged: (v) => setState(() => _model = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _prompt,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: context.tr('Prompt', '提示词'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _generate,
                  icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.brush),
                  label: Text(context.tr('Generate', '生成')),
                ),
                const SizedBox(width: 8),
                if (_image != null)
                  OutlinedButton.icon(
                    onPressed: () => saveBytes(context, fileName: 'cirrus-ai.png', bytes: _image!, mimeType: 'image/png'),
                    icon: const Icon(Icons.save_alt),
                    label: Text(context.tr('Save', '保存')),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_image != null) ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_image!, fit: BoxFit.contain)),
          ],
        );
      },
    );
  }
}

class _Models extends ConsumerStatefulWidget {
  const _Models({required this.accountId});

  final String accountId;

  @override
  ConsumerState<_Models> createState() => _ModelsState();
}

class _ModelsState extends ConsumerState<_Models> {
  String _q = '';
  String _task = 'all';

  Future<void> _run(Map<String, dynamic> m) async {
    final name = m['name'] as String;
    final task = _taskOf(m);
    final example = switch (task) {
      'Text Generation' => {
        'messages': [
          {'role': 'user', 'content': 'Hello!'},
        ],
      },
      'Text Embeddings' => {
        'text': ['Cirrus is fast'],
      },
      'Translation' => {'text': 'Hello world', 'source_lang': 'english', 'target_lang': 'chinese'},
      'Summarization' => {'input_text': 'Long text to summarize…', 'max_length': 128},
      'Text Classification' => {'text': 'I love this product!'},
      _ => {'prompt': 'Hello'},
    };
    final input = await promptText(
      context,
      title: name,
      initial: prettyJson(example),
      multiline: true,
      monospace: true,
      confirmLabel: context.tr('Run', '运行'),
    );
    if (input == null || !mounted) return;
    final Object? body;
    try {
      body = jsonDecode(input);
    } catch (_) {
      showToast(context, context.tr('Invalid JSON', 'JSON 格式错误'), error: true);
      return;
    }
    final c = ref.read(clientProvider)!;
    final r = await runAction(context, () => c.post('/accounts/${widget.accountId}/ai/run/$name', data: body));
    if (r != null && mounted) await showJsonDialog(context, r, title: name);
  }

  @override
  Widget build(BuildContext context) {
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'ai-models:${widget.accountId}',
      load: (c) => _models(c, widget.accountId),
      builder: (context, models, h) {
        final tasks = {for (final m in models) _taskOf(m)}.where((t) => t.isNotEmpty).toList()..sort();
        final q = _q.toLowerCase();
        final list = models.where((m) {
          if (_task != 'all' && _taskOf(m) != _task) return false;
          return q.isEmpty || '${m['name']} ${m['description']}'.toLowerCase().contains(q);
        }).toList()
          ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(child: SearchField(onChanged: (v) => setState(() => _q = v.trim()))),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _task,
                    underline: const SizedBox(),
                    items: [
                      DropdownMenuItem(value: 'all', child: Text(context.tr('All tasks', '全部任务'))),
                      for (final t in tasks) DropdownMenuItem(value: t, child: Text(t)),
                    ],
                    onChanged: (v) => setState(() => _task = v ?? 'all'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final m = list[i];
                  return ListTile(
                    title: Text('${m['name']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                    subtitle: Text('${_taskOf(m)} · ${m['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(tooltip: context.tr('Run', '运行'), icon: const Icon(Icons.play_arrow), onPressed: () => _run(m)),
                    onTap: () => showJsonDialog(context, m, title: '${m['name']}'),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
