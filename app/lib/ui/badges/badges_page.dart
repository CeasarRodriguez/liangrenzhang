import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/badges.dart';
import '../../core/budget.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../providers.dart';
import '../widgets.dart';

/// Artwork of the [number]-th badge earned: assets/badges/medal_N.png
/// (docs/奖章.md). Every badge gets its own design; one not drawn yet shows a
/// numbered medal instead.
class MedalImage extends StatelessWidget {
  const MedalImage({super.key, required this.number, this.size = 64});

  final int number;
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/badges/medal_$number.png',
    width: size,
    height: size,
    errorBuilder: (_, _, _) => SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.military_tech_rounded, size: size, color: AppColors.coral),
          Positioned(
            bottom: size * 0.18,
            child: Text(
              '$number',
              style: TextStyle(fontSize: size * 0.16, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A badge slot not earned yet.
class _LockedMedal extends StatelessWidget {
  const _LockedMedal();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
      child: Icon(Icons.lock_outline_rounded, size: 26, color: color),
    );
  }
}

/// Badge number of [month] in the order earned (1 = the first);
/// [badges] is newest first.
int badgeNumber(List<Month> badges, Month month) => badges.length - badges.indexOf(month);

const _cheers = [
  '上个月我们一起守住了预算，攒钱的路上又前进了一大步！',
  '说到做到的两个人最酷了，这枚奖章是你们一起挣来的 🏅',
  '每一笔省下的钱，都是写给未来的情书 ❤️',
  '又是自律的一个月！继续保持，目标就在前面等着我们。',
  '给彼此一个拥抱吧，上个月的你们真的很棒！',
];

/// Congratulates on [month]'s badge, the [number]-th earned.
Future<void> showBadgeDialog(BuildContext context, Goal goal, List<BudgetEntry> entries, Month month, int number) {
  final s = monthEndSnapshot(goal, entries, month);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: MedalImage(number: number, size: 120),
      title: Text('${month.month}月达成啦！收获第 $number 枚奖章'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_cheers[Random().nextInt(_cheers.length)], textAlign: TextAlign.center, style: const TextStyle(height: 1.5)),
          const SizedBox(height: 12),
          Text(
            '${month.month}月花了 ${yuan(s.monthSpent)}，限额 ${yuan(s.monthLimit)}，省下 ${yuan(s.monthLimit - s.monthSpent)}\n'
            '累计已攒 ${yuan(s.saved)}，计划进度 ${yuan(s.expectedSaved)}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Theme.of(dialogContext).colorScheme.outline, height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            Navigator.push(context, MaterialPageRoute(builder: (_) => const BadgesPage()));
          },
          child: const Text('看看奖章墙'),
        ),
        FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('收下奖章')),
      ],
    ),
  );
}

class BadgesPage extends ConsumerWidget {
  const BadgesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final badges = ref.watch(badgesProvider);
    final level = badgeLevel(badges);
    // oldest first, then a few locked slots for the badges still to come
    final earned = badges.reversed.toList();
    final slots = max(6, (earned.length ~/ 3 + 1) * 3);

    return Scaffold(
      appBar: AppBar(title: const Text('我们的奖章')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          SectionCard(
            child: Row(
              children: [
                Icon(Icons.workspace_premium_outlined, size: 48, color: theme.colorScheme.outline),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        level == null ? '等级：敬请期待' : 'Lv.${level.level} ${level.name}',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${level == null ? '等级系统下个版本开放 · ' : ''}已获得 ${badges.length} 枚奖章',
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '一个月的花销没超过限额，累计已攒也跟上了计划进度，下个月就能拿到一枚奖章。',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline, height: 1.5),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.8,
            children: [
              for (var i = 0; i < slots; i++)
                Card(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (i < earned.length) MedalImage(number: i + 1, size: 72) else const _LockedMedal(),
                      const SizedBox(height: 8),
                      Text('第 ${i + 1} 枚', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(
                        i < earned.length ? earned[i].label : '待解锁',
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
