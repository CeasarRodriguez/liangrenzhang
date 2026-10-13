import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/budget.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/services.dart';
import 'data/sync.dart';

/// Overridden by AppRoot with the initialized instance.
final servicesProvider = Provider<AppServices>((ref) => throw UnimplementedError());

/// Switches between the offline trial and server mode (public build only).
/// Overridden by AppRoot, which restarts the app on the other database.
final switchModeProvider = Provider<Future<void> Function(AppMode)>((ref) => throw UnimplementedError());

final repositoryProvider = Provider((ref) => Repository(ref.watch(servicesProvider)));

Stream<T> _listenable<T>(Ref ref, ValueListenable<T> l) {
  final controller = StreamController<T>();
  void emit() => controller.add(l.value);
  l.addListener(emit);
  emit();
  ref.onDispose(() {
    l.removeListener(emit);
    controller.close();
  });
  return controller.stream;
}

final sessionProvider = StreamProvider<Session>((ref) {
  return _listenable(ref, ref.watch(servicesProvider).session);
});

final syncServiceProvider = StreamProvider<SyncService?>((ref) async* {
  final s = ref.watch(servicesProvider);
  yield s.sync;
  yield* s.syncChanges;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final sync = ref.watch(syncServiceProvider).value;
  if (sync == null) return Stream.value(const SyncStatus());
  return _listenable(ref, sync.status);
});

final outboxCountProvider = StreamProvider<int>((ref) => ref.watch(servicesProvider).db.watchOutboxCount());

final entriesProvider = StreamProvider<List<Entry>>((ref) => ref.watch(servicesProvider).db.watchEntries());

final notesProvider = StreamProvider<Map<String, String>>((ref) => ref.watch(servicesProvider).db.watchNotes());

final goalsProvider = StreamProvider<List<GoalRecord>>((ref) => ref.watch(servicesProvider).db.watchGoals());

final membersProvider = StreamProvider<List<Member>>((ref) => ref.watch(servicesProvider).db.watchMembers());

final householdProvider = StreamProvider<Household?>((ref) {
  final s = ref.watch(servicesProvider);
  final id = ref.watch(sessionProvider).value?.householdId ?? '';
  if (id.isEmpty) return Stream.value(null);
  return s.db.watchHousehold(id);
});

final alertsProvider = StreamProvider<List<AlertItem>>((ref) => ref.watch(servicesProvider).db.watchAlerts());

final alertMessagesProvider = StreamProvider<List<AlertMessage>>(
  (ref) => ref.watch(servicesProvider).db.watchAlertMessages(),
);

final currentUserIdProvider = Provider<String>((ref) => ref.watch(sessionProvider).value?.userId ?? '');

class Members {
  const Members(this.me, this.partner);

  final Member? me;
  final Member? partner;

  String nameOf(String userId) {
    if (me?.id == userId) return '我';
    if (partner?.id == userId) return partner!.displayName;
    return 'TA';
  }
}

final meAndPartnerProvider = Provider<Members>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  final members = ref.watch(membersProvider).value ?? const [];
  return Members(members.where((m) => m.id == uid).firstOrNull, members.where((m) => m.id != uid).firstOrNull);
});

/// Month shown on the records and stats pages.
class SelectedMonth extends Notifier<Month> {
  @override
  Month build() => Month.of(DateTime.now());

  void set(Month m) => state = m;
  void previous() => state = state.add(-1);
  void next() => state = state.add(1);
}

final selectedMonthProvider = NotifierProvider<SelectedMonth, Month>(SelectedMonth.new);

DateTime today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

GoalRecord? goalFor(List<GoalRecord> goals, Month m) => goals.where((g) => g.goal.contains(m)).firstOrNull;

/// The goal covering the current month, if any.
final activeGoalProvider = Provider<GoalRecord?>((ref) {
  final goals = ref.watch(goalsProvider).value ?? const [];
  return goalFor(goals, Month.of(today()));
});

class MonthBudget {
  const MonthBudget(this.goal, this.snapshot);

  final GoalRecord? goal;
  final Snapshot? snapshot;
}

/// Budget snapshot for the current month (home page).
final currentBudgetProvider = Provider<MonthBudget>((ref) {
  final goal = ref.watch(activeGoalProvider);
  if (goal == null) return const MonthBudget(null, null);
  final entries = ref.watch(entriesProvider).value ?? const [];
  final t = today();
  final snap = computeSnapshot(goal.goal, entries.map((e) => e.toBudget()), Month.of(t), t);
  return MonthBudget(goal, snap);
});
