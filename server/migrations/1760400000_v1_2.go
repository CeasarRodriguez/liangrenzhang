package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// v1.2: purchase reservations (pre-deducted expenses with a public item
// name) and per-member expected income on goals.
func init() {
	m.Register(func(app core.App) error {
		entries, err := app.FindCollectionByNameOrId("entries")
		if err != nil {
			return err
		}
		entries.Fields.Add(
			// counted as spent already, but not bought yet
			&core.BoolField{Name: "reserved"},
			// item name of a reservation, visible to both partners
			&core.TextField{Name: "title", Max: 30},
		)
		if err := app.Save(entries); err != nil {
			return err
		}

		goals, err := app.FindCollectionByNameOrId("goals")
		if err != nil {
			return err
		}
		// {"<user id>" | "*": expected monthly income in cents}
		goals.Fields.Add(&core.JSONField{Name: "income_plan", MaxSize: 1024})
		return app.Save(goals)
	}, func(app core.App) error {
		if entries, err := app.FindCollectionByNameOrId("entries"); err == nil {
			entries.Fields.RemoveByName("reserved")
			entries.Fields.RemoveByName("title")
			if err := app.Save(entries); err != nil {
				return err
			}
		}
		if goals, err := app.FindCollectionByNameOrId("goals"); err == nil {
			goals.Fields.RemoveByName("income_plan")
			return app.Save(goals)
		}
		return nil
	})
}
