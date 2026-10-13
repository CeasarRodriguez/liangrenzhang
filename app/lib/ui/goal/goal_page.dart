import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/budget.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../providers.dart';
import '../widgets.dart';

class GoalPage extends ConsumerStatefulWidget {
  const GoalPage({super.key});

  @override
  ConsumerState<GoalPage> createState() => _GoalPageState();
}

class _GoalPageState extends ConsumerState<GoalPage> {
  GoalRecord? _editing;
  late Month _start;
  late Month _end;
  final _myIncome = TextEditingController();
  final _partnerIncome = TextEditingController();
  final _target = TextEditingController();
  bool _busy = false;

  /// Combined monthly income of a goal saved before per-member planning.
  int? _legacyMonthly;

  @override
  void initState() {
    super.initState();
    _load(ref.read(activeGoalProvider));
  }

  void _load(GoalRecord? g) {
    final now = Month.of(DateTime.now());
    _editing = g;
    _start = g?.startMonth ?? now;
    _end = g?.endMonth ?? Month(now.year, 12);
    _target.text = g == null ? '' : centsToInput(g.savingsTarget);

    final plan = g?.incomePlan ?? const <String, int>{};
    final me = ref.read(currentUserIdProvider);
    final partner = ref.read(meAndPartnerProvider).partner?.id;
    // "*" is whoever of us is not listed by id (not joined when it was saved)
    final mine = plan[me] ?? (plan.containsKey(partner) ? plan[othersKey] : null);
    final theirs = plan[partner] ?? (plan.containsKey(me) ? plan[othersKey] : null);
    _myIncome.text = mine == null ? '' : centsToInput(mine);
    _partnerIncome.text = theirs == null ? '' : centsToInput(theirs);
    _legacyMonthly = g != null && plan.isEmpty ? g.plannedIncome ~/ g.goal.totalMonths : null;
  }

  @override
  void dispose() {
    _myIncome.dispose();
    _partnerIncome.dispose();
    _target.dispose();
    super.dispose();
  }

  /// The income plan the form describes, or null while incomplete.
  Map<String, int>? _plan() {
    final mine = parseYuan(_myIncome.text);
    final theirs = parseYuan(_partnerIncome.text);
    if (mine == null || theirs == null) return null;
    final partner = ref.read(meAndPartnerProvider).partner?.id;
    return {ref.read(currentUserIdProvider): mine, partner ?? othersKey: theirs};
  }

