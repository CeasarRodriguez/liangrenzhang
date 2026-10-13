import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/services.dart';
import '../../providers.dart';
import '../settings/server_dialog.dart';

/// First screen of the public build: try the app offline, or connect to a
/// server the couple deployed themselves.
class WelcomePage extends ConsumerWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset('assets/logo.png', height: 96),
                  const SizedBox(height: 12),
                  Text(
                    '两人账',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '一起记账，一起攒钱',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 32),
                  _Choice(
                    icon: Icons.phone_android_rounded,
                    title: '单机体验',
                    body: '不需要服务器，打开就能用。数据只存在这台手机上，用「TA（模拟）」代替另一半，先熟悉一下功能。',
                    action: '开始体验',
                    onPressed: () => ref.read(switchModeProvider)(AppMode.offline),
                  ),
                  const SizedBox(height: 12),
                  _Choice(
                    icon: Icons.dns_rounded,
                    title: '连接服务器',
                    body: '两个人各用一台手机，实时同步，App 关着也能收到超支提醒。需要先自己部署服务端，方法见开源项目里的 docs/服务器部署.md。',
                    action: '填写服务器地址',
                    primary: true,
                    onPressed: () => showServerDialog(context, ref),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.coral),
                const SizedBox(width: 10),
                Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: TextStyle(height: 1.5, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            primary
                ? FilledButton(onPressed: onPressed, child: Text(action))
                : FilledButton.tonal(onPressed: onPressed, child: Text(action)),
          ],
        ),
      ),
    );
  }
}
