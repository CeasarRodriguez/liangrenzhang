// Package push delivers alert notifications to devices that cannot keep a
// long-lived connection (HarmonyOS NEXT, via Huawei Push Kit).
package push

import (
	"context"
	"log/slog"
)

type Message struct {
	Title string
	Body  string
}

// Sender pushes one message to a set of device tokens.
type Sender interface {
	Send(ctx context.Context, tokens []string, msg Message) error
}

// Noop is used when no push credentials are configured.
type Noop struct{ Logger *slog.Logger }

func (n Noop) Send(_ context.Context, tokens []string, msg Message) error {
	if n.Logger != nil {
		n.Logger.Debug("push disabled, dropping message", "tokens", len(tokens), "title", msg.Title)
	}
	return nil
}
