package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		s := app.Settings()

		s.Meta.AppName = "两人账"
		s.Meta.HideControls = true

		// Caddy terminates TLS and forwards the client IP.
		s.TrustedProxy.Headers = []string{"X-Forwarded-For"}

		s.Batch.Enabled = false

		s.Backups.Cron = "30 3 * * *"
		s.Backups.CronMaxKeep = 14

		s.Logs.MaxDays = 14

		s.RateLimits.Enabled = true
		s.RateLimits.Rules = []core.RateLimitRule{
			{Label: "*:auth", MaxRequests: 5, Duration: 10},
			{Label: "users:create", MaxRequests: 3, Duration: 60},
			{Label: "/api/ledger/household/join", MaxRequests: 5, Duration: 60},
			{Label: "*:create", MaxRequests: 30, Duration: 5},
			{Label: "/api/", MaxRequests: 300, Duration: 10},
		}

		return app.Save(s)
	}, nil)
}
