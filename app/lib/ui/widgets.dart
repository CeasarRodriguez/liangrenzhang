import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/budget.dart';
import '../core/categories.dart';
import '../core/dates.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../providers.dart';

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(describeError(error))));
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [action] with a busy flag and shows errors as a snackbar.
Future<bool> runGuarded(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } on Object catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.onTap});

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class MonthSwitcher extends ConsumerWidget {
  const MonthSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(selectedMonthProvider);
    final notifier = ref.read(selectedMonthProvider.notifier);
    final isCurrent = month == Month.of(DateTime.now());
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(onPressed: notifier.previous, icon: const Icon(Icons.chevron_left_rounded)),
        GestureDetector(
          onTap: () async {
            final picked = await showMonthPicker(context, month);
            if (picked != null) notifier.set(picked);
          },
          child: Text(
            month.label,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(onPressed: isCurrent ? null : notifier.next, icon: const Icon(Icons.chevron_right_rounded)),
      ],
    );
  }
}

Future<Month?> showMonthPicker(BuildContext context, Month initial, {Month? first, Month? last}) {
  return showDialog<Month>(
    context: context,
    builder: (context) {
      var year = initial.year;
      return StatefulBuilder(
        builder: (context, setState) {
          final scheme = Theme.of(context).colorScheme;
          return AlertDialog(
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(onPressed: () => setState(() => year--), icon: const Icon(Icons.chevron_left_rounded)),
                Text('$year年'),
                IconButton(onPressed: () => setState(() => year++), icon: const Icon(Icons.chevron_right_rounded)),
              ],
            ),
            content: SizedBox(
              width: 280,
              child: GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.6,
                children: [
                  for (var m = 1; m <= 12; m++)
                    Builder(
                      builder: (context) {
                        final value = Month(year, m);
                        final enabled =
                            (first == null || value.index >= first.index) &&
                            (last == null || value.index <= last.index);
                        final selected = value == initial;
                        return FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            minimumSize: Size.zero,
                            padding: EdgeInsets.zero,
                            backgroundColor: selected ? scheme.primary : null,
                            foregroundColor: selected ? scheme.onPrimary : null,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: enabled ? () => Navigator.pop(context, value) : null,
                          child: Text('$m月'),
                        );
                      },
                    ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({super.key, required this.type, required this.category, this.size = 40});

  final String type;
  final String category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = categoryOf(type, category);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.color.withValues(alpha: 0.15), shape: BoxShape.circle),
      child: Icon(c.icon, color: c.color, size: size * 0.52),
    );
  }
}

class EntryTile extends ConsumerWidget {
  const EntryTile({super.key, required this.entry, this.onTap, this.showDate = false});

  final Entry entry;
  final VoidCallback? onTap;
  final bool showDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(meAndPartnerProvider);
    final isMine = entry.owner == ref.watch(currentUserIdProvider);
    final note = isMine ? (ref.watch(notesProvider).value?[entry.id] ?? '') : '';
    final theme = Theme.of(context);
    final who = members.nameOf(entry.owner);

    final subtitle = [if (showDate) friendlyDate(entry.occurredOn), who, if (note.isNotEmpty) note].join(' · ');

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: CategoryAvatar(type: entry.type, category: entry.category),
      title: Text(entry.category),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.pending)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.cloud_upload_outlined, size: 16, color: theme.colorScheme.outline),
            ),
          Text(
            '${entry.isExpense ? '-' : '+'}${formatYuan(entry.amount)}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: entry.isExpense ? theme.colorScheme.onSurface : AppColors.income,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(icon, size: 48, color: color),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(color: color),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Small cloud icon describing the sync state.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    if (ref.watch(servicesProvider).offline != null) {
      const tip = '单机体验版：数据只保存在这台手机上，不会同步';
      return IconButton(
        tooltip: tip,
        icon: Icon(Icons.phone_android_rounded, color: scheme.outline),
        onPressed: () => showMessage(context, tip),
      );
    }
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(outboxCountProvider).value ?? 0;

    final (IconData icon, Color color, String tip) = switch (status) {
      _ when status?.syncing ?? false => (Icons.sync_rounded, scheme.primary, '正在同步'),
      _ when !(status?.online ?? false) => (Icons.cloud_off_rounded, scheme.outline, '离线中，记账会在联网后自动上传'),
      _ when pending > 0 => (Icons.cloud_upload_rounded, AppColors.warning, '有 $pending 条待上传'),
      _ => (Icons.cloud_done_rounded, AppColors.mint, '已同步'),
    };
    return IconButton(
      tooltip: tip,
      icon: Icon(icon, color: color),
      onPressed: () {
        showMessage(context, tip);
        ref.read(servicesProvider).sync?.syncNow();
      },
    );
  }
}
