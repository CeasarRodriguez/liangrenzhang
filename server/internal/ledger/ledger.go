// Package ledger wires the couple-ledger business rules into PocketBase:
// household pairing, privacy guards, validation and budget alerts.
package ledger

import (
	"math/rand/v2"
	"sync"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"couple-ledger/server/internal/push"
)

type Config struct {
	// Location is the couple's timezone, used to decide "this month".
	Location *time.Location
	// MaxUsers caps the number of accounts this server accepts.
	MaxUsers int
	Pusher   push.Sender

	// Now and Intn are overridable for tests.
	Now  func() time.Time
	Intn func(n int) int
}

type ledger struct {
	cfg Config

	// mu serializes household membership changes and alert evaluation;
	// the whole server serves a single couple, so contention is negligible.
	mu sync.Mutex
}

func Register(app core.App, cfg Config) {
	if cfg.Location == nil {
		cfg.Location = time.Local
	}
	if cfg.MaxUsers <= 0 {
		cfg.MaxUsers = 2
	}
	if cfg.Pusher == nil {
		cfg.Pusher = push.Noop{Logger: app.Logger()}
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Intn == nil {
		cfg.Intn = rand.IntN
	}

	l := &ledger{cfg: cfg}

	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.BindFunc(privacyGuard)

		g := se.Router.Group("/api/ledger")
		g.Bind(apis.RequireAuth("users"))
		g.POST("/household", l.createHousehold)
		g.POST("/household/join", l.joinHousehold)

		return se.Next()
	})
	app.OnRealtimeSubscribeRequest().BindFunc(guardSubscriptions)

	app.OnRecordCreateRequest("users").BindFunc(l.limitSignups)
	app.OnRecordValidate("entries").BindFunc(validateEntry)
	app.OnRecordValidate("goals").BindFunc(validateGoal)
	app.OnRecordCreate("devices").BindFunc(dedupeDeviceToken)
	app.OnRecordUpdate("devices").BindFunc(dedupeDeviceToken)

	app.OnRecordAfterCreateSuccess("entries", "goals").BindFunc(l.onBudgetChange)
	app.OnRecordAfterUpdateSuccess("entries", "goals").BindFunc(l.onBudgetChange)
}
