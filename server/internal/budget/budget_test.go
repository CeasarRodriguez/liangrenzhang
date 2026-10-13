package budget

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

type fixtureFile struct {
	Cases []struct {
		Name string `json:"name"`
		Goal struct {
			StartMonth    string `json:"start_month"`
			EndMonth      string `json:"end_month"`
			PlannedIncome int64  `json:"planned_income"`
			SavingsTarget int64  `json:"savings_target"`
		} `json:"goal"`
		Entries []struct {
			Type   string `json:"type"`
			Amount int64  `json:"amount"`
			Date   string `json:"date"`
		} `json:"entries"`
		Month  string   `json:"month"`
		Today  string   `json:"today"`
		Expect Snapshot `json:"expect"`
		Levels []string `json:"levels"`
	} `json:"cases"`
}

func mustMonth(t *testing.T, s string) Month {
	t.Helper()
	m, err := ParseMonth(s)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestSharedFixtures(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "budget_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f fixtureFile
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) == 0 {
		t.Fatal("no fixture cases")
	}

	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			g := Goal{
				StartMonth:    mustMonth(t, c.Goal.StartMonth),
				EndMonth:      mustMonth(t, c.Goal.EndMonth),
				PlannedIncome: c.Goal.PlannedIncome,
				SavingsTarget: c.Goal.SavingsTarget,
			}
			entries := make([]Entry, len(c.Entries))
			for i, e := range c.Entries {
				entries[i] = Entry{Type: e.Type, Amount: e.Amount, Date: e.Date}
			}
			today, err := time.Parse("2006-01-02", c.Today)
			if err != nil {
				t.Fatal(err)
			}

			got := Compute(g, entries, mustMonth(t, c.Month), today)
			if got != c.Expect {
				t.Errorf("snapshot mismatch\n got: %+v\nwant: %+v", got, c.Expect)
			}

			levels := CrossedLevels(got)
			if len(levels) == 0 && len(c.Levels) == 0 {
				return
			}
			if !reflect.DeepEqual(levels, c.Levels) {
				t.Errorf("levels = %v, want %v", levels, c.Levels)
			}
		})
	}
}

func TestParseMonth(t *testing.T) {
	for _, bad := range []string{"", "2026", "2026-13", "2026-00", "26-01-01", "2026/01"} {
		if _, err := ParseMonth(bad); err == nil {
			t.Errorf("ParseMonth(%q) expected error", bad)
		}
	}
	m, err := ParseMonth("2026-02")
	if err != nil || m.DaysIn() != 28 || m.String() != "2026-02" {
		t.Errorf("unexpected %v %v", m, err)
	}
}
