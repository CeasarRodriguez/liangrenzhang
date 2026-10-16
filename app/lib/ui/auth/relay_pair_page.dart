import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/services.dart';
import '../../providers.dart';
import '../widgets.dart';

/// Shows the pairing code with a copy button.
Future<void> showPairingCodeDialog(BuildContext context, String code) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.key_rounded),
      title: const Text('配对码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            code,
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w600, height: 1.5),
          ),
          const SizedBox(height: 12),
          const Text(
            '让另一半打开两人账，选「两人同步」→「输入配对码」。\n\n'
            '配对码就是你们账本的钥匙，只发给另一半。作者的服务器不知道这串码，所以看不到你们的账。',
            style: TextStyle(height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: code));
            showMessage(context, '配对码已复制');
          },
          child: const Text('复制'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('好的')),
      ],
    ),
  );
}

/// Relay mode setup: one phone creates the pairing and shows the code, the
/// other enters it.
class RelayPairPage extends ConsumerStatefulWidget {
  const RelayPairPage({super.key});

  @override
  ConsumerState<RelayPairPage> createState() => _RelayPairPageState();
}

class _RelayPairPageState extends ConsumerState<RelayPairPage> {
  final _myName = TextEditingController();
  final _home = TextEditingController(text: '我们的小家');
  final _joinName = TextEditingController();
  final _code = TextEditingController();
  bool _restore = false;
  bool _busy = false;

  @override
  void dispose() {
    _myName.dispose();
    _home.dispose();
    _joinName.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    await runGuarded(context, action);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _create() async {
    final name = _myName.text.trim();
    if (name.isEmpty) return showMessage(context, '先填一下你的昵称');
    final s = ref.read(servicesProvider);
    await _run(() async {
      await s.createPair(name: name, householdName: _home.text.trim().isEmpty ? '我们的小家' : _home.text.trim());
      final code = s.pairingCode;
      // the home screen replaces this page underneath the dialog
      if (code != null && mounted) await showPairingCodeDialog(context, code);
    });
  }

  Future<void> _join() async {
    final name = _joinName.text.trim();
    if (!_restore && name.isEmpty) return showMessage(context, '先填一下你的昵称');
    if (_code.text.trim().isEmpty) return showMessage(context, '填一下另一半给你的配对码');
    final s = ref.read(servicesProvider);
    await _run(() => s.joinPair(_code.text, name: _restore ? null : name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = TextStyle(color: theme.colorScheme.outline, height: 1.5);
    return Scaffold(
      appBar: AppBar(
        title: const Text('两人同步'),
        leading: BackButton(onPressed: _busy ? null : () => ref.read(switchModeProvider)(AppMode.online)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline_rounded, color: AppColors.mint, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('账目只保存在你们两台手机上。作者的服务器只把加密后的数据转交给对方的手机，送达就删除，看不到内容。', style: hint)),
            ],
          ),
          const SizedBox(height: 20),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('我先创建', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('创建后会得到一串配对码，发给另一半。', style: hint),
                const SizedBox(height: 12),
                TextField(
                  controller: _myName,
                  decoration: const InputDecoration(labelText: '我的昵称'),
                  maxLength: 20,
                ),
                TextField(
                  controller: _home,
                  decoration: const InputDecoration(labelText: '家的名字'),
                  maxLength: 30,
                ),
                const SizedBox(height: 4),
                FilledButton(onPressed: _busy ? null : _create, child: const Text('创建')),
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
                  decoration: const InputDecoration(labelText: '配对码', hintText: 'XXXX-XXXX-…'),
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 12),
                if (!_restore)
                  TextField(
                    controller: _joinName,
                    decoration: const InputDecoration(labelText: '我的昵称'),
                    maxLength: 20,
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _restore,
                  onChanged: _busy ? null : (v) => setState(() => _restore = v),
                  title: const Text('我换了手机，要找回原来的账'),
                  subtitle: const Text('从另一半的手机上取回。旧手机上的备注只存在旧手机里，找不回来'),
                ),
                const SizedBox(height: 4),
                FilledButton.tonal(onPressed: _busy ? null : _join, child: Text(_restore ? '找回' : '加入')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A reinstalled phone in relay mode: waits for the partner's phone to send
/// everything, then asks which member this phone belongs to.
class RelayRestorePage extends ConsumerWidget {
  const RelayRestorePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(servicesProvider);
    final relay = s.relay;
    final theme = Theme.of(context);
    final hint = TextStyle(color: theme.colorScheme.outline, height: 1.5);
    final members = ref.watch(membersProvider).value ?? const [];

    Future<void> asNewMember() async {
      final name = await _askName(context);
      if (name != null && name.isNotEmpty && context.mounted) {
        await runGuarded(context, () => s.joinAsNewMember(name));
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('找回原来的账'),
        actions: [TextButton(onPressed: s.unpair, child: const Text('取消'))],
      ),
      body: relay == null
          ? const SizedBox.shrink()
          : ValueListenableBuilder<String>(
              valueListenable: relay.partnerMember,
              builder: (context, partner, _) {
                final candidates = members.where((m) => m.id != partner).toList();
                return ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (partner.isEmpty) ...[
                      const SizedBox(height: 24),
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 20),
                      Text('正在等另一半的手机发来数据……\n请让 TA 打开一下两人账（要联网）。', textAlign: TextAlign.center, style: hint),
                    ] else if (candidates.isEmpty) ...[
                      Text('另一半的手机上没有找到你原来的账。', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text('可以作为新成员加入，以后记的账会正常同步。', style: hint),
                    ] else ...[
                      Text('你是哪一位？', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text('选中后，原来记在这个名字下的账就回到这台手机上了。', style: hint),
                      const SizedBox(height: 12),
                      for (final m in candidates)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.person_rounded),
                            title: Text(m.displayName),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => runGuarded(context, () => s.adoptMember(m.id)),
                          ),
                        ),
                    ],
                    const SizedBox(height: 24),
                    TextButton(onPressed: asNewMember, child: const Text('我是第一次用，作为新成员加入')),
                  ],
                );
              },
            ),
    );
  }

  static Future<String?> _askName(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('我的昵称'),
        content: TextField(controller: controller, autofocus: true, maxLength: 20),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('加入')),
        ],
      ),
    );
    controller.dispose();
    return name;
  }
}
