package main

import (
	"log"
	"os"
	"strconv"
	"time"
	_ "time/tzdata" // the runtime image has no zoneinfo

	"github.com/pocketbase/pocketbase"

	"couple-ledger/server/internal/ledger"
	"couple-ledger/server/internal/push"
	_ "couple-ledger/server/migrations"
)

func main() {
	app := pocketbase.New()

	loc, err := time.LoadLocation(env("LEDGER_TZ", "Asia/Shanghai"))
	if err != nil {
		log.Fatalf("invalid LEDGER_TZ: %v", err)
	}
	maxUsers, err := strconv.Atoi(env("LEDGER_MAX_USERS", "2"))
	if err != nil {
		log.Fatalf("invalid LEDGER_MAX_USERS: %v", err)
	}

	cfg := ledger.Config{Location: loc, MaxUsers: maxUsers}

	if projectID := os.Getenv("HUAWEI_PROJECT_ID"); projectID != "" {
		testMessage, _ := strconv.ParseBool(env("HUAWEI_PUSH_TEST_MESSAGE", "true"))
		sender, err := push.NewHuawei(push.HuaweiConfig{
			ProjectID:          projectID,
			ServiceAccountFile: os.Getenv("HUAWEI_SERVICE_ACCOUNT_FILE"),
			ClientID:           os.Getenv("HUAWEI_CLIENT_ID"),
			ClientSecret:       os.Getenv("HUAWEI_CLIENT_SECRET"),
			Category:           env("HUAWEI_PUSH_CATEGORY", "MARKETING"),
			TestMessage:        testMessage,
		})
		if err != nil {
			log.Fatalf("huawei push config: %v", err)
		}
		cfg.Pusher = sender
	}

	ledger.Register(app, cfg)

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
