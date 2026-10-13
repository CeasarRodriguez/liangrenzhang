import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers.dart';
import '../widgets.dart';

/// Walks through the phone settings needed for background alerts.
class NotificationSetupPage extends ConsumerStatefulWidget {
  const NotificationSetupPage({super.key});

  @override
  ConsumerState<NotificationSetupPage> createState() => _NotificationSetupPageState();
}

class _NotificationSetupPageState extends ConsumerState<NotificationSetupPage> with WidgetsBindingObserver {
  bool _notifications = false;
  bool _battery = false;
  bool _background = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = ref.read(servicesProvider);
    final notifications = await s.native.notificationsEnabled();
    final battery = s.isAndroid && await s.native.isIgnoringBatteryOptimizations();
    final background = await s.db.getSetting<bool>('bg_alerts') ?? true;
    if (mounted) {
      setState(() {
        _notifications = notifications;
        _battery = battery;
        _background = background;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(servicesProvider);
    final theme = Theme.of(context);

    Widget step(int n, String title, String desc, {required bool done, String? action, VoidCallback? onAction}) {
      return SectionCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: done ? AppColors.mint : theme.colorScheme.surfaceContainerHighest,
              child: done
                  ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                  : Text('$n', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(desc, style: TextStyle(fontSize: 13, height: 1.5, color: theme.colorScheme.outline)),
                  if (action != null && !done) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                      onPressed: onAction,
                      child: Text(action),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    final steps = <Widget>[
      step(
        1,
        '允许通知',
        '超支提醒通过系统通知发给你。',
        done: _notifications,
        action: '去允许',
        onAction: () async {
          await s.native.requestNotificationPermission();
          await _refresh();
        },
      ),
    ];

    if (s.isAndroid) {
      steps.addAll([
        step(
          2,
          '关闭电池优化',
          '不然系统会在锁屏后断开 App 和服务器的连接。',
          done: _battery,
          action: '去关闭',
          onAction: () async {
            await s.native.requestIgnoreBatteryOptimizations();
            await _refresh();
          },
        ),
        step(
          3,
          '允许后台运行和自启动（vivo / iQOO）',
          '1. 设置 → 电池 → 后台耗电管理 → 两人账 → 选「允许后台高耗电」\n'
              '2. 设置 → 应用与权限 → 权限管理 → 自启动 → 打开「两人账」\n'
              '3. 在最近任务里把两人账下拉「锁定」，防止一键清理时被关掉',
          done: false,
          action: '打开应用设置',
          onAction: s.native.openAppSettings,
        ),
      ]);
    } else {
      steps.add(step(2, '保持 App 已登录', '鸿蒙通过华为推送送达提醒，App 被划掉也能收到。首次登录后会自动登记这台手机。', done: _notifications));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('通知设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (s.isAndroid)
            Card(
              child: SwitchListTile(
                title: const Text('后台提醒'),
                subtitle: const Text('通知栏会常驻一个小图标，用来保持和服务器的连接，耗电很少'),
                value: _background,
                onChanged: (v) async {
                  await s.setBackgroundAlerts(v);
                  setState(() => _background = v);
                },
              ),
            ),
          const SizedBox(height: 12),
          for (final w in steps) ...[w, const SizedBox(height: 12)],
        ],
      ),
    );
  }
}
