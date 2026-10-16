// Command relay serves the app's relay mode: a mailbox that forwards end-to-end
// encrypted messages between two phones and keeps nothing it could read.
package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"couple-ledger/server/internal/relay"
)

func main() {
	addr := env("RELAY_ADDR", "0.0.0.0:8091")
	dir := env("RELAY_DIR", "relay_data")
	trustProxy, err := strconv.ParseBool(env("RELAY_TRUST_PROXY", "true"))
	if err != nil {
		log.Fatalf("invalid RELAY_TRUST_PROXY: %v", err)
	}

	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Fatal(err)
	}
	db, err := relay.OpenDB(filepath.Join(dir, "relay.db"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	srv := relay.New(db, relay.Config{TrustProxy: trustProxy})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		ticker := time.NewTicker(time.Hour)
		defer ticker.Stop()
		for {
			if err := srv.Cleanup(ctx); err != nil && ctx.Err() == nil {
				log.Printf("relay cleanup: %v", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
		// no WriteTimeout: event streams stay open until shutdown ends them
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdown)
	}()

	log.Printf("relay listening on %s", addr)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
