import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/services.dart';
import '../../providers.dart';
import '../alerts/alert_messages_page.dart';
import '../alerts/alerts_history_page.dart';
import '../auth/relay_pair_page.dart';
import '../badges/badges_page.dart';
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
    final pending = ref.watch(outboxCountProvider).value ?? 0;
    final unread = (ref.watch(alertsProvider).value ?? const []).where((a) => !a.read).length;
    final badges = ref.watch(badgesProvider).length;
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
                      if (members.me?.username.isNotEmpty ?? false)
                        Text(
                          '@${members.me!.username}',
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
                if (members.partner == null && s.pairingCode != null)
                  ListTile(
                    leading: const Icon(Icons.key_rounded),
                    title: const Text('配对码'),
                    subtitle: const Text('让另一半选「两人同步」→「输入配对码」'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showPairingCodeDialog(context, s.pairingCode!),
                  ),
                if (members.partner == null && (household?.inviteCode.isNotEmpty ?? false))
                  ListTile(
                    leading: const Icon(Icons.vpn_key_rounded),
                    title: Text('邀请码 ${household!.inviteCode}'),
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
                  leading: const Icon(Icons.military_tech_outlined),
                  title: const Text('我们的奖章'),
                  subtitle: Text(badges == 0 ? '守住一个月的预算就能拿到' : '已获得 $badges 枚'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => push(const BadgesPage()),
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
                if (s.mode == AppMode.online)
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
          if (s.mode == AppMode.offline)
            const _OfflineCard()
          else if (s.mode == AppMode.relay)
            const _RelayCard()
          else
            Card(
              child: Column(
                children: [
                  const _SyncTile(),
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
}

class _SyncTile extends ConsumerWidget {
  const _SyncTile();

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(servicesProvider);
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(outboxCountProvider).value ?? 0;
    return ListTile(
      leading: const Icon(Icons.sync_rounded),
      title: const Text('同步'),
      subtitle: Text(
        [
          if (status?.online ?? false) '已连接' else '离线',
          if (pending > 0) '$pending 条待${s.mode == AppMode.relay ? '发送' : '上传'}',
          if (status?.lastSync != null) '上次同步 ${_time(status!.lastSync!)}',
          if (status?.lastError != null) status!.lastError!,
        ].join(' · '),
      ),
      trailing: TextButton(onPressed: () => s.sync?.syncNow(), child: const Text('立即同步')),
    );
  }
}

/// Relay mode: sync state, the pairing code, and leaving the pairing.
class _RelayCard extends ConsumerWidget {
  const _RelayCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(servicesProvider);
    final pending = ref.watch(outboxCountProvider).value ?? 0;
    return Card(
      child: Column(
        children: [
          const _SyncTile(),
          const ListTile(
            leading: Icon(Icons.lock_outline_rounded),
            title: Text('两人同步（端到端加密）'),
            subtitle: Text('账目只保存在你们两台手机上。作者的服务器只转交加密后的数据，送达就删除，看不到内容。'),
          ),
          if (s.pairingCode != null)
            ListTile(
              leading: const Icon(Icons.key_rounded),
              title: const Text('配对码'),
              subtitle: const Text('另一半换手机时，用它找回账目'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showPairingCodeDialog(context, s.pairingCode!),
            ),
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded),
            title: const Text('换一种使用方式'),
            subtitle: const Text('单机体验或自己的服务器。这台手机上的账会保留'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('换一种使用方式？'),
                  content: const Text('两人同步的账会留在这台手机上，不会删除；以后再选「两人同步」就能回来。'),
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
            leading: const Icon(Icons.link_off_rounded, color: AppColors.danger),
            title: const Text('解除配对', style: TextStyle(color: AppColors.danger)),
            subtitle: const Text('删除这台手机上的账目'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('解除配对？'),
                  content: Text(
                    '${pending > 0 ? '还有 $pending 条记账没发给另一半，解除后会丢失。\n\n' : ''}'
                    '这台手机上的账目和备注会全部删除。另一半的手机上还留着一份（不含你的备注）：'
                    '以后让 TA 在「我的」里查看配对码，再选「找回原来的账」就能取回。',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('解除')),
                  ],
                ),
              );
              if (ok == true) await s.unpair();
            },
          ),
        ],
      ),
    );
  }
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
          if (bakedRelayUrl.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: const Text('两人同步'),
              subtitle: const Text('用配对码和另一半连在一起，账目只存在你们手机上'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('开始两人同步？'),
                    content: const Text('接下来创建配对，或输入另一半给你的配对码。\n\n现在的体验数据会留在这台手机上，不会发给另一半；以后选「单机体验」还能回来。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续')),
                    ],
                  ),
                );
                if (ok == true) await ref.read(switchModeProvider)(AppMode.relay);
              },
            ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('使用自己的服务器'),
            subtitle: const Text('体验数据留在这台手机上，不会上传'),
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
