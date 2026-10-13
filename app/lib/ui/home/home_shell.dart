import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/badges.dart';
import '../../core/budget.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../badges/badges_page.dart';
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
        _monthlyCheck();
      },
    );

    // run the monthly check once the data is there: the first sync of this
    // session online, the local database offline
    ref.listenManual(syncStatusProvider, (prev, next) {
      if (prev?.value?.lastSync == null && next.value?.lastSync != null) _monthlyCheck();
    });
    void onLoaded(AsyncValue<Object?>? prev, AsyncValue<Object?> next) {
      if (!(prev?.hasValue ?? false) && next.hasValue) _monthlyCheck();
    }

    ref.listenManual(entriesProvider, onLoaded, fireImmediately: true);
    ref.listenManual(goalsProvider, onLoaded, fireImmediately: true);
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

  bool _checking = false;

  /// At the start of a month: reminds to record last month's income while
  /// it can still be corrected, and hands out last month's badge. Each
  /// popup shows once per phone.
  Future<void> _monthlyCheck() async {
    if (_checking) return;
    _checking = true;
    try {
      await Future<void>.delayed(Duration.zero);
      final s = ref.read(servicesProvider);
      // online, wait until the partner's records of this session are in
      if (!mounted || (s.offline == null && ref.read(syncStatusProvider).value?.lastSync == null)) return;
      final goals = ref.read(goalsProvider).value;
      if (goals == null || ref.read(entriesProvider).value == null) return;

      final t = today();
      final last = Month.of(t).add(-1);
      final record = goalFor(goals, last);
      if (record == null) return;
      List<BudgetEntry> entries() => [for (final e in ref.read(entriesProvider).value ?? const <Entry>[]) e.toBudget()];

      if (t.day <= incomeGraceDays) {
        final key = 'income_reminder:${s.userId}:$last';
        if (await s.db.getSetting<bool>(key) != true) {
          await s.db.setSetting(key, true);
          final missing = missingIncome(record.goal, entries(), last);
          if (missing.isNotEmpty && mounted) await _remindIncome(record, last, missing);
        }
      }

      final key = 'badge_popup:${s.userId}:$last';
      if (!mounted || await s.db.getSetting<bool>(key) == true) return;
      final current = entries();
      if (!monthAchieved(record.goal, current, last)) return;
      await s.db.setSetting(key, true);
      final number = badgeNumber(ref.read(badgesProvider), last);
      if (mounted) await showBadgeDialog(context, record.goal, current, last, number);
    } finally {
      _checking = false;
    }
  }

  Future<void> _remindIncome(GoalRecord goal, Month last, List<String> missing) async {
    final s = ref.read(servicesProvider);
    final members = ref.read(meAndPartnerProvider);
    final me = s.userId;
    String nameOf(String bucket) {
      if (bucket == me) return '我';
      if (bucket != othersKey) return members.nameOf(bucket);
      // "*" is whoever is not listed by id; for old goals, both of us
      if (goal.incomePlan.isEmpty) return '我们';
      return goal.incomePlan.containsKey(me) ? (members.partner?.displayName ?? 'TA') : '我';
    }

    final names = missing.map(nameOf).toList();
    final canRecord = s.offline != null || names.contains('我') || names.contains('我们');
    final next = last.add(1);
    final record = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.payments_outlined),
        title: Text('${last.month}月的收入还没登记完'),
        content: Text(
          '还没登记收入：${names.join('、')}\n\n'
          '${next.month}月$incomeGraceDays日前补记（日期选${last.month}月），限额会按实际到账修正；'
          '过了 $incomeGraceDays 号还没补记，就按预期收入算。',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('知道了')),
          if (canRecord) FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('去补记')),
        ],
      ),
    );
    if (record == true && mounted) {
      await showEntryEditor(context, initialType: typeIncome, initialDate: DateTime(last.year, last.month, last.daysIn));
    }
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
