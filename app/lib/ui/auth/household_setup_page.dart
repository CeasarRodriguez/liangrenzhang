import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../widgets.dart';

class HouseholdSetupPage extends ConsumerStatefulWidget {
  const HouseholdSetupPage({super.key});

  @override
  ConsumerState<HouseholdSetupPage> createState() => _HouseholdSetupPageState();
}

class _HouseholdSetupPageState extends ConsumerState<HouseholdSetupPage> {
  final _name = TextEditingController(text: '我们的小家');
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await runGuarded(context, action);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.read(servicesProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('组建我们的家'),
        actions: [TextButton(onPressed: _busy ? null : s.logout, child: const Text('退出'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('一个人先创建，把邀请码告诉另一半；另一半选择「加入」并输入邀请码。', style: TextStyle(color: theme.colorScheme.outline)),
          const SizedBox(height: 20),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('我先创建', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '家的名字'),
                  maxLength: 30,
                ),
                const SizedBox(height: 4),
                FilledButton(
                  onPressed: _busy ? null : () => _run(() => s.createHousehold(_name.text.trim())),
                  child: const Text('创建'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('另一半已经创建了', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  decoration: const InputDecoration(labelText: '6 位邀请码'),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 4),
                FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () {
                          if (_code.text.length != 6) {
                            showMessage(context, '邀请码是 6 位数字');
                            return;
                          }
                          _run(() => s.joinHousehold(_code.text));
                        },
                  child: const Text('加入'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
