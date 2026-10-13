import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'data/services.dart';
import 'providers.dart';
import 'ui/auth/household_setup_page.dart';
import 'ui/auth/login_page.dart';
import 'ui/auth/welcome_page.dart';
import 'ui/home/home_shell.dart';

const appName = '两人账';

/// Holds the [AppServices] of the current mode and swaps them (with a fresh
/// provider scope) when the user switches between offline trial and server.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.env, required this.initial});

  final AppEnv env;
  final AppServices initial;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late AppServices? _services = widget.initial;
  var _generation = 0;

  Future<void> _switchMode(AppMode mode) async {
    final old = _services;
    if (old == null || old.mode == mode) return;
    await widget.env.writeMode(mode);
    setState(() => _services = null);
    // let the old screens unsubscribe before their database closes
    await WidgetsBinding.instance.endOfFrame;
    await old.close();
    final next = await AppServices.open(widget.env);
    if (!mounted) return;
    setState(() {
      _services = next;
      _generation++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    if (services == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    return ProviderScope(
      key: ValueKey(_generation),
      overrides: [servicesProvider.overrideWithValue(services), switchModeProvider.overrideWithValue(_switchMode)],
      child: const LedgerApp(),
    );
  }
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const SessionGate(),
    );
  }
}

class SessionGate extends ConsumerWidget {
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stage = ref.watch(sessionProvider).value?.stage ?? ref.read(servicesProvider).session.value.stage;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: switch (stage) {
        SessionStage.needsServer => const WelcomePage(key: ValueKey('welcome')),
        SessionStage.loggedOut => const LoginPage(key: ValueKey('login')),
        SessionStage.needsHousehold => const HouseholdSetupPage(key: ValueKey('household')),
        SessionStage.ready => const HomeShell(key: ValueKey('home')),
      },
    );
  }
}
