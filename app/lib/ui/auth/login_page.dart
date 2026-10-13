import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services.dart';
import '../../providers.dart';
import '../settings/server_dialog.dart';
import '../widgets.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    for (final c in [_username, _name, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final s = ref.read(servicesProvider);
    await runGuarded(context, () async {
      if (_register) {
        await s.register(username: _username.text, password: _password.text, name: _name.text);
      } else {
        await s.login(_username.text, _password.text);
      }
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
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
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('登录')),
                        ButtonSegment(value: true, label: Text('注册')),
                      ],
                      selected: {_register},
                      onSelectionChanged: (v) => setState(() => _register = v.first),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        hintText: '小写字母、数字或下划线',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      validator: (v) {
                        final t = (v ?? '').trim().toLowerCase();
                        if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(t)) return '3～20 位小写字母、数字或下划线';
                        return null;
                      },
                    ),
                    if (_register) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: '昵称',
                          hintText: '对方会看到这个名字',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        textInputAction: TextInputAction.next,
                        validator: (v) => (v ?? '').trim().isEmpty ? '起个昵称吧' : null,
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        // keep "next" on the keyboard moving between text fields
                        suffixIcon: ExcludeFocus(
                          child: IconButton(
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      textInputAction: _register ? TextInputAction.next : TextInputAction.done,
                      onFieldSubmitted: (_) => _register ? null : _submit(),
                      validator: (v) => (v ?? '').length < 8 ? '密码至少 8 位' : null,
                    ),
                    if (_register) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _confirm,
                        obscureText: _obscure,
                        decoration: const InputDecoration(
                          labelText: '确认密码',
                          prefixIcon: Icon(Icons.lock_outline_rounded),
                        ),
                        onFieldSubmitted: (_) => _submit(),
                        validator: (v) => v != _password.text ? '两次输入的密码不一样' : null,
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : Text(_register ? '注册' : '登录'),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => showServerDialog(context, ref),
                      icon: const Icon(Icons.dns_outlined, size: 18),
                      label: Text(isPublicBuild ? '服务器：${_hostOf(ref.read(servicesProvider).serverUrl)}' : '服务器设置'),
                    ),
                    if (isPublicBuild)
                      TextButton(
                        onPressed: () => ref.read(switchModeProvider)(AppMode.offline),
                        child: const Text('先不连服务器，单机体验'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _hostOf(String url) => Uri.tryParse(url)?.authority ?? url;
