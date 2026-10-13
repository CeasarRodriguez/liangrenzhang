package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

const (
	usersCollectionId = "_pb_users_auth_"

	monthPattern = `^\d{4}-(0[1-9]|1[0-2])$`
	datePattern  = `^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$`
)

// unchanged returns a rule fragment that accepts a request body only if it
// does not modify field (either absent or equal to the stored value).
func unchanged(field string) string {
	return "(@request.body." + field + ":isset = false || @request.body." + field + " = " + field + ")"
}

func init() {
	m.Register(func(app core.App) error {
		// ---------------------------------------------------------------
		// households
		// ---------------------------------------------------------------
		households := core.NewBaseCollection("households")
		households.ListRule = types.Pointer("id = @request.auth.household")
		households.ViewRule = types.Pointer("id = @request.auth.household")
		// created and joined only through /api/ledger/household routes
		households.UpdateRule = types.Pointer("id = @request.auth.household && " +
			unchanged("invite_code") + " && " + unchanged("created_by"))
		households.Fields.Add(
			&core.TextField{Name: "name", Required: true, Max: 30},
			&core.TextField{Name: "invite_code", Required: true, Min: 6, Max: 6, Pattern: `^\d{6}$`},
			&core.RelationField{Name: "created_by", CollectionId: usersCollectionId, MaxSelect: 1},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		households.AddIndex("idx_households_invite_code", true, "invite_code", "")
		if err := app.Save(households); err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// users: username login + household membership
		// ---------------------------------------------------------------
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		users.ListRule = types.Pointer("id = @request.auth.id || (household != '' && household = @request.auth.household)")
		users.ViewRule = users.ListRule
		users.CreateRule = types.Pointer("@request.body.household:isset = false")
		users.UpdateRule = types.Pointer("id = @request.auth.id && " + unchanged("household"))
		users.DeleteRule = nil
		if email, ok := users.Fields.GetByName("email").(*core.EmailField); ok {
			email.Required = false
		}
		users.Fields.Add(
			// lowercase only, so the plain unique index is effectively case-insensitive
			&core.TextField{Name: "username", Required: true, Min: 3, Max: 20, Pattern: `^[a-z0-9_]+$`},
			&core.RelationField{Name: "household", CollectionId: households.Id, MaxSelect: 1},
			&core.TextField{Name: "color", Max: 9, Pattern: `^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$`},
		)
		users.AddIndex("idx_users_username", true, "username", "")
		users.PasswordAuth.IdentityFields = []string{"username"}
		users.AuthToken.Duration = 90 * 24 * 3600
		if err := app.Save(users); err != nil {
			return err
		}

		member := "@request.auth.id != '' && household = @request.auth.household"

		// ---------------------------------------------------------------
		// entries: public part of every income/expense record
		// ---------------------------------------------------------------
		entries := core.NewBaseCollection("entries")
		entries.ListRule = types.Pointer(member)
		entries.ViewRule = types.Pointer(member)
		entries.CreateRule = types.Pointer(member + " && owner = @request.auth.id")
		entries.UpdateRule = types.Pointer(member + " && owner = @request.auth.id && " +
			unchanged("owner") + " && " + unchanged("household"))
		entries.DeleteRule = nil // soft delete via the "deleted" flag so other devices can sync it
		entries.Fields.Add(
			&core.RelationField{Name: "household", CollectionId: households.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.RelationField{Name: "owner", CollectionId: usersCollectionId, MaxSelect: 1, Required: true},
			&core.SelectField{Name: "type", Values: []string{"income", "expense"}, MaxSelect: 1, Required: true},
			&core.NumberField{Name: "amount", OnlyInt: true, Min: types.Pointer(1.0), Max: types.Pointer(100_000_000_000.0), Required: true},
			&core.TextField{Name: "category", Required: true, Max: 20},
			&core.TextField{Name: "occurred_on", Required: true, Pattern: datePattern},
			&core.BoolField{Name: "deleted"},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		entries.AddIndex("idx_entries_household_date", false, "household, occurred_on", "")
		entries.AddIndex("idx_entries_household_updated", false, "household, updated", "")
		if err := app.Save(entries); err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// entry_details: private note, readable only by its owner
		// ---------------------------------------------------------------
		details := core.NewBaseCollection("entry_details")
		owner := "@request.auth.id != '' && owner = @request.auth.id"
		details.ListRule = types.Pointer(owner)
		details.ViewRule = types.Pointer(owner)
		details.CreateRule = types.Pointer(owner + " && entry.owner = @request.auth.id")
		details.UpdateRule = types.Pointer(owner + " && " + unchanged("owner") + " && " + unchanged("entry"))
		details.DeleteRule = types.Pointer(owner)
		details.Fields.Add(
			&core.RelationField{Name: "entry", CollectionId: entries.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.RelationField{Name: "owner", CollectionId: usersCollectionId, MaxSelect: 1, Required: true},
			&core.TextField{Name: "note", Max: 200},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		details.AddIndex("idx_entry_details_entry", true, "entry", "")
		details.AddIndex("idx_entry_details_owner_updated", false, "owner, updated", "")
		if err := app.Save(details); err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// goals: savings goal for a month range
		// ---------------------------------------------------------------
		goals := core.NewBaseCollection("goals")
		goals.ListRule = types.Pointer(member)
		goals.ViewRule = types.Pointer(member)
		goals.CreateRule = types.Pointer(member)
		goals.UpdateRule = types.Pointer(member + " && " + unchanged("household"))
		goals.DeleteRule = types.Pointer(member)
		goals.Fields.Add(
			&core.RelationField{Name: "household", CollectionId: households.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.TextField{Name: "start_month", Required: true, Pattern: monthPattern},
			&core.TextField{Name: "end_month", Required: true, Pattern: monthPattern},
			&core.NumberField{Name: "planned_income", OnlyInt: true, Min: types.Pointer(0.0), Max: types.Pointer(100_000_000_000.0)},
			&core.NumberField{Name: "savings_target", OnlyInt: true, Min: types.Pointer(0.0), Max: types.Pointer(100_000_000_000.0)},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		goals.AddIndex("idx_goals_household", false, "household, start_month", "")
		if err := app.Save(goals); err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// alert_messages: customizable friendly-reminder copy
		// ---------------------------------------------------------------
		levels := []string{"month_80", "month_100", "month_120", "period_over"}
		messages := core.NewBaseCollection("alert_messages")
		messages.ListRule = types.Pointer(member)
		messages.ViewRule = types.Pointer(member)
		messages.CreateRule = types.Pointer(member + " && created_by = @request.auth.id && " +
			"(@request.body.is_default:isset = false || @request.body.is_default = false)")
		messages.UpdateRule = types.Pointer(member + " && " + unchanged("household") + " && " +
			unchanged("is_default") + " && " + unchanged("created_by") + " && " +
			"(is_default = false || (" + unchanged("text") + " && " + unchanged("level") + "))")
		messages.DeleteRule = types.Pointer(member + " && is_default = false")
		messages.Fields.Add(
			&core.RelationField{Name: "household", CollectionId: households.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.SelectField{Name: "level", Values: levels, MaxSelect: 1, Required: true},
			&core.TextField{Name: "text", Required: true, Max: 200},
			&core.BoolField{Name: "is_default"},
			&core.BoolField{Name: "enabled"},
			&core.RelationField{Name: "created_by", CollectionId: usersCollectionId, MaxSelect: 1},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		messages.AddIndex("idx_alert_messages_household_level", false, "household, level", "")
		if err := app.Save(messages); err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// alerts: delivered reminders (one per recipient), server-created only
		// ---------------------------------------------------------------
		alerts := core.NewBaseCollection("alerts")
		recipient := "@request.auth.id != '' && recipient = @request.auth.id"
		alerts.ListRule = types.Pointer(recipient)
		alerts.ViewRule = types.Pointer(recipient)
		alerts.UpdateRule = types.Pointer(recipient + " && " + unchanged("household") + " && " +
			unchanged("recipient") + " && " + unchanged("kind") + " && " + unchanged("period_key") + " && " +
			unchanged("title") + " && " + unchanged("body"))
		alerts.Fields.Add(
			&core.RelationField{Name: "household", CollectionId: households.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.RelationField{Name: "recipient", CollectionId: usersCollectionId, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.SelectField{Name: "kind", Values: levels, MaxSelect: 1, Required: true},
			&core.TextField{Name: "period_key", Required: true, Max: 40},
			&core.TextField{Name: "title", Max: 60},
			&core.TextField{Name: "body", Max: 400},
			&core.BoolField{Name: "read"},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		alerts.AddIndex("idx_alerts_unique", true, "recipient, kind, period_key", "")
		if err := app.Save(alerts); err != nil {
			return err
		}

		// ---------------------------------------------------------------
		// devices: push tokens (HarmonyOS Push Kit)
		// ---------------------------------------------------------------
		devices := core.NewBaseCollection("devices")
		self := "@request.auth.id != '' && user = @request.auth.id"
		devices.ListRule = types.Pointer(self)
		devices.ViewRule = types.Pointer(self)
		devices.CreateRule = types.Pointer(self)
		devices.UpdateRule = types.Pointer(self + " && " + unchanged("user"))
		devices.DeleteRule = types.Pointer(self)
		devices.Fields.Add(
			&core.RelationField{Name: "user", CollectionId: usersCollectionId, MaxSelect: 1, Required: true, CascadeDelete: true},
			&core.SelectField{Name: "platform", Values: []string{"android", "harmony"}, MaxSelect: 1, Required: true},
			&core.TextField{Name: "push_token", Max: 512},
			&core.TextField{Name: "app_version", Max: 30},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		devices.AddIndex("idx_devices_push_token", true, "push_token", "push_token != ''")
		return app.Save(devices)
	}, func(app core.App) error {
		for _, name := range []string{"devices", "alerts", "alert_messages", "goals", "entry_details", "entries"} {
			c, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			if err := app.Delete(c); err != nil {
				return err
			}
		}

		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		users.Fields.RemoveByName("username")
		users.Fields.RemoveByName("household")
		users.Fields.RemoveByName("color")
		users.RemoveIndex("idx_users_username")
		users.PasswordAuth.IdentityFields = []string{"email"}
		if err := app.Save(users); err != nil {
			return err
		}

		if c, err := app.FindCollectionByNameOrId("households"); err == nil {
			return app.Delete(c)
		}
		return nil
	})
}
