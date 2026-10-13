import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/services.dart';
import '../../providers.dart';
import '../alerts/alert_messages_page.dart';
import '../alerts/alerts_history_page.dart';
import '../goal/goal_page.dart';
import '../widgets.dart';
import 'notification_setup_page.dart';
import 'server_dialog.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(servicesProvider);
    final members = ref.watch(meAndPartnerProvider);
    final household = ref.watch(householdProvider).value;
    final goal = ref.watch(activeGoalProvider);
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(outboxCountProvider).value ?? 0;
    final unread = (ref.watch(alertsProvider).value ?? const []).where((a) => !a.read).length;
    final theme = Theme.of(context);

    void push(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          SectionCard(
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: AppColors.coral.withValues(alpha: 0.15),
                  child: Text(
                    (members.me?.displayName.characters.firstOrNull ?? '?'),
                    style: const TextStyle(fontSize: 22, color: AppColors.coral, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        members.me?.displayName ?? '',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '@${members.me?.username ?? ''}',
                        style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_rounded),
                  tooltip: '修改昵称',
                  onPressed: () async {
                    final name = await _prompt(context, '修改昵称', members.me?.displayName ?? '', maxLength: 20);
                    if (name != null && name.isNotEmpty && context.mounted) {
                      await runGuarded(context, () => ref.read(repositoryProvider).updateProfile(name: name));
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.home_rounded),
                  title: Text(household?.name ?? '我们的家'),
                  subtitle: Text(members.partner == null ? '另一半还没加入' : '和 ${members.partner!.displayName} 一起记账'),
                  trailing: const Icon(Icons.edit_rounded, size: 20),
                  onTap: () async {
                    final name = await _prompt(context, '家的名字', household?.name ?? '', maxLength: 30);
                    if (name != null && name.isNotEmpty && context.mounted) {
                      await runGuarded(context, () => ref.read(repositoryProvider).renameHousehold(name));
                    }
                  },
                ),
                if (members.partner == null && household != null)
                  ListTile(
                    leading: const Icon(Icons.vpn_key_rounded),
                    title: Text('邀请码 ${household.inviteCode}'),
                    subtitle: const Text('让另一半注册后选择「加入」并输入这个邀请码'),
                    trailing: const Icon(Icons.copy_rounded, size: 20),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: household.inviteCode));
                      showMessage(context, '邀请码已复制');
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.flag_rounded),
                  title: const Text('攒钱目标'),
                  subtitle: Text(
                    goal == null
                        ? '还没设置'
                        : '${goal.startMonth.label} - ${goal.endMonth.label} 攒 ${yuan(goal.savingsTarget)}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => push(const GoalPage()),
                ),
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline_rounded),
                  title: const Text('提醒文案'),
                  subtitle: const Text('自定义超支时的友情提醒'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => push(const AlertMessagesPage()),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_none_rounded),
                  title: const Text('提醒记录'),
                  subtitle: Text(unread > 0 ? '$unread 条未读' : '查看收到过的提醒'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => push(const AlertsHistoryPage()),
                ),
                if (s.offline == null)
                  ListTile(
                    leading: const Icon(Icons.notifications_active_outlined),
                    title: const Text('通知设置'),
                    subtitle: Text(s.isAndroid ? '让 App 在后台也能收到提醒' : '允许通知，App 关闭时也能收到提醒'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => push(const NotificationSetupPage()),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (s.offline != null)
            const _OfflineCard()
          else
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: const Text('同步'),
                    subtitle: Text(
                      [
                        if (status?.online ?? false) '已连接' else '离线',
                        if (pending > 0) '$pending 条待上传',
                        if (status?.lastSync != null) '上次同步 ${_time(status!.lastSync!)}',
                        if (status?.lastError != null) status!.lastError!,
                      ].join(' · '),
                    ),
                    trailing: TextButton(onPressed: () => s.sync?.syncNow(), child: const Text('立即同步')),
                  ),
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('服务器地址'),
                    subtitle: Text(s.serverUrl),
                    onTap: () => showServerDialog(context, ref),
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout_rounded, color: AppColors.danger),
                    title: const Text('退出登录', style: TextStyle(color: AppColors.danger)),
                    onTap: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('退出登录？'),
                          content: Text(
                            pending > 0 ? '还有 $pending 条记账没上传，退出后会丢失。建议联网同步后再退出。' : '数据都保存在服务器上，重新登录后会自动恢复。',
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
                          ],
                        ),
                      );
                      if (ok == true) await s.logout();
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Offline trial build: explains the mode and lets the user start over.
class _OfflineCard extends ConsumerWidget {
  const _OfflineCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Column(
        children: [
          const ListTile(
            leading: Icon(Icons.phone_android_rounded),
            title: Text('单机体验版'),
            subtitle: Text('数据只保存在这台手机上。「TA（模拟）」代替另一半，记账时可以切换成替 TA 记。'),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('连接服务器'),
            subtitle: const Text('两人同步。体验数据留在这台手机上，不会上传'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('改用服务器？'),
                  content: const Text('接下来填写你们自己部署的服务器地址，再注册或登录。\n\n现在的体验数据会留在这台手机上，不会上传；以后在登录页选「单机体验」还能回来。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续')),
                  ],
                ),
              );
              if (ok == true) await ref.read(switchModeProvider)(AppMode.online);
            },
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt_rounded, color: AppColors.danger),
            title: const Text('清空体验数据', style: TextStyle(color: AppColors.danger)),
            subtitle: const Text('删除所有账目、目标、提醒，自定义文案恢复默认'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空体验数据？'),
                  content: const Text('这台手机上的体验数据会全部删除，不能恢复。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(servicesProvider).logout();
                if (context.mounted) showMessage(context, '已清空');
              }
            },
          ),
        ],
      ),
    );
  }
}

Future<String?> _prompt(BuildContext context, String title, String initial, {int? maxLength}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, maxLength: maxLength),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('保存')),
      ],
    ),
  );
  controller.dispose();
  return result;
}
