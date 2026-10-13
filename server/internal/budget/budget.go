// Package budget implements the savings-goal math shared (by spec and by
// test fixtures in shared/budget_cases.json) with the Dart client.
//
// All money values are integer cents (分). Dates are local calendar dates
// ("YYYY-MM-DD") so month bucketing never depends on server timezone.
package budget

import (
	"fmt"
	"time"
)

const (
	TypeIncome  = "income"
	TypeExpense = "expense"
)

// Alert levels, ordered by severity.
const (
	LevelMonth80    = "month_80"
	LevelMonth100   = "month_100"
	LevelMonth120   = "month_120"
	LevelPeriodOver = "period_over"
)

// AllLevels lists every alert level in ascending severity.
var AllLevels = []string{LevelMonth80, LevelMonth100, LevelMonth120, LevelPeriodOver}

// UsedPercentOverflow is reported when the month limit is 0 but money was spent.
const UsedPercentOverflow = 999

// IncomeGraceDays is how long into the next month a month's income can
// still be recorded before the month is settled.
const IncomeGraceDays = 7

// OthersKey is the IncomePlan bucket for members not listed by user id
// (e.g. a partner who has not joined yet).
const OthersKey = "*"

// Month is a calendar month.
type Month struct {
	Year  int
	Month int // 1..12
}

func ParseMonth(s string) (Month, error) {
	var m Month
	if len(s) != 7 || s[4] != '-' {
		return m, fmt.Errorf("invalid month %q, want YYYY-MM", s)
	}
	if _, err := fmt.Sscanf(s, "%4d-%2d", &m.Year, &m.Month); err != nil {
		return m, fmt.Errorf("invalid month %q: %w", s, err)
	}
	if m.Month < 1 || m.Month > 12 {
		return m, fmt.Errorf("invalid month %q", s)
	}
	return m, nil
}

// MonthOfDate returns the month part of a "YYYY-MM-DD" date.
func MonthOfDate(date string) (Month, error) {
	if len(date) < 7 {
		return Month{}, fmt.Errorf("invalid date %q", date)
	}
	return ParseMonth(date[:7])
}

func MonthOf(t time.Time) Month { return Month{t.Year(), int(t.Month())} }

func (m Month) String() string { return fmt.Sprintf("%04d-%02d", m.Year, m.Month) }

// Index is a monotonically increasing month number, handy for arithmetic.
func (m Month) Index() int { return m.Year*12 + m.Month - 1 }

func (m Month) DaysIn() int {
	return time.Date(m.Year, time.Month(m.Month)+1, 0, 0, 0, 0, 0, time.UTC).Day()
}

type Goal struct {
	StartMonth    Month
	EndMonth      Month
	PlannedIncome int64
	SavingsTarget int64
	// IncomePlan is each member's expected monthly income by user id, with
	// OthersKey covering everyone not listed. Goals created before
	// per-member planning leave it empty: PlannedIncome is then spread
	// evenly over the period as a single household bucket.
	IncomePlan map[string]int64
}

// TotalMonths is the inclusive length of the goal period.
func (g Goal) TotalMonths() int { return g.EndMonth.Index() - g.StartMonth.Index() + 1 }

func (g Goal) Contains(m Month) bool {
	return m.Index() >= g.StartMonth.Index() && m.Index() <= g.EndMonth.Index()
}

type Entry struct {
	Owner  string
	Type   string
	Amount int64
	Date   string // YYYY-MM-DD
}

// Snapshot is the budget state of one month within a goal period.
type Snapshot struct {
	Month    string `json:"month"`
	InPeriod bool   `json:"in_period"`

	// ExpectedIncome is the period's income corrected by what actually
	// arrived (see expectedIncome).
	ExpectedIncome int64 `json:"expected_income"`
	// Budget is expected income minus savings target for the whole period.
	Budget int64 `json:"budget"`
	// SpentBefore is the expense total of period months before Month.
	SpentBefore int64 `json:"spent_before"`
	// MonthsLeft counts Month and every later period month.
	MonthsLeft int `json:"months_left"`

	MonthLimit     int64 `json:"month_limit"`
	MonthSpent     int64 `json:"month_spent"`
	MonthIncome    int64 `json:"month_income"`
	MonthRemaining int64 `json:"month_remaining"`
	UsedPercent    int   `json:"used_percent"`

	// Period totals include every period month up to and including Month.
	PeriodSpent   int64 `json:"period_spent"`
	PeriodIncome  int64 `json:"period_income"`
	Saved         int64 `json:"saved"`
	ToTarget      int64 `json:"to_target"`
	ExpectedSaved int64 `json:"expected_saved"`
	PeriodOver    bool  `json:"period_over"`

	DaysLeft       int   `json:"days_left"`
	DailyAllowance int64 `json:"daily_allowance"`
}

