import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/budget.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../entry/entry_editor.dart';
import '../goal/goal_page.dart';
import '../widgets.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(meAndPartnerProvider);
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final unread = (ref.watch(alertsProvider).value ?? const <AlertItem>[]).where((a) => !a.read).toList();
    final budget = ref.watch(currentBudgetProvider);

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Text('嗨，${members.me?.displayName ?? ''}'),
        actions: const [SyncIndicator()],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.read(servicesProvider).sync?.syncNow(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            if (unread.isNotEmpty) ...[
              _AlertBanner(alert: unread.first, more: unread.length - 1),
              const SizedBox(height: 12),
            ],
            if (budget.snapshot == null)
              const _NoGoalCard()
            else ...[
              _MonthCard(snapshot: budget.snapshot!),
              const SizedBox(height: 12),
              _GoalCard(goal: budget.goal!, snapshot: budget.snapshot!),
            ],
            const SizedBox(height: 12),
            _CoupleCard(entries: entries, members: members),
            const SizedBox(height: 20),
            Text('最近记账', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const EmptyHint(icon: Icons.edit_note_rounded, text: '还没有记账，点右下角「记一笔」开始吧')
            else
              Card(
                child: Column(
                  children: [
                    for (final e in entries.take(8))
                      EntryTile(entry: e, showDate: true, onTap: () => openEntry(context, ref, e)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AlertBanner extends ConsumerWidget {
  const _AlertBanner({required this.alert, required this.more});

  final AlertItem alert;
  final int more;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.favorite_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(alert.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(alert.body, style: const TextStyle(height: 1.5)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => ref.read(repositoryProvider).markAlertRead(alert),
                child: Text(more > 0 ? '知道啦（还有 $more 条）' : '知道啦'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoGoalCard extends StatelessWidget {
  const _NoGoalCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GoalPage())),
      child: Row(
        children: [
          const Icon(Icons.flag_rounded, size: 40, color: AppColors.coral),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设置攒钱目标', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  '定好计划攒多少，App 会算出每个月能花多少，花超了会友情提醒',
                  style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.snapshot});

  final Snapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final theme = Theme.of(context);
    final color = usageColor(s.usedPercent);
    final over = s.monthRemaining < 0;
    final fraction = s.monthLimit > 0 ? s.monthSpent / s.monthLimit : (s.monthSpent > 0 ? 1.0 : 0.0);

    return SectionCard(
      child: Row(
        children: [
          SizedBox(
            width: 112,
            height: 112,
            child: CustomPaint(
              painter: _RingPainter(fraction: fraction, color: color, track: theme.colorScheme.surfaceContainerHighest),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.usedPercent >= usedPercentOverflow ? '超支' : '${s.usedPercent}%',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: color),
                    ),
                    Text('已用', style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本月还能花', style: TextStyle(color: theme.colorScheme.outline, fontSize: 13)),
                Text(
                  over ? '超出 ${yuan(-s.monthRemaining)}' : yuan(s.monthRemaining),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: over ? AppColors.danger : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text('已花 ${yuan(s.monthSpent)} / 限额 ${yuan(s.monthLimit)}', style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 2),
                Text(
                  s.dailyAllowance > 0
                      ? '剩 ${s.daysLeft} 天，每天约 ${yuan(s.dailyAllowance)}'
                      : '剩 ${s.daysLeft} 天，这个月先省着点',
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.fraction, required this.color, required this.track});

  final double fraction;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(arcRect, 0, math.pi * 2, false, base);
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(arcRect, -math.pi / 2, math.pi * 2 * fraction.clamp(0.0, 1.0), false, fg);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color || old.track != track;
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.snapshot});

  final GoalRecord goal;
  final Snapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final theme = Theme.of(context);
    final target = goal.savingsTarget;
    final progress = target > 0 ? (s.saved / target).clamp(0.0, 1.0) : 0.0;
    final ahead = s.saved - s.expectedSaved;

    return SectionCard(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GoalPage())),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_rounded, color: AppColors.coral, size: 20),
              const SizedBox(width: 6),
              Text('攒钱目标 ${yuan(target)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                '${goal.startMonth.label} - ${goal.endMonth.month}月',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 12,
              color: AppColors.coral,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('已攒 ${yuan(s.saved)}'),
              Text('还差 ${yuan(s.toTarget)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            ahead >= 0
                ? '按计划到本月底应攒到 ${yuan(s.expectedSaved)}，已经提前做到啦 👏'
                : '按计划到本月底应攒到 ${yuan(s.expectedSaved)}，加油，还差 ${yuan(-ahead)}',
            style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

class _CoupleCard extends StatelessWidget {
  const _CoupleCard({required this.entries, required this.members});

  final List<Entry> entries;
  final Members members;

  @override
  Widget build(BuildContext context) {
    final month = Month.of(DateTime.now());
    int sum(String? owner, String type) => entries
        .where((e) => e.month == month && e.type == type && (owner == null || e.owner == owner))
        .fold(0, (a, e) => a + e.amount);

    final me = members.me;
    final partner = members.partner;
    final theme = Theme.of(context);

    Widget column(String label, int spent, int income) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: theme.colorScheme.outline, fontSize: 13)),
          const SizedBox(height: 4),
          Text(yuan(spent), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          if (income > 0) Text('收入 ${yuan(income)}', style: const TextStyle(fontSize: 12, color: AppColors.income)),
        ],
      ),
    );

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本月花销', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            children: [
              column('我', sum(me?.id, typeExpense), sum(me?.id, typeIncome)),
              Container(width: 1, height: 44, color: theme.dividerColor),
              const SizedBox(width: 16),
              partner == null
                  ? Expanded(
                      child: Text(
                        '另一半还没加入\n去「我的」里把邀请码发给 TA',
                        style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
                      ),
                    )
                  : column(partner.displayName, sum(partner.id, typeExpense), sum(partner.id, typeIncome)),
            ],
          ),
        ],
      ),
    );
  }
}
