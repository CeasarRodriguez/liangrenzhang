import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/budget.dart';
import '../../core/categories.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../records/records_page.dart' show OwnerFilter;
import '../widgets.dart';

class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  OwnerFilter _who = OwnerFilter.all;
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(selectedMonthProvider);
    final uid = ref.watch(currentUserIdProvider);
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final theme = Theme.of(context);

    final monthExpenses = entries.where((e) {
      if (e.month != month || !e.isExpense) return false;
      return switch (_who) {
        OwnerFilter.all => true,
        OwnerFilter.me => e.owner == uid,
        OwnerFilter.partner => e.owner != uid,
      };
    });
    final byCategory = <String, int>{};
    for (final e in monthExpenses) {
      byCategory[e.category] = (byCategory[e.category] ?? 0) + e.amount;
    }
    final sorted = byCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = sorted.fold(0, (a, e) => a + e.value);

    return Scaffold(
      appBar: AppBar(title: const Text('统计')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          const MonthSwitcher(),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('支出分类', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                SegmentedButton<OwnerFilter>(
                  segments: const [
                    ButtonSegment(value: OwnerFilter.all, label: Text('全家')),
                    ButtonSegment(value: OwnerFilter.me, label: Text('我')),
                    ButtonSegment(value: OwnerFilter.partner, label: Text('TA')),
                  ],
                  selected: {_who},
                  onSelectionChanged: (v) => setState(() {
                    _who = v.first;
                    _touched = null;
                  }),
                ),
                const SizedBox(height: 16),
                if (total == 0)
                  const EmptyHint(icon: Icons.pie_chart_outline_rounded, text: '这个月还没有支出')
                else ...[
                  SizedBox(
                    height: 200,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        PieChart(
                          PieChartData(
                            sectionsSpace: 2,
                            centerSpaceRadius: 56,
                            pieTouchData: PieTouchData(
                              touchCallback: (event, response) {
                                setState(() => _touched = response?.touchedSection?.touchedSectionIndex);
                              },
                            ),
                            sections: [
                              for (var i = 0; i < sorted.length; i++)
                                PieChartSectionData(
                                  value: sorted[i].value.toDouble(),
                                  color: categoryOf(typeExpense, sorted[i].key).color,
                                  radius: _touched == i ? 40 : 32,
                                  showTitle: false,
                                ),
                            ],
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('总支出', style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
                            Text(yuan(total), style: const TextStyle(fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final e in sorted)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          CategoryAvatar(type: typeExpense, category: e.key, size: 32),
                          const SizedBox(width: 12),
                          Text(e.key),
                          const SizedBox(width: 8),
                          Text(
                            '${(e.value * 100 / total).toStringAsFixed(1)}%',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                          ),
                          const Spacer(),
                          Text(yuan(e.value), style: const TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _TrendCard(entries: entries, end: month),
        ],
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.entries, required this.end});

  final List<Entry> entries;
  final Month end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final months = [for (var i = 11; i >= 0; i--) end.add(-i)];
    final expense = {for (final m in months) m: 0};
    final income = {for (final m in months) m: 0};
    for (final e in entries) {
      final m = e.month;
      if (!expense.containsKey(m)) continue;
      if (e.isExpense) {
        expense[m] = expense[m]! + e.amount;
      } else {
        income[m] = income[m]! + e.amount;
      }
    }
    final maxCents = [...expense.values, ...income.values].fold(0, (a, b) => a > b ? a : b);
    final maxY = maxCents == 0 ? 100.0 : maxCents / 100 * 1.15;

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('近 12 个月收支', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              _Legend(color: AppColors.coral, label: '支出'),
              const SizedBox(width: 12),
              _Legend(color: AppColors.income, label: '收入'),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: BarChart(
              BarChartData(
                maxY: maxY,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
                      '${months[group.x].month}月${rodIndex == 0 ? '支出' : '收入'}\n${yuan((rod.toY * 100).round())}',
                      const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(
                          '${months[value.toInt()].month}',
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
                        ),
                      ),
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < months.length; i++)
                    BarChartGroupData(
                      x: i,
                      barsSpace: 2,
                      barRods: [
                        BarChartRodData(
                          toY: expense[months[i]]! / 100,
                          color: AppColors.coral,
                          width: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        BarChartRodData(
                          toY: income[months[i]]! / 100,
                          color: AppColors.income,
                          width: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
      ),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}
