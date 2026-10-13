import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/budget.dart';
import '../../core/categories.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/offline.dart';
import '../../providers.dart';
import '../widgets.dart';

Future<void> showEntryEditor(BuildContext context, {Entry? entry}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => EntryEditor(entry: entry),
  );
}

/// Own entries open the editor; the partner's open a read-only sheet.
void openEntry(BuildContext context, WidgetRef ref, Entry e) {
  if (e.owner == ref.read(currentUserIdProvider)) {
    showEntryEditor(context, entry: e);
  } else {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _PartnerEntrySheet(entry: e),
    );
  }
}

class EntryEditor extends ConsumerStatefulWidget {
  const EntryEditor({super.key, this.entry});

  final Entry? entry;

  @override
  ConsumerState<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends ConsumerState<EntryEditor> {
  late String _type;
  late String _category;
  late DateTime _date;

  /// Offline trial only: record as the simulated partner.
  bool _asPartner = false;
  final _amount = TextEditingController();
  final _note = TextEditingController();

  bool get _editing => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _type = e?.type ?? typeExpense;
    _category = e?.category ?? expenseCategories.first.name;
    _date = e == null ? today() : parseIsoDate(e.occurredOn);
    if (e != null) {
      _amount.text = centsToInput(e.amount);
      _note.text = ref.read(notesProvider).value?[e.id] ?? '';
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _setType(String type) {
    setState(() {
      _type = type;
      if (!categoriesFor(type).any((c) => c.name == _category)) _category = categoriesFor(type).first.name;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: today().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final cents = parseYuan(_amount.text);
    if (cents == null || cents <= 0) {
      showMessage(context, '请输入正确的金额（最多两位小数）');
      return;
    }
    await ref
        .read(repositoryProvider)
        .saveEntry(
          id: widget.entry?.id,
          owner: _asPartner ? offlinePartnerId : null,
          type: _type,
          amount: cents,
          category: _category,
          occurredOn: isoDate(_date),
          note: _note.text.trim(),
        );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这笔账？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repositoryProvider).deleteEntry(widget.entry!);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExpense = _type == typeExpense;
    final offline = ref.watch(servicesProvider).offline != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: typeExpense, label: Text('支出'), icon: Icon(Icons.remove_circle_outline_rounded)),
                ButtonSegment(value: typeIncome, label: Text('收入'), icon: Icon(Icons.add_circle_outline_rounded)),
              ],
              selected: {_type},
              onSelectionChanged: (v) => _setType(v.first),
            ),
            if (offline && !_editing) ...[
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('我记的')),
                  ButtonSegment(value: true, label: Text('替 TA 记（模拟）')),
                ],
                selected: {_asPartner},
                onSelectionChanged: (v) => setState(() => _asPartner = v.first),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              autofocus: !_editing,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: isExpense ? null : AppColors.income,
              ),
              decoration: InputDecoration(
                prefixText: '¥ ',
                hintText: '0.00',
                prefixStyle: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in categoriesFor(_type))
                  ChoiceChip(
                    avatar: Icon(c.icon, size: 18, color: _category == c.name ? null : c.color),
                    label: Text(c.name),
                    selected: _category == c.name,
                    onSelected: (_) => setState(() => _category = c.name),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_rounded),
              title: Text(friendlyDate(isoDate(_date))),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _pickDate,
            ),
            if (!_asPartner)
              TextField(
                controller: _note,
                maxLength: 200,
                decoration: const InputDecoration(
                  hintText: '备注（选填）',
                  prefixIcon: Icon(Icons.lock_outline_rounded, size: 20),
                  helperText: '备注只有自己能看到，另一半只看到金额和分类',
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _save, child: Text(_editing ? '保存修改' : '记下来')),
            if (_editing) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _delete,
                child: const Text('删除这笔', style: TextStyle(color: AppColors.danger)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PartnerEntrySheet extends ConsumerWidget {
  const _PartnerEntrySheet({required this.entry});

  final Entry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final who = ref.watch(meAndPartnerProvider).nameOf(entry.owner);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CategoryAvatar(type: entry.type, category: entry.category, size: 56),
          const SizedBox(height: 12),
          Text(
            '${entry.isExpense ? '-' : '+'}${yuan(entry.amount)}',
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text('${entry.category} · ${friendlyDate(entry.occurredOn)} · $who 记的'),
          const SizedBox(height: 16),
          Text('这是 TA 的账目，只能查看。', style: TextStyle(color: theme.colorScheme.outline, fontSize: 13)),
          if (ref.watch(servicesProvider).offline != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await ref.read(repositoryProvider).deleteEntry(entry);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('删除这笔（体验版）', style: TextStyle(color: AppColors.danger)),
            ),
          ],
        ],
      ),
    );
  }
}
