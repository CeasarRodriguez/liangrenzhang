import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/budget.dart';
import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../entry/entry_editor.dart';
import '../widgets.dart';

enum OwnerFilter { all, me, partner }

class RecordsPage extends ConsumerStatefulWidget {
  const RecordsPage({super.key});

  @override
  ConsumerState<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends ConsumerState<RecordsPage> {
  OwnerFilter _filter = OwnerFilter.all;

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(selectedMonthProvider);
    final uid = ref.watch(currentUserIdProvider);
    final all = ref.watch(entriesProvider).value ?? const <Entry>[];
    final entries = all.where((e) {
      if (e.month != month) return false;
      return switch (_filter) {
        OwnerFilter.all => true,
        OwnerFilter.me => e.owner == uid,
        OwnerFilter.partner => e.owner != uid,
      };
    }).toList();

    final expense = entries.where((e) => e.isExpense).fold(0, (a, e) => a + e.amount);
    final income = entries.where((e) => !e.isExpense).fold(0, (a, e) => a + e.amount);

    final byDay = <String, List<Entry>>{};
    for (final e in entries) {
      byDay.putIfAbsent(e.occurredOn, () => []).add(e);
    }
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('账目'), actions: const [SyncIndicator()]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        children: [
          const MonthSwitcher(),
          SectionCard(
            child: Row(
              children: [
                _Total(label: '支出', value: expense),
                _Total(label: '收入', value: income, color: AppColors.income),
                _Total(label: '结余', value: income - expense),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<OwnerFilter>(
            segments: const [
              ButtonSegment(value: OwnerFilter.all, label: Text('全部')),
              ButtonSegment(value: OwnerFilter.me, label: Text('我的')),
              ButtonSegment(value: OwnerFilter.partner, label: Text('TA 的')),
            ],
            selected: {_filter},
            onSelectionChanged: (v) => setState(() => _filter = v.first),
          ),
          const SizedBox(height: 12),
          if (entries.isEmpty) const EmptyHint(icon: Icons.receipt_long_outlined, text: '这个月还没有账目'),
          for (final day in byDay.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
              child: Row(
                children: [
                  Text(friendlyDate(day.key), style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(_daySummary(day.value), style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
                ],
              ),
            ),
            Card(
              child: Column(
                children: [for (final e in day.value) EntryTile(entry: e, onTap: () => openEntry(context, ref, e))],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _daySummary(List<Entry> list) {
    final out = list.where((e) => e.type == typeExpense).fold(0, (a, e) => a + e.amount);
    final inc = list.where((e) => e.type == typeIncome).fold(0, (a, e) => a + e.amount);
    return [if (out > 0) '支出 ${formatYuan(out)}', if (inc > 0) '收入 ${formatYuan(inc)}'].join('  ');
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value, this.color});

  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: theme.colorScheme.outline)),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(
              formatYuan(value),
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
