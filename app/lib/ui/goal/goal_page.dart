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
  final _income = TextEditingController();
  final _target = TextEditingController();
  bool _busy = false;

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
    _income.text = g == null ? '' : centsToInput(g.plannedIncome);
    _target.text = g == null ? '' : centsToInput(g.savingsTarget);
  }

  @override
  void dispose() {
    _income.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final income = parseYuan(_income.text);
    final target = parseYuan(_target.text);
    if (income == null || target == null) {
      showMessage(context, '请填写计划收入和攒钱目标');
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref
          .read(repositoryProvider)
          .saveGoal(id: _editing?.id, start: _start, end: _end, plannedIncome: income, savingsTarget: target),
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
    final now = Month.of(DateTime.now());

    final income = parseYuan(_income.text);
    final target = parseYuan(_target.text);
    final months = _start.monthsUntil(_end);
    Snapshot? preview;
    if (income != null && target != null && months > 0) {
      final g = Goal(startMonth: _start, endMonth: _end, plannedIncome: income, savingsTarget: target);
      final t = today();
      final m = g.contains(now) ? now : _start;
      preview = computeSnapshot(g, entries.map((e) => e.toBudget()), m, t);
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
                TextField(
                  controller: _income,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: const InputDecoration(
                    labelText: '计划期内两人总收入',
                    prefixText: '¥ ',
                    helperText: '例如两人一年工资合计 12 万，就填 120000',
                  ),
                  onChanged: (_) => setState(() {}),
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
          if (preview != null) ...[
            const SizedBox(height: 12),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('算一算', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
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
                    '每月限额是动态的：哪个月花超了，之后几个月会自动收紧；省下来了，之后就宽松一点。',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
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
                      subtitle: Text('收入 ${yuan(g.plannedIncome)} · 攒 ${yuan(g.savingsTarget)}'),
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