// Compute builds the snapshot for month, given all household entries
// (deleted ones already removed) and today's local date.
func Compute(g Goal, entries []Entry, month Month, today time.Time) Snapshot {
	s := Snapshot{
		Month:          month.String(),
		InPeriod:       g.Contains(month),
		ExpectedIncome: expectedIncome(g, entries, today),
	}
	s.Budget = s.ExpectedIncome - g.SavingsTarget

	for _, e := range entries {
		em, err := MonthOfDate(e.Date)
		if err != nil {
			continue
		}
		if em == month {
			if e.Type == TypeExpense {
				s.MonthSpent += e.Amount
			} else if e.Type == TypeIncome {
				s.MonthIncome += e.Amount
			}
		}
		if !g.Contains(em) || em.Index() > month.Index() {
			continue
		}
		switch e.Type {
		case TypeExpense:
			s.PeriodSpent += e.Amount
			if em.Index() < month.Index() {
				s.SpentBefore += e.Amount
			}
		case TypeIncome:
			s.PeriodIncome += e.Amount
		}
	}

	if s.InPeriod {
		s.MonthsLeft = g.EndMonth.Index() - month.Index() + 1
		if left := s.Budget - s.SpentBefore; left > 0 {
			s.MonthLimit = left / int64(s.MonthsLeft)
		}

		elapsed := int64(month.Index() - g.StartMonth.Index() + 1)
		s.ExpectedSaved = g.SavingsTarget * elapsed / int64(g.TotalMonths())
	}

	s.MonthRemaining = s.MonthLimit - s.MonthSpent
	switch {
	case s.MonthLimit > 0:
		s.UsedPercent = int(s.MonthSpent * 100 / s.MonthLimit)
	case s.MonthSpent > 0:
		s.UsedPercent = UsedPercentOverflow
	}

	s.Saved = s.PeriodIncome - s.PeriodSpent
	if s.ToTarget = g.SavingsTarget - s.Saved; s.ToTarget < 0 {
		s.ToTarget = 0
	}
	s.PeriodOver = s.InPeriod && s.PeriodSpent > max(s.Budget, 0)

	todayMonth := MonthOf(today)
	switch {
	case month == todayMonth:
		s.DaysLeft = month.DaysIn() - today.Day() + 1
	case month.Index() > todayMonth.Index():
		s.DaysLeft = month.DaysIn()
	}
	if s.MonthRemaining > 0 && s.DaysLeft > 0 {
		s.DailyAllowance = s.MonthRemaining / int64(s.DaysLeft)
	}

	return s
}

// plannedIncome is bucket's expected income in the k-th period month.
func plannedIncome(g Goal, bucket string, k int) int64 {
	if len(g.IncomePlan) == 0 {
		n := int64(g.TotalMonths())
		return g.PlannedIncome*int64(k+1)/n - g.PlannedIncome*int64(k)/n
	}
	return g.IncomePlan[bucket]
}

// incomeBucket maps an entry owner to its IncomePlan bucket.
func incomeBucket(g Goal, owner string) string {
	if _, ok := g.IncomePlan[owner]; ok {
		return owner
	}
	return OthersKey
}

// expectedIncome estimates the period's total income, member by member and
// month by month:
//   - later months count the plan;
//   - the current month, and the previous one during its grace period,
//     count what arrived but at least the plan, so income that is merely
//     not recorded yet never tightens the limit;
//   - settled months count what arrived, or the plan for a member who
//     recorded nothing at all that month (most likely forgot).
func expectedIncome(g Goal, entries []Entry, today time.Time) int64 {
	start, n := g.StartMonth.Index(), g.TotalMonths()
	buckets := []string{OthersKey}
	for b := range g.IncomePlan {
		if b != OthersKey {
			buckets = append(buckets, b)
		}
	}

	actual := make(map[string][]int64, len(buckets))
	for _, b := range buckets {
		actual[b] = make([]int64, n)
	}
	for _, e := range entries {
		if e.Type != TypeIncome {
			continue
		}
		em, err := MonthOfDate(e.Date)
		if err != nil || !g.Contains(em) {
			continue
		}
		actual[incomeBucket(g, e.Owner)][em.Index()-start] += e.Amount
	}

	todayIdx := MonthOf(today).Index()
	var total int64
	for k := range n {
		idx := start + k
		open := idx >= todayIdx || (idx == todayIdx-1 && today.Day() <= IncomeGraceDays)
		for _, b := range buckets {
			planned, got := plannedIncome(g, b, k), actual[b][k]
			switch {
			case idx > todayIdx:
				total += planned
			case open:
				total += max(got, planned)
			case got > 0:
				total += got
			default:
				total += planned
			}
		}
	}
	return total
}

// CrossedLevels returns the alert levels reached by s, in ascending severity.
func CrossedLevels(s Snapshot) []string {
	if !s.InPeriod {
		return nil
	}

	var levels []string
	monthLevels := []struct {
		level   string
		percent int64
	}{{LevelMonth80, 80}, {LevelMonth100, 100}, {LevelMonth120, 120}}
	for _, ml := range monthLevels {
		if s.MonthSpent > 0 && s.MonthSpent*100 >= ml.percent*s.MonthLimit {
			levels = append(levels, ml.level)
		}
	}
	if s.PeriodOver {
		levels = append(levels, LevelPeriodOver)
	}
	return levels
}
