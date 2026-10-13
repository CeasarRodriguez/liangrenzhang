import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alert_copy.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../widgets.dart';

class AlertsHistoryPage extends ConsumerWidget {
  const AlertsHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider).value ?? const <AlertItem>[];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('提醒记录')),
      body: alerts.isEmpty
          ? const EmptyHint(icon: Icons.notifications_none_rounded, text: '还没有收到过提醒，继续保持 👍')
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: alerts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final a = alerts[i];
                final created = DateTime.tryParse(a.created)?.toLocal();
                return SectionCard(
                  onTap: a.read ? null : () => ref.read(repositoryProvider).markAlertRead(a),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (!a.read)
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: const BoxDecoration(color: AppColors.coral, shape: BoxShape.circle),
                            ),
                          Expanded(
                            child: Text(
                              a.title.isEmpty ? (alertTitles[a.kind] ?? '') : a.title,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (created != null)
                            Text(
                              '${created.month}月${created.day}日',
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                            ),
                        ],
                      ),
                      if (a.body.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(a.body, style: const TextStyle(height: 1.5)),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }
}
