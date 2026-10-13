import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alert_copy.dart';
import '../../core/budget.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../widgets.dart';

/// Customizable friendly-reminder copy, one tab per alert level.
class AlertMessagesPage extends ConsumerWidget {
  const AlertMessagesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: allLevels.length,
      child: Builder(
        builder: (context) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('提醒文案'),
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final l in allLevels) Tab(text: alertLevelLabels[l])],
              ),
            ),
            body: TabBarView(children: [for (final l in allLevels) _LevelList(level: l)]),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () {
                final level = allLevels[DefaultTabController.of(context).index];
                showMessageEditor(context, level: level);
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('写一条'),
            ),
          );
        },
      ),
    );
  }
}

class _LevelList extends ConsumerWidget {
  const _LevelList({required this.level});

  final String level;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(alertMessagesProvider).value ?? const <AlertMessage>[];
    final messages = all.where((m) => m.level == level).toList()
      ..sort((a, b) => a.isDefault == b.isDefault ? a.created.compareTo(b.created) : (a.isDefault ? 1 : -1));
    final enabledCount = messages.where((m) => m.enabled).length;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Text(
          '「${alertTitles[level]}」时，会从下面打开的文案里随机挑一条发给你们俩。'
          '${enabledCount == 0 ? '\n现在全部关掉了，会使用一句简短的默认提醒。' : ''}',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.outline, height: 1.5),
        ),
        const SizedBox(height: 12),
        for (final m in messages) ...[
          SectionCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            onTap: m.isDefault ? null : () => showMessageEditor(context, level: level, message: m),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.text, style: TextStyle(height: 1.5, color: m.enabled ? null : theme.colorScheme.outline)),
                      const SizedBox(height: 6),
                      Text(
                        m.isDefault ? '默认文案' : '自定义 · 点击编辑',
                        style: TextStyle(
                          fontSize: 12,
                          color: m.isDefault ? theme.colorScheme.outline : AppColors.coral,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: m.enabled,
                  onChanged: (v) =>
                      runGuarded(context, () => ref.read(repositoryProvider).updateAlertMessage(m, enabled: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

Future<void> showMessageEditor(BuildContext context, {required String level, AlertMessage? message}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _MessageEditor(level: level, message: message),
  );
}

class _MessageEditor extends ConsumerStatefulWidget {
  const _MessageEditor({required this.level, this.message});

  final String level;
  final AlertMessage? message;

  @override
  ConsumerState<_MessageEditor> createState() => _MessageEditorState();
}

class _MessageEditorState extends ConsumerState<_MessageEditor> {
  late final TextEditingController _text = TextEditingController(text: widget.message?.text ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _insert(String placeholder) {
    final sel = _text.selection;
    final text = _text.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _text.value = TextEditingValue(
      text: text.replaceRange(start, end, placeholder),
      selection: TextSelection.collapsed(offset: start + placeholder.length),
    );
    setState(() {});
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      showMessage(context, '写点什么吧');
      return;
    }
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final ok = await runGuarded(
      context,
      () => widget.message == null
          ? repo.addAlertMessage(widget.level, text)
          : repo.updateAlertMessage(widget.message!, text: text),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    final ok = await runGuarded(context, () => ref.read(repositoryProvider).deleteAlertMessage(widget.message!));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final budget = ref.watch(currentBudgetProvider);
    final snap = budget.snapshot ?? previewSnapshot;
    final target = budget.goal?.savingsTarget ?? 2000000;
    final unknown = unknownPlaceholders(_text.text);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${alertLevelLabels[widget.level]}时的提醒',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              maxLength: 200,
              decoration: const InputDecoration(hintText: '比如：亲爱的，这个月已经花了 ¥{已花} 啦，剩下的日子我们省着点～'),
              onChanged: (_) => setState(() {}),
            ),
            Text('点一下插入自动替换的数字：', style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in alertPlaceholders.entries)
                  ActionChip(
                    label: Text(p.value, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _insert(p.key),
                  ),
              ],
            ),
            if (unknown.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${unknown.join('、')} 不是可用的占位符，会原样显示',
                style: const TextStyle(fontSize: 12, color: AppColors.warning),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '预览（${budget.snapshot == null ? '示例数字' : '按本月实际数字'}）',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 6),
                  Text(alertTitles[widget.level]!, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    _text.text.isEmpty ? '…' : renderAlert(_text.text, snap, target),
                    style: const TextStyle(height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
            if (widget.message != null)
              TextButton(
                onPressed: _busy ? null : _delete,
                child: const Text('删除这条', style: TextStyle(color: AppColors.danger)),
              ),
          ],
        ),
      ),
    );
  }
}
