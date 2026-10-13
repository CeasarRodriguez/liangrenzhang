import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/budget.dart';
import '../../core/categories.dart';
import '../../core/money.dart';
import '../../core/purchase.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../entry/entry_editor.dart';
import '../goal/goal_page.dart';
import '../widgets.dart';

/// Big-purchase calculator: what buying it does to the budget and the
/// savings target, and pre-deducting it once decided.
class PurchasePage extends ConsumerStatefulWidget {
  const PurchasePage({super.key});

  @override
  ConsumerState<PurchasePage> createState() => _PurchasePageState();
}

class _PurchasePageState extends ConsumerState<PurchasePage> {
  final _price = TextEditingController();
  final _title = TextEditingController();
  String _category = '购物';
  bool _busy = false;

  @override
  void dispose() {
    _price.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _reserve(int price) async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showMessage(context, '填一下买什么，方便两人知道这笔预扣是什么');
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(repositoryProvider).reserve(amount: price, category: _category, title: title),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _price.clear();
      _title.clear();
      showMessage(context, '已预扣 ${yuan(price)}。买了之后点它选「已经买了」，不用再记一笔');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goal = ref.watch(activeGoalProvider);
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final reservations = ref.watch(reservationsProvider);
    final price = parseYuan(_price.text);

    PurchaseImpact? impact;
    if (goal != null && price != null && price > 0) {
      final t = today();
      impact = simulatePurchase(goal.goal, entries.map((e) => e.toBudget()), Month.of(t), t, price);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('大件测算')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          if (goal == null)
            SectionCard(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GoalPage())),
              child: const Row(
                children: [
                  Icon(Icons.flag_rounded, color: AppColors.coral),
                  SizedBox(width: 12),
                  Expanded(child: Text('测算要根据攒钱目标来算，先设置一个覆盖本月的攒钱目标吧')),
                  Icon(Icons.chevron_right_rounded),
                ],
              ),
            )
          else ...[
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                    decoration: InputDecoration(
                      prefixText: '¥ ',
                      hintText: '想买的东西多少钱',
                      hintStyle: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.outline),
                      prefixStyle: theme.textTheme.headlineSmall,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _title,
                    maxLength: 30,
                    decoration: const InputDecoration(
                      labelText: '买什么（比如新手机、电脑）',
                      prefixIcon: Icon(Icons.shopping_bag_outlined, size: 20),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in expenseCategories)
                        ChoiceChip(
                          avatar: Icon(c.icon, size: 18, color: _category == c.name ? null : c.color),
                          label: Text(c.name),
                          selected: _category == c.name,
                          onSelected: (_) => setState(() => _category = c.name),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (impact != null) ...[
              const SizedBox(height: 12),
              _ImpactCard(impact: impact, target: goal.savingsTarget),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : () => _reserve(impact!.price),
                icon: const Icon(Icons.lock_clock_rounded),
                label: Text('确认要买，先预扣 ${yuan(impact.price)}'),
              ),
              const SizedBox(height: 6),
              Text(
                '预扣会马上算进本月支出，两人都能看到。不买了可以取消；买了之后点它选「已经买了」，不用再记一笔。',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.outline, height: 1.5),
              ),
            ],
          ],
          if (reservations.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('预扣中', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (final e in reservations)
                    EntryTile(entry: e, showDate: true, onTap: () => openEntry(context, ref, e)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImpactCard extends StatelessWidget {
  const _ImpactCard({required this.impact, required this.target});

  final PurchaseImpact impact;
  final int target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = impact;
    final s = i.snapshot;

    String money(int cents) => cents < 0 ? '超出 ${yuan(-cents)}' : yuan(cents);

    Widget row(String label, String before, String after, {bool bad = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: TextStyle(color: theme.colorScheme.outline))),
          Text(before),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward_rounded, size: 16)),
          Text(
            after,
            style: TextStyle(fontWeight: FontWeight.w600, color: bad ? AppColors.danger : null),
          ),
        ],
      ),
    );

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('买了会怎样', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          row('本月还能花', money(s.monthRemaining), money(i.remainingAfter), bad: i.remainingAfter < 0),
          if (i.laterMonths > 0)
            row(
              '之后 ${i.laterMonths} 个月每月限额',
              yuan(i.laterLimitBefore),
              yuan(i.laterLimitAfter),
              bad: i.laterLimitAfter < i.laterLimitBefore,
            ),
          row(
            '计划期末能攒到',
            yuan(i.projectedSavings + i.goalShrink),
            yuan(i.projectedSavings),
            bad: i.goalShrink > 0,
          ),
          row('目前已攒', yuan(s.saved), yuan(i.savedAfter), bad: i.savedAfter < s.expectedSaved),
          Text(
            '按计划到本月底应攒到 ${yuan(s.expectedSaved)}',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: (i.fit == PurchaseFit.overGoal ? AppColors.danger : AppColors.mint).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('建议', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final line in purchaseAdvice(i, target)) ...[
                  Text(line, style: const TextStyle(height: 1.5)),
                  const SizedBox(height: 4),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How to fit the purchase in, spread over time.
List<String> purchaseAdvice(PurchaseImpact i, int target) {
  final cut = i.laterLimitBefore - i.laterLimitAfter;
  final spread = i.fromThisMonth > 0
      ? '本月剩余额度出 ${yuan(i.fromThisMonth)}，剩下 ${yuan(i.spillover)}'
      : '本月额度已经用完，${yuan(i.price)} 全部';
  final lines = switch (i.fit) {
    PurchaseFit.thisMonth => ['本月额度够，直接从本月剩余额度出就行，之后的月份和攒钱目标都不受影响。'],
    PurchaseFit.laterMonths => [
      '$spread摊到之后 ${i.laterMonths} 个月，每月少花约 ${yuan(cut)}（限额从 ${yuan(i.laterLimitBefore)} 降到 ${yuan(i.laterLimitAfter)}），攒钱目标不受影响。',
    ],
    PurchaseFit.overGoal => [
      '计划期剩下能花的钱不够了，买了攒钱目标会缩水 ${yuan(i.goalShrink)}，预计攒到 ${yuan(i.projectedSavings)}（目标 ${yuan(target)}）。',
      if (i.laterMonths > 0 && i.spillover > i.goalShrink)
        '而且之后 ${i.laterMonths} 个月的额度要全部搭进去，每月限额会降到 ${yuan(i.laterLimitAfter)}。',
      '想保住目标，需要再多 ${yuan(i.goalShrink)} 的收入，或者等下个计划期再买。',
    ],
  };
  if (i.tight) {
    lines.add('提醒：你们最近几个月平均每月花 ${yuan(i.recentAverageSpend)}，之后每月只有 ${yuan(i.laterLimitAfter)}，会比较紧，可以考虑晚一点再买。');
  }
  return lines;
}
