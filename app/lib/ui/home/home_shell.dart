import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../providers.dart';
import '../entry/entry_editor.dart';
import '../records/records_page.dart';
import '../settings/settings_page.dart';
import '../stats/stats_page.dart';
import 'home_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<AlertItem>? _alertSub;
  StreamSubscription<AlertItem>? _offlineAlertSub;

  @override
  void initState() {
    super.initState();
    ref.listenManual(syncServiceProvider, (_, next) {
      _alertSub?.cancel();
      _alertSub = next.value?.newAlerts.listen(_showAlert);
    }, fireImmediately: true);
    _offlineAlertSub = ref.read(servicesProvider).offline?.newAlerts.listen(_showAlert);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        final s = ref.read(servicesProvider);
        s.sync?.syncNow();
        s.registerDevice();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _alertSub?.cancel();
    _offlineAlertSub?.cancel();
    super.dispose();
  }

  Future<void> _showAlert(AlertItem alert) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.favorite_rounded, color: Colors.pinkAccent),
        title: Text(alert.title),
        content: Text(alert.body, style: const TextStyle(height: 1.5)),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(96, 40)),
            onPressed: () => Navigator.pop(context),
            child: const Text('知道啦'),
          ),
        ],
      ),
    );
    await ref.read(repositoryProvider).markAlertRead(alert);
  }

  @override
  Widget build(BuildContext context) {
    final pages = const [HomePage(), RecordsPage(), StatsPage(), SettingsPage()];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: _tab <= 1
          ? FloatingActionButton.extended(
              onPressed: () => showEntryEditor(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('记一笔'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: '首页'),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: '账目',
          ),
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline_rounded),
            selectedIcon: Icon(Icons.pie_chart_rounded),
            label: '统计',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
