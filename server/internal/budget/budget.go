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
}

// TotalMonths is the inclusive length of the goal period.
func (g Goal) TotalMonths() int { return g.EndMonth.Index() - g.StartMonth.Index() + 1 }

func (g Goal) Contains(m Month) bool {
	return m.Index() >= g.StartMonth.Index() && m.Index() <= g.EndMonth.Index()
}

type Entry struct {
	Type   string
	Amount int64
	Date   string // YYYY-MM-DD
}

// Snapshot is the budget state of one month within a goal period.
type Snapshot struct {
	Month    string `json:"month"`
	InPeriod bool   `json:"in_period"`

	// Budget is planned income minus savings target for the whole period.
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
		Month:    month.String(),
		InPeriod: g.Contains(month),
		Budget:   g.PlannedIncome - g.SavingsTarget,
	}

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
