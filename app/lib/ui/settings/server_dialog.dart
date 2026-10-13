import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api.dart';
import '../../data/services.dart';
import '../../providers.dart';
import '../widgets.dart';

/// Where our deploy scripts put the server certificate.
const _fingerprintCommand = 'openssl x509 -noout -fingerprint -sha256 -in /opt/couple-ledger/data/certs/server.crt';

/// Lets the user enter their server (first setup in the public build) or
/// point the app at a migrated server without reinstalling.
Future<void> showServerDialog(BuildContext context, WidgetRef ref) async {
  final s = ref.read(servicesProvider);
  final firstSetup = s.serverUrl.isEmpty;
  final controller = TextEditingController(text: s.serverUrl);
  var busy = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(firstSetup ? '连接服务器' : '服务器地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(hintText: 'https://1.2.3.4:8443'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              autofocus: firstSetup,
            ),
            const SizedBox(height: 8),
            Text(
              firstSetup ? '填你们自己部署的两人账服务器地址。两台手机要填同一个地址。' : '只有服务器迁移后才需要修改。两台手机都要改成同一个地址。',
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
                    var url = controller.text.trim();
                    if (!url.contains('://')) url = 'https://$url';
                    if (!url.startsWith('https://')) {
                      showMessage(context, '地址要以 https:// 开头');
                      return;
                    }
                    setState(() => busy = true);
                    final ok = await _connect(context, s, url);
                    if (!context.mounted) return;
                    setState(() => busy = false);
                    if (ok) {
                      Navigator.pop(context);
                      showMessage(context, firstSetup ? '已连接服务器' : '已切换服务器');
                    }
                  },
            child: Text(busy ? '连接中…' : (firstSetup ? '连接' : '保存')),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
}

/// Switches to [url], asking the user to confirm an unknown certificate.
Future<bool> _connect(BuildContext context, AppServices s, String url) async {
  try {
    await s.changeServer(url);
    return true;
  } on UntrustedCertificateException catch (e) {
    if (!context.mounted) return false;
    final trusted = await _confirmCertificate(context, e);
    if (trusted != true || !context.mounted) return false;
    return runGuarded(context, () => s.changeServer(url, trust: e.pems));
  } on Object catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Self-deployed servers use their own root certificate, which the app
/// cannot vouch for. Like SSH, the user compares the fingerprint once.
Future<bool?> _confirmCertificate(BuildContext context, UntrustedCertificateException e) {
  final theme = Theme.of(context);
  const mono = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4);
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        e.changed ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
        color: e.changed ? theme.colorScheme.error : null,
      ),
      title: Text(e.changed ? '服务器证书变了' : '确认服务器证书'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.changed
                  ? '这个地址的证书和上次信任的不一样。如果服务器刚重新签发过证书，核对指纹一致后可以重新信任；否则不要继续。'
                  : '这台服务器用的是自建证书，App 没法自动确认它就是你们的服务器，需要你核对一次。',
              style: const TextStyle(height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text('在服务器上执行下面的命令，输出的指纹要和本机收到的完全一致：', style: TextStyle(height: 1.5)),
            const SizedBox(height: 6),
            SelectableText(_fingerprintCommand, style: mono.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 12),
            const Text('本机收到的指纹：'),
            const SizedBox(height: 6),
            for (final fp in e.fingerprints) ...[
              SelectableText(_wrap(fp), style: mono.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('一致，信任'),
        ),
      ],
    ),
  );
}

/// Eight bytes per line so the fingerprint fits a phone-sized dialog.
String _wrap(String fingerprint) {
  final parts = fingerprint.split(':');
  final lines = <String>[];
  for (var i = 0; i < parts.length; i += 8) {
    lines.add(parts.sublist(i, i + 8 > parts.length ? parts.length : i + 8).join(':'));
  }
  return lines.join(':\n');
}
