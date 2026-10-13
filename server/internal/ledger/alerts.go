package ledger

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"couple-ledger/server/internal/alertcopy"
	"couple-ledger/server/internal/budget"
	"couple-ledger/server/internal/push"
)

func (l *ledger) onBudgetChange(e *core.RecordEvent) error {
	if err := l.evaluate(e.App, e.Record.GetString("household")); err != nil {
		e.App.Logger().Error("budget alert evaluation failed",
			"household", e.Record.GetString("household"), "error", err)
	}
	return e.Next()
}

// evaluate checks the household's current month against its goal and
// creates (and pushes) every alert level that was newly crossed.
func (l *ledger) evaluate(app core.App, householdId string) error {
	if householdId == "" {
		return nil
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.cfg.Now().In(l.cfg.Location)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	month := budget.MonthOf(today)

	goalRec, err := app.FindFirstRecordByFilter("goals",
		"household = {:h} && start_month <= {:m} && end_month >= {:m}",
		dbx.Params{"h": householdId, "m": month.String()},
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	goal, err := goalFromRecord(goalRec)
	if err != nil {
		return err
	}

	entryRecs, err := app.FindRecordsByFilter("entries",
		"household = {:h} && deleted = false && occurred_on >= {:from} && occurred_on <= {:to}",
		"", 0, 0,
		dbx.Params{"h": householdId, "from": goal.StartMonth.String() + "-01", "to": month.String() + "-31"},
	)
	if err != nil {
		return err
	}
	entries := make([]budget.Entry, len(entryRecs))
	for i, r := range entryRecs {
		entries[i] = budget.Entry{
			Type:   r.GetString("type"),
			Amount: r.GetInt64("amount"),
			Date:   r.GetString("occurred_on"),
		}
	}

	snap := budget.Compute(goal, entries, month, today)
	periodKey := func(level string) string {
		if level == budget.LevelPeriodOver {
			return "goal:" + goalRec.Id
		}
		return month.String()
	}

	var newLevels []string
	for _, level := range budget.CrossedLevels(snap) {
		n, err := app.CountRecords("alerts", dbx.HashExp{
			"household": householdId, "kind": level, "period_key": periodKey(level),
		})
		if err != nil {
			return err
		}
		if n == 0 {
			newLevels = append(newLevels, level)
		}
	}
	if len(newLevels) == 0 {
		return nil
	}

	members, err := app.FindAllRecords("users", dbx.HashExp{"household": householdId})
	if err != nil {
		return err
	}

	// Only the most severe new level is announced; lower ones crossed at
	// the same time are recorded as already read so they never fire later.
	top := newLevels[len(newLevels)-1]
	var topTitle, topBody string

	err = app.RunInTransaction(func(tx core.App) error {
		col, err := tx.FindCollectionByNameOrId("alerts")
		if err != nil {
			return err
		}
		for _, level := range newLevels {
			title := alertcopy.Titles[level]
			body := alertcopy.Render(l.pickMessage(tx, householdId, level), snap, goal.SavingsTarget)
			if level == top {
				topTitle, topBody = title, body
			}
			for _, m := range members {
				r := core.NewRecord(col)
				r.Set("household", householdId)
				r.Set("recipient", m.Id)
				r.Set("kind", level)
				r.Set("period_key", periodKey(level))
				r.Set("title", title)
				r.Set("body", body)
				r.Set("read", level != top)
				if err := tx.Save(r); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return err
	}

	l.pushToHarmony(app, members, push.Message{Title: topTitle, Body: topBody})
	return nil
}

func goalFromRecord(r *core.Record) (budget.Goal, error) {
	start, err := budget.ParseMonth(r.GetString("start_month"))
	if err != nil {
		return budget.Goal{}, err
	}
	end, err := budget.ParseMonth(r.GetString("end_month"))
	if err != nil {
		return budget.Goal{}, err
	}
	return budget.Goal{
		StartMonth:    start,
		EndMonth:      end,
		PlannedIncome: r.GetInt64("planned_income"),
		SavingsTarget: r.GetInt64("savings_target"),
	}, nil
}

func (l *ledger) pickMessage(app core.App, householdId, level string) string {
	msgs, err := app.FindAllRecords("alert_messages", dbx.HashExp{
		"household": householdId, "level": level, "enabled": true,
	})
	if err != nil || len(msgs) == 0 {
		return alertcopy.Fallback[level]
	}
	return msgs[l.cfg.Intn(len(msgs))].GetString("text")
}

// pushToHarmony notifies HarmonyOS devices; Android devices receive the
// alert through their realtime subscription instead.
func (l *ledger) pushToHarmony(app core.App, members []*core.Record, msg push.Message) {
	ids := make([]any, len(members))
	for i, m := range members {
		ids[i] = m.Id
	}
	devices, err := app.FindAllRecords("devices",
		dbx.In("user", ids...),
		dbx.HashExp{"platform": "harmony"},
		dbx.NewExp("push_token != ''"),
	)
	if err != nil {
		app.Logger().Error("load push devices failed", "error", err)
		return
	}
	tokens := make([]string, 0, len(devices))
	for _, d := range devices {
		tokens = append(tokens, d.GetString("push_token"))
	}
	if len(tokens) == 0 {
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := l.cfg.Pusher.Send(ctx, tokens, msg); err != nil {
			app.Logger().Warn("harmony push failed", "error", err)
		}
	}()
}
