// Package alertcopy holds the default friendly-reminder messages and the
// placeholder rendering shared (by spec) with the Dart client preview.
package alertcopy

import (
	"strconv"
	"strings"

	"couple-ledger/server/internal/budget"
)

// Titles is the notification title per alert level.
var Titles = map[string]string{
	budget.LevelMonth80:    "本月预算已用八成",
	budget.LevelMonth100:   "本月额度已用完",
	budget.LevelMonth120:   "本月超支提醒",
	budget.LevelPeriodOver: "攒钱目标预警",
}

// Defaults are seeded into alert_messages for every new household.
var Defaults = map[string][]string{
	budget.LevelMonth80: {
		"本月预算已经用掉八成啦，剩下的日子一起悠着点，小金库在向我们招手～",
		"这个月已经花了 ¥{已花}，离限额 ¥{限额} 只剩 ¥{本月剩余}。接下来 {剩余天数} 天，每天控制在 ¥{日均可花} 以内就稳了！",
		"叮～本月额度进度条走到 80% 了。不急不慌，想买的先放进购物车冷静几天？",
		"温馨提示：本月还能花 ¥{本月剩余}。我们一起攒钱的样子，真的很棒 ❤️",
		"预算小管家报告：本月已用八成。距离攒够 ¥{目标} 还差 ¥{还差}，加油加油～",
		"这个月花得有点快哦，剩下的 ¥{本月剩余} 要省着点用，留点给未来的我们～",
	},
	budget.LevelMonth100: {
		"这个月的额度刚好用完。再花的部分会让下个月紧一点点，没关系，一起调整就好 💪",
		"本月限额 ¥{限额} 已经用完啦～接下来能不花就先不花，周末在家做饭也很浪漫呀。",
		"额度见底提醒：本月已花 ¥{已花}。今天开始进入「省钱模式」，我们一起坚持到月底！",
		"本月预算到站了 🚉 再花就要向下个月借啦，先忍一忍，好东西不会跑的～",
		"小金库发来消息：这个月的零花钱用完啦。抱抱，下个月我们再好好安排。",
		"本月可花的钱已经全部花完。离攒够 ¥{目标} 还差 ¥{还差}，稳住，我们能行！",
	},
	budget.LevelMonth120: {
		"本月已超出限额 ¥{超出金额}。离攒够 ¥{目标} 还差 ¥{还差}，接下来几天能省则省？",
		"超支警报 🚨 这个月已经多花了 ¥{超出金额}，下个月的额度会自动收紧，一起踩踩刹车吧～",
		"本月花了 ¥{已花}，比计划多出两成多。不是批评，只是提醒：我们的攒钱目标还在等我们哦。",
		"这个月有点放飞自我啦（多花了 ¥{超出金额}）。今晚一起复盘一下？顺便给彼此一个拥抱～",
		"预算小管家有点慌：本月超支 ¥{超出金额}。剩下的日子一起清空购物车、少点外卖吧！",
		"多花的 ¥{超出金额} 会分摊到之后几个月。别有压力，从今天开始省就来得及～",
	},
	budget.LevelPeriodOver: {
		"计划期能花的钱已经花完了，再花就要动用攒钱目标啦。要不要一起看看目标需不需要调整？",
		"可花额度已全部用完，之后每一笔都在「吃」攒钱目标。我们坐下来聊聊下一步？",
		"重要提醒：累计支出已超出计划。目前已攒 ¥{已攒}，离目标 ¥{目标} 还差 ¥{还差}。",
		"攒钱目标亮黄灯了 ⚠️ 可花额度已用完，要不要一起调整一下目标，或者再努努力？",
		"额度全部花完啦。目标不是枷锁，调整一下也没关系，重要的是我们一起往前走 ❤️",
	},
}

// Fallback is used when every message of a level has been disabled.
var Fallback = map[string]string{
	budget.LevelMonth80:    "本月预算已用掉 80%，还剩 ¥{本月剩余}。",
	budget.LevelMonth100:   "本月额度 ¥{限额} 已用完。",
	budget.LevelMonth120:   "本月已超出限额 ¥{超出金额}。",
	budget.LevelPeriodOver: "计划期可花额度已用完，还差 ¥{还差} 达成攒钱目标。",
}

// Placeholders lists the supported template variables.
var Placeholders = []string{"{限额}", "{已花}", "{本月剩余}", "{超出金额}", "{目标}", "{已攒}", "{还差}", "{剩余天数}", "{日均可花}"}

// Render fills the template placeholders from the budget snapshot.
func Render(tpl string, s budget.Snapshot, savingsTarget int64) string {
	over := s.MonthSpent - s.MonthLimit
	if over < 0 {
		over = 0
	}
	remaining := s.MonthRemaining
	if remaining < 0 {
		remaining = 0
	}

	return strings.NewReplacer(
		"{限额}", FormatYuan(s.MonthLimit),
		"{已花}", FormatYuan(s.MonthSpent),
		"{本月剩余}", FormatYuan(remaining),
		"{超出金额}", FormatYuan(over),
		"{目标}", FormatYuan(savingsTarget),
		"{已攒}", FormatYuan(s.Saved),
		"{还差}", FormatYuan(s.ToTarget),
		"{剩余天数}", strconv.Itoa(s.DaysLeft),
		"{日均可花}", FormatYuan(s.DailyAllowance),
	).Replace(tpl)
}

// FormatYuan formats cents as yuan with thousands separators,
// dropping the decimals when they are zero: 123456 -> "1,234.56", 100000 -> "1,000".
func FormatYuan(cents int64) string {
	sign := ""
	if cents < 0 {
		sign = "-"
		cents = -cents
	}

	intPart := strconv.FormatInt(cents/100, 10)
	var b strings.Builder
	for i, r := range intPart {
		if i > 0 && (len(intPart)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}

	if frac := cents % 100; frac != 0 {
		b.WriteByte('.')
		if frac < 10 {
			b.WriteByte('0')
		}
		b.WriteString(strconv.FormatInt(frac, 10))
	}

	return sign + b.String()
}
