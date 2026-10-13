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

Future<void> showEntryEditor(BuildContext context, {Entry? entry, String? initialType, DateTime? initialDate}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => EntryEditor(entry: entry, initialType: initialType, initialDate: initialDate),
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
  const EntryEditor({super.key, this.entry, this.initialType, this.initialDate});

  final Entry? entry;

  /// For a new entry: preselected type and date.
  final String? initialType;
  final DateTime? initialDate;

  @override
  ConsumerState<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends ConsumerState<EntryEditor> {
  late String _type;
  late String _category;
  late DateTime _date;

  /// The category was chosen rather than left at the default.
  bool _categoryPicked = false;

  /// Offline trial only: record as the simulated partner.
  bool _asPartner = false;
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _title = TextEditingController();

  bool get _editing => widget.entry != null;
  bool get _reserved => widget.entry?.reserved ?? false;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _type = e?.type ?? widget.initialType ?? typeExpense;
    _category = e?.category ?? categoriesFor(_type).first.name;
    _date = e == null ? (widget.initialDate ?? today()) : parseIsoDate(e.occurredOn);
    if (e != null) {
      _amount.text = centsToInput(e.amount);
      _note.text = ref.read(notesProvider).value?[e.id] ?? '';
      _title.text = e.title;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _title.dispose();
    super.dispose();
  }

  void _setType(String type) {
    setState(() {
      _type = type;
      if (!categoriesFor(type).any((c) => c.name == _category)) {
        _category = categoriesFor(type).first.name;
        _categoryPicked = false;
      }
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

  int? _cents() {
    final cents = parseYuan(_amount.text);
    if (cents == null || cents <= 0) {
      showMessage(context, '请输入正确的金额（最多两位小数）');
      return null;
    }
    return cents;
  }

  Future<void> _save() async {
    final cents = _cents();
    if (cents == null) return;
    final repo = ref.read(repositoryProvider);

    // a new expense with the amount of a reservation is most likely the purchase itself
    if (!_editing && _type == typeExpense) {
      final owner = _asPartner ? offlinePartnerId : ref.read(currentUserIdProvider);
      final matches = ref
          .read(reservationsProvider)
          .where((r) => r.owner == owner && r.amount == cents)
          .toList();
      if (matches.isNotEmpty) {
        final choice = await _askDuplicate(matches);
        if (choice == null || !mounted) return;
        if (choice.isNotEmpty) {
          final reservation = matches.firstWhere((r) => r.id == choice);
          final note = _note.text.trim();
          await repo.confirmReservation(
            reservation,
            occurredOn: isoDate(_date),
            amount: cents,
            // keep the reservation's category unless one was chosen here
            category: _categoryPicked ? _category : null,
            note: note.isEmpty ? null : note,
          );
          if (mounted) {
            showMessage(context, '已把预扣「${reservation.title}」记为已购买，没有重复记账');
            Navigator.pop(context);
          }
          return;
        }
      }
    }

    await repo.saveEntry(
      id: widget.entry?.id,
      owner: _asPartner ? offlinePartnerId : null,
      type: _type,
      amount: cents,
      category: _category,
      occurredOn: isoDate(_date),
      note: _note.text.trim(),
      title: _reserved ? _title.text.trim() : null,
    );
    if (mounted) Navigator.pop(context);
  }

  /// The id of the reservation this entry is, '' for "a different one", or
  /// null when dismissed.
  Future<String?> _askDuplicate(List<Entry> matches) => showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('会不会重复记账？'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            matches.length == 1
                ? '你有一笔同样金额的预扣「${matches.single.title}」，这笔是不是就是它？'
                : '你有几笔同样金额的预扣，这笔是其中之一吗？',
            style: const TextStyle(height: 1.5),
          ),
        ),
        for (final r in matches)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, r.id),
            child: Text(
              '是「${r.title}」，记为已购买（${friendlyDate(r.occurredOn)}预扣）',
              style: const TextStyle(color: AppColors.coral, fontWeight: FontWeight.w600),
            ),
          ),
        SimpleDialogOption(onPressed: () => Navigator.pop(context, ''), child: const Text('不是，另记一笔')),
      ],
    ),
  );

  /// Reservation: the purchase happened.
  Future<void> _bought() async {
    final cents = _cents();
    if (cents == null) return;
    final date = await showDatePicker(
      context: context,
      helpText: '哪天买的？',
      initialDate: today(),
      firstDate: DateTime(2020),
      lastDate: today().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    await ref
        .read(repositoryProvider)
        .confirmReservation(
          widget.entry!,
          occurredOn: isoDate(date),
          amount: cents,
          category: _category,
          title: _title.text.trim(),
          note: _note.text.trim(),
        );
    if (mounted) {
      showMessage(context, '已记为已购买');
      Navigator.pop(context);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_reserved ? '不买了，取消这笔预扣？' : '删除这笔账？'),
        content: _reserved ? const Text('预扣的钱会退回本月额度。') : null,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_reserved ? '取消预扣' : '删除', style: const TextStyle(color: AppColors.danger)),
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
            if (_reserved) ...[
              const ReservedChip(large: true),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                maxLength: 30,
                decoration: const InputDecoration(
                  labelText: '买什么',
                  prefixIcon: Icon(Icons.shopping_bag_outlined, size: 20),
                  helperText: '物品名两人都能看到',
                ),
              ),
            ] else
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
                    onSelected: (_) => setState(() {
                      _category = c.name;
                      _categoryPicked = true;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_rounded),
              title: Text(_reserved ? '${friendlyDate(isoDate(_date))} 预扣' : friendlyDate(isoDate(_date))),
              trailing: _reserved ? null : const Icon(Icons.chevron_right_rounded),
              onTap: _reserved ? null : _pickDate,
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
            if (_reserved) ...[
              FilledButton.icon(
                onPressed: _bought,
                icon: const Icon(Icons.check_rounded),
                label: const Text('已经买了'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _save, child: const Text('保存修改（继续预扣）')),
            ] else
              FilledButton(onPressed: _save, child: Text(_editing ? '保存修改' : '记下来')),
            if (_editing) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _delete,
                child: Text(_reserved ? '不买了，取消预扣' : '删除这笔', style: const TextStyle(color: AppColors.danger)),
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
          if (entry.title.isNotEmpty) ...[
            Text(entry.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
          ],
          Text('${entry.category} · ${friendlyDate(entry.occurredOn)} · $who ${entry.reserved ? '预扣的，还没买' : '记的'}'),
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