  Future<void> _save() async {
    final plan = _plan();
    final target = parseYuan(_target.text);
    if (plan == null || target == null) {
      showMessage(context, '请填写两人每月的预期收入和攒钱目标（没有收入可以填 0）');
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref
          .read(repositoryProvider)
          .saveGoal(id: _editing?.id, start: _start, end: _end, incomePlan: plan, savingsTarget: target),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showMessage(context, '攒钱计划已保存');
      Navigator.pop(context);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个攒钱计划？'),
        content: const Text('账目不会受影响，只是不再计算限额和提醒。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (await runGuarded(context, () => ref.read(repositoryProvider).deleteGoal(_editing!.id)) && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goals = ref.watch(goalsProvider).value ?? const <GoalRecord>[];
    final entries = ref.watch(entriesProvider).value ?? const <Entry>[];
    final members = ref.watch(meAndPartnerProvider);
    final partnerName = members.partner?.displayName ?? 'TA';
    final now = Month.of(DateTime.now());

    final plan = _plan();
    final target = parseYuan(_target.text);
    final months = _start.monthsUntil(_end);
    Goal? goal;
    Snapshot? preview;
    if (plan != null && target != null && months > 0) {
      final monthly = plan.values.fold(0, (a, b) => a + b);
      goal = Goal(
        startMonth: _start,
        endMonth: _end,
        plannedIncome: monthly * months,
        savingsTarget: target,
        incomePlan: plan,
      );
      final m = goal.contains(now) ? now : _start;
      preview = computeSnapshot(goal, entries.map((e) => e.toBudget()), m, today());
    }

    return Scaffold(
      appBar: AppBar(title: Text(_editing == null ? '设置攒钱目标' : '修改攒钱目标')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('计划期', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ActionChip(
                      label: const Text('本月到年底'),
                      onPressed: () => setState(() {
                        _start = now;
                        _end = Month(now.year, 12);
                      }),
                    ),
                    ActionChip(
                      label: Text('${now.year}全年'),
                      onPressed: () => setState(() {
                        _start = Month(now.year, 1);
                        _end = Month(now.year, 12);
                      }),
                    ),
                    ActionChip(
                      label: Text('${now.year + 1}全年'),
                      onPressed: () => setState(() {
                        _start = Month(now.year + 1, 1);
                        _end = Month(now.year + 1, 12);
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _MonthField(
                        label: '开始',
                        value: _start,
                        onChanged: (m) => setState(() {
                          _start = m;
                          if (_end.index < m.index) _end = m;
                        }),
                      ),
                    ),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('至')),
                    Expanded(
                      child: _MonthField(
                        label: '结束',
                        value: _end,
                        first: _start,
                        onChanged: (m) => setState(() => _end = m),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('共 $months 个月', style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
                const SizedBox(height: 16),
                if (_legacyMonthly != null) ...[
                  Text(
                    '以前填的是两人合计，平均每月 ${yuan(_legacyMonthly!)}，现在请两人分别填写',
                    style: const TextStyle(fontSize: 13, color: AppColors.warning),
                  ),
                  const SizedBox(height: 8),
                ],
                _IncomeField(controller: _myIncome, label: '我每月到手（预期）', onChanged: () => setState(() {})),
                const SizedBox(height: 12),
                _IncomeField(
                  controller: _partnerIncome,
                  label: '$partnerName每月到手（预期）',
                  helper: members.partner == null ? 'TA 还没加入也可以先填，加入后自动算到 TA 名下' : null,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _target,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: const InputDecoration(labelText: '计划攒下', prefixText: '¥ '),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          if (preview != null && goal != null) ...[
            const SizedBox(height: 12),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('算一算', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _IncomePreview(
                    goal: goal,
                    snapshot: preview,
                    entries: entries,
                    myId: members.me?.id ?? '',
                    partnerName: partnerName,
                  ),
                  const SizedBox(height: 8),
                  if (preview.budget <= 0)
                    const Text('攒钱目标不低于计划收入，每个月的可花额度会是 0，确定吗？', style: TextStyle(color: AppColors.danger))
                  else ...[
                    Text('计划期一共能花 ${yuan(preview.budget)}，平均每月 ${yuan(preview.budget ~/ months)}'),
                    const SizedBox(height: 4),
                    Text(
                      '${Month.parse(preview.month).label}的限额：${yuan(preview.monthLimit)}'
                      '${preview.spentBefore > 0 ? '（已扣除之前月份花掉的 ${yuan(preview.spentBefore)}）' : ''}',
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '每月限额是动态的：哪个月花超了，之后几个月会自动收紧；省下来了，之后就宽松一点。\n'
                    '收入也按实际到账修正：上个月的收入可以在次月 $incomeGraceDays 号前补记，'
                    '之后按实际结算，多了放宽、少了收紧；某人整月没记收入就按预期算。',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.outline, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
          if (_editing != null)
            TextButton(
              onPressed: _busy ? null : _delete,
              child: const Text('删除这个计划', style: TextStyle(color: AppColors.danger)),
            ),
          if (goals.length > 1 || (goals.isNotEmpty && _editing == null)) ...[
            const SizedBox(height: 24),
            Text('所有攒钱计划', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (final g in goals)
                    ListTile(
                      title: Text('${g.startMonth.label} - ${g.endMonth.label}'),
                      subtitle: Text('预期收入 ${yuan(g.plannedIncome)} · 攒 ${yuan(g.savingsTarget)}'),
                      trailing: g.id == _editing?.id ? const Icon(Icons.edit_rounded) : null,
                      onTap: () => setState(() => _load(g)),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _load(null)),
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建另一个时间段的计划'),
            ),
          ],
        ],
      ),
    );
  }
}

class _MonthField extends StatelessWidget {
  const _MonthField({required this.label, required this.value, required this.onChanged, this.first});

  final String label;
  final Month value;
  final Month? first;
  final ValueChanged<Month> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final m = await showMonthPicker(context, value, first: first);
        if (m != null) onChanged(m);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value.label),
      ),
    );
  }
}

class _IncomeField extends StatelessWidget {
  const _IncomeField({required this.controller, required this.label, required this.onChanged, this.helper});

  final TextEditingController controller;
  final String label;
  final String? helper;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: InputDecoration(labelText: label, prefixText: '¥ ', helperText: helper),
      onChanged: (_) => onChanged(),
    );
  }
}

/// Expected vs. corrected income, and what has arrived this month.
class _IncomePreview extends StatelessWidget {
  const _IncomePreview({
    required this.goal,
    required this.snapshot,
    required this.entries,
    required this.myId,
    required this.partnerName,
  });

  final Goal goal;
  final Snapshot snapshot;
  final List<Entry> entries;
  final String myId;
  final String partnerName;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    final diff = snapshot.expectedIncome - goal.plannedIncome;
    final month = Month.parse(snapshot.month);
    final k = month.index - goal.startMonth.index;
    final actual = actualIncome(goal, entries.map((e) => e.toBudget()));
    final mine = incomeBucket(goal, myId);
    final theirs = goal.incomePlan.keys.firstWhere((b) => b != mine, orElse: () => othersKey);

    String arrived(String who, String bucket) =>
        '$who ${yuan(actual[bucket]?[k] ?? 0)} / 预期 ${yuan(plannedIncomeOf(goal, bucket, k))}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('计划期 ${goal.totalMonths} 个月，预期两人共收入 ${yuan(goal.plannedIncome)}'),
        const SizedBox(height: 4),
        Text(
          diff == 0
              ? '按实际到账修正后：和预期一致'
              : '按实际到账修正后：${yuan(snapshot.expectedIncome)}（比预期${diff > 0 ? '多' : '少'} ${yuan(diff.abs())}）',
          style: TextStyle(color: diff < 0 ? AppColors.warning : null),
        ),
        if (k >= 0 && k < goal.totalMonths) ...[
          const SizedBox(height: 4),
          Text(
            '${month.month}月已到账：${arrived('我', mine)}；${arrived(partnerName, theirs)}',
            style: TextStyle(fontSize: 13, color: outline),
          ),
        ],
      ],
    );
  }
}
