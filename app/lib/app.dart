import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'data/services.dart';
import 'providers.dart';
import 'ui/auth/household_setup_page.dart';
import 'ui/auth/login_page.dart';
import 'ui/home/home_shell.dart';

const appName = '两人账';

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
    final stage = ref.watch(sessionProvider).value?.stage ?? SessionStage.loggedOut;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: switch (stage) {
        SessionStage.loggedOut => const LoginPage(key: ValueKey('login')),
        SessionStage.needsHousehold => const HouseholdSetupPage(key: ValueKey('household')),
        SessionStage.ready => const HomeShell(key: ValueKey('home')),
      },
    );
  }
}
