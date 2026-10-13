import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../widgets.dart';

/// Lets the user point the app at a migrated server without reinstalling.
Future<void> showServerDialog(BuildContext context, WidgetRef ref) async {
  final s = ref.read(servicesProvider);
  final controller = TextEditingController(text: s.serverUrl);
  var busy = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('服务器地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(hintText: 'https://1.2.3.4:8443'),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            Text(
              '只有服务器迁移后才需要修改。两台手机都要改成同一个地址。',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
            onPressed: busy
                ? null
                : () async {
                    final url = controller.text.trim();
                    if (!url.startsWith('https://')) {
                      showMessage(context, '地址要以 https:// 开头');
                      return;
                    }
                    setState(() => busy = true);
                    final ok = await runGuarded(context, () => s.changeServer(url));
                    if (!context.mounted) return;
                    setState(() => busy = false);
                    if (ok) {
                      Navigator.pop(context);
                      showMessage(context, '已切换服务器');
                    }
                  },
            child: Text(busy ? '连接中…' : '保存'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
}
