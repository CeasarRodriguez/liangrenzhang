// Friendly-reminder copy helpers. Mirrors server/internal/alertcopy (Go):
// the server renders real alerts; the app uses this for the editor preview.

import 'budget.dart';
import 'money.dart';

const alertTitles = {
  levelMonth80: '本月预算已用八成',
  levelMonth100: '本月额度已用完',
  levelMonth120: '本月超支提醒',
  levelPeriodOver: '攒钱目标预警',
};

/// Short tab labels for the message editor.
const alertLevelLabels = {
  levelMonth80: '用到 80%',
  levelMonth100: '用完 100%',
  levelMonth120: '超支 120%',
  levelPeriodOver: '计划期超额',
};

const alertPlaceholders = {
  '{限额}': '本月限额',
  '{已花}': '本月已花',
  '{本月剩余}': '本月还能花',
  '{超出金额}': '本月超出的金额',
  '{目标}': '攒钱目标',
  '{已攒}': '目前已攒',
  '{还差}': '离目标还差',
  '{剩余天数}': '本月剩余天数',
  '{日均可花}': '剩余每天可花',
};

String renderAlert(String template, Snapshot s, int savingsTarget) {
  final over = s.monthSpent - s.monthLimit;
  final remaining = s.monthRemaining < 0 ? 0 : s.monthRemaining;
  final values = {
    '{限额}': formatYuan(s.monthLimit),
    '{已花}': formatYuan(s.monthSpent),
    '{本月剩余}': formatYuan(remaining),
    '{超出金额}': formatYuan(over < 0 ? 0 : over),
    '{目标}': formatYuan(savingsTarget),
    '{已攒}': formatYuan(s.saved),
    '{还差}': formatYuan(s.toTarget),
    '{剩余天数}': '${s.daysLeft}',
    '{日均可花}': formatYuan(s.dailyAllowance),
  };
  return template.replaceAllMapped(RegExp(r'\{[^{}]+\}'), (m) => values[m.group(0)] ?? m.group(0)!);
}

/// Placeholders in [template] that the server will not replace.
List<String> unknownPlaceholders(String template) => RegExp(
  r'\{[^{}]+\}',
).allMatches(template).map((m) => m.group(0)!).where((p) => !alertPlaceholders.containsKey(p)).toList();

/// A believable example snapshot for previews (82% of the month used).
const previewSnapshot = Snapshot(
  month: '',
  inPeriod: true,
  budget: 2000000,
  spentBefore: 0,
  monthsLeft: 3,
  monthLimit: 333333,
  monthSpent: 410000,
  monthIncome: 0,
  monthRemaining: -76667,
  usedPercent: 123,
  periodSpent: 410000,
  periodIncome: 900000,
  saved: 490000,
  toTarget: 1510000,
  expectedSaved: 666666,
  periodOver: false,
  daysLeft: 12,
  dailyAllowance: 0,
);

/// Default messages, same as server/internal/alertcopy.Defaults. Only the
/// offline trial build seeds these locally; online households get them
/// from the server.
const defaultAlertMessages = {
  levelMonth80: [
    '本月预算已经用掉八成啦，剩下的日子一起悠着点，小金库在向我们招手～',
    '这个月已经花了 ¥{已花}，离限额 ¥{限额} 只剩 ¥{本月剩余}。接下来 {剩余天数} 天，每天控制在 ¥{日均可花} 以内就稳了！',
    '叮～本月额度进度条走到 80% 了。不急不慌，想买的先放进购物车冷静几天？',
    '温馨提示：本月还能花 ¥{本月剩余}。我们一起攒钱的样子，真的很棒 ❤️',
    '预算小管家报告：本月已用八成。距离攒够 ¥{目标} 还差 ¥{还差}，加油加油～',
    '这个月花得有点快哦，剩下的 ¥{本月剩余} 要省着点用，留点给未来的我们～',
  ],
  levelMonth100: [
    '这个月的额度刚好用完。再花的部分会让下个月紧一点点，没关系，一起调整就好 💪',
    '本月限额 ¥{限额} 已经用完啦～接下来能不花就先不花，周末在家做饭也很浪漫呀。',
    '额度见底提醒：本月已花 ¥{已花}。今天开始进入「省钱模式」，我们一起坚持到月底！',
    '本月预算到站了 🚉 再花就要向下个月借啦，先忍一忍，好东西不会跑的～',
    '小金库发来消息：这个月的零花钱用完啦。抱抱，下个月我们再好好安排。',
    '本月可花的钱已经全部花完。离攒够 ¥{目标} 还差 ¥{还差}，稳住，我们能行！',
  ],
  levelMonth120: [
    '本月已超出限额 ¥{超出金额}。离攒够 ¥{目标} 还差 ¥{还差}，接下来几天能省则省？',
    '超支警报 🚨 这个月已经多花了 ¥{超出金额}，下个月的额度会自动收紧，一起踩踩刹车吧～',
    '本月花了 ¥{已花}，比计划多出两成多。不是批评，只是提醒：我们的攒钱目标还在等我们哦。',
    '这个月有点放飞自我啦（多花了 ¥{超出金额}）。今晚一起复盘一下？顺便给彼此一个拥抱～',
    '预算小管家有点慌：本月超支 ¥{超出金额}。剩下的日子一起清空购物车、少点外卖吧！',
    '多花的 ¥{超出金额} 会分摊到之后几个月。别有压力，从今天开始省就来得及～',
  ],
  levelPeriodOver: [
    '计划期能花的钱已经花完了，再花就要动用攒钱目标啦。要不要一起看看目标需不需要调整？',
    '可花额度已全部用完，之后每一笔都在「吃」攒钱目标。我们坐下来聊聊下一步？',
    '重要提醒：累计支出已超出计划。目前已攒 ¥{已攒}，离目标 ¥{目标} 还差 ¥{还差}。',
    '攒钱目标亮黄灯了 ⚠️ 可花额度已用完，要不要一起调整一下目标，或者再努努力？',
    '额度全部花完啦。目标不是枷锁，调整一下也没关系，重要的是我们一起往前走 ❤️',
  ],
};

/// Used when every message of a level has been disabled.
const fallbackAlertMessages = {
  levelMonth80: '本月预算已用掉 80%，还剩 ¥{本月剩余}。',
  levelMonth100: '本月额度 ¥{限额} 已用完。',
  levelMonth120: '本月已超出限额 ¥{超出金额}。',
  levelPeriodOver: '计划期可花额度已用完，还差 ¥{还差} 达成攒钱目标。',
};
