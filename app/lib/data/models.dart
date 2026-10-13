import '../core/budget.dart';

/// Local records keep the server JSON shape plus a few `_`-prefixed flags.
typedef Json = Map<String, dynamic>;

class Entry {
  const Entry({
    required this.id,
    required this.household,
    required this.owner,
    required this.type,
    required this.amount,
    required this.category,
    required this.occurredOn,
    this.deleted = false,
    this.updated = '',
    this.created = '',
    this.pending = false,
  });

  final String id;
  final String household;
  final String owner;
  final String type;
  final int amount;
  final String category;
  final String occurredOn; // YYYY-MM-DD
  final bool deleted;
  final String updated;
  final String created;

  /// Not yet confirmed by the server.
  final bool pending;

  bool get isExpense => type == typeExpense;
  Month get month => Month.ofDate(occurredOn);

  BudgetEntry toBudget() => BudgetEntry(type: type, amount: amount, date: occurredOn);

  factory Entry.fromJson(Json j) => Entry(
    id: j['id'] as String,
    household: j['household'] as String? ?? '',
    owner: j['owner'] as String? ?? '',
    type: j['type'] as String? ?? typeExpense,
    amount: (j['amount'] as num?)?.toInt() ?? 0,
    category: j['category'] as String? ?? '其他',
    occurredOn: j['occurred_on'] as String? ?? '',
    deleted: j['deleted'] as bool? ?? false,
    updated: j['updated'] as String? ?? '',
    created: j['created'] as String? ?? '',
    pending: j['_pending'] as bool? ?? false,
  );

  /// Body sent to the server.
  Json toApi() => {
    'id': id,
    'household': household,
    'owner': owner,
    'type': type,
    'amount': amount,
    'category': category,
    'occurred_on': occurredOn,
    'deleted': deleted,
  };

  Json toLocal() => {...toApi(), 'updated': updated, 'created': created, '_pending': pending};

  Entry copyWith({String? type, int? amount, String? category, String? occurredOn, bool? deleted, bool? pending}) =>
      Entry(
        id: id,
        household: household,
        owner: owner,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        category: category ?? this.category,
        occurredOn: occurredOn ?? this.occurredOn,
        deleted: deleted ?? this.deleted,
        updated: updated,
        created: created,
        pending: pending ?? this.pending,
      );
}

class GoalRecord {
  const GoalRecord({
    required this.id,
    required this.household,
    required this.startMonth,
    required this.endMonth,
    required this.plannedIncome,
    required this.savingsTarget,
  });

  final String id;
  final String household;
  final Month startMonth;
  final Month endMonth;
  final int plannedIncome;
  final int savingsTarget;

  Goal get goal =>
      Goal(startMonth: startMonth, endMonth: endMonth, plannedIncome: plannedIncome, savingsTarget: savingsTarget);

  static GoalRecord? fromJson(Json j) {
    final start = Month.tryParse(j['start_month'] as String? ?? '');
    final end = Month.tryParse(j['end_month'] as String? ?? '');
    if (start == null || end == null) return null;
    return GoalRecord(
      id: j['id'] as String,
      household: j['household'] as String? ?? '',
      startMonth: start,
      endMonth: end,
      plannedIncome: (j['planned_income'] as num?)?.toInt() ?? 0,
      savingsTarget: (j['savings_target'] as num?)?.toInt() ?? 0,
    );
  }
}

class Member {
  const Member({required this.id, required this.username, required this.name, this.color = ''});

  final String id;
  final String username;
  final String name;
  final String color;

  String get displayName => name.isNotEmpty ? name : username;

  factory Member.fromJson(Json j) => Member(
    id: j['id'] as String,
    username: j['username'] as String? ?? '',
    name: j['name'] as String? ?? '',
    color: j['color'] as String? ?? '',
  );
}

class Household {
  const Household({required this.id, required this.name, required this.inviteCode});

  final String id;
  final String name;
  final String inviteCode;

  factory Household.fromJson(Json j) =>
      Household(id: j['id'] as String, name: j['name'] as String? ?? '', inviteCode: j['invite_code'] as String? ?? '');
}

class AlertItem {
  const AlertItem({
    required this.id,
    required this.kind,
    required this.periodKey,
    required this.title,
    required this.body,
    required this.read,
    required this.created,
  });

  final String id;
  final String kind;
  final String periodKey;
  final String title;
  final String body;
  final bool read;
  final String created;

  factory AlertItem.fromJson(Json j) => AlertItem(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? '',
    periodKey: j['period_key'] as String? ?? '',
    title: j['title'] as String? ?? '',
    body: j['body'] as String? ?? '',
    read: j['read'] as bool? ?? false,
    created: j['created'] as String? ?? '',
  );
}

class AlertMessage {
  const AlertMessage({
    required this.id,
    required this.level,
    required this.text,
    required this.isDefault,
    required this.enabled,
    required this.created,
  });

  final String id;
  final String level;
  final String text;
  final bool isDefault;
  final bool enabled;
  final String created;

  factory AlertMessage.fromJson(Json j) => AlertMessage(
    id: j['id'] as String,
    level: j['level'] as String? ?? '',
    text: j['text'] as String? ?? '',
    isDefault: j['is_default'] as bool? ?? false,
    enabled: j['enabled'] as bool? ?? false,
    created: j['created'] as String? ?? '',
  );
}
