// Package relay is the mailbox behind the app's relay mode: it passes
// end-to-end encrypted messages between the phones of one couple and keeps
// nothing it could read. Rooms and devices are random ids, message bodies
// are ciphertext, and each copy is deleted as soon as its recipient
// acknowledges it (undelivered ones expire after Config.DeliveryTTL).
package relay

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	// MaxBody caps one request body.
	MaxBody int64
	// MaxRoomBytes caps the undelivered ciphertext kept for one room.
	MaxRoomBytes int64
	// MaxItems caps the messages in one send request.
	MaxItems int
	// MaxDevices caps the devices registered in one room.
	MaxDevices int
	// MaxResponseBytes is where a receive response stops adding messages.
	MaxResponseBytes int

	// DeliveryTTL drops messages that were never picked up.
	DeliveryTTL time.Duration
	// DeviceIdle drops devices that have not shown up for this long.
	DeviceIdle time.Duration
	// EvictIdle: a full room makes space by dropping devices idle this long.
	EvictIdle time.Duration
	// RoomIdle drops rooms nobody used for this long.
	RoomIdle time.Duration

	// Rate (per second) and Burst limit requests per client IP.
	Rate  float64
	Burst float64
	// TrustProxy takes the client IP from X-Forwarded-For (set by Caddy).
	TrustProxy bool
	// KeepAlive is the interval of SSE comments that keep idle streams open.
	KeepAlive time.Duration

	Now func() time.Time
}

const day = 24 * time.Hour

func (c *Config) setDefaults() {
	if c.MaxBody <= 0 {
		c.MaxBody = 512 << 10
	}
	if c.MaxRoomBytes <= 0 {
		c.MaxRoomBytes = 20 << 20
	}
	if c.MaxItems <= 0 {
		c.MaxItems = 100
	}
	if c.MaxDevices <= 0 {
		c.MaxDevices = 4
	}
	if c.MaxResponseBytes <= 0 {
		c.MaxResponseBytes = 1 << 20
	}
	if c.DeliveryTTL <= 0 {
		c.DeliveryTTL = 30 * day
	}
	if c.DeviceIdle <= 0 {
		c.DeviceIdle = 60 * day
	}
	if c.EvictIdle <= 0 {
		c.EvictIdle = 30 * day
	}
	if c.RoomIdle <= 0 {
		c.RoomIdle = 180 * day
	}
	if c.Rate <= 0 {
		c.Rate = 10
	}
	if c.Burst <= 0 {
		c.Burst = 60
	}
	if c.KeepAlive <= 0 {
		c.KeepAlive = 25 * time.Second
	}
	if c.Now == nil {
		c.Now = time.Now
	}
}

type Server struct {
	cfg   Config
	db    *sql.DB
	mux   *http.ServeMux
	hub   *hub
	limit *limiter
}

func New(db *sql.DB, cfg Config) *Server {
	cfg.setDefaults()
	s := &Server{
		cfg:   cfg,
		db:    db,
		mux:   http.NewServeMux(),
		hub:   newHub(),
		limit: newLimiter(cfg.Rate, cfg.Burst),
	}
	s.mux.HandleFunc("GET /relay/health", s.health)
	s.mux.HandleFunc("POST /relay/v1/rooms/{room}/join", s.join)
	s.mux.HandleFunc("POST /relay/v1/rooms/{room}/messages", s.send)
	s.mux.HandleFunc("GET /relay/v1/rooms/{room}/messages", s.receive)
	s.mux.HandleFunc("POST /relay/v1/rooms/{room}/ack", s.ack)
	s.mux.HandleFunc("POST /relay/v1/rooms/{room}/leave", s.leave)
	s.mux.HandleFunc("GET /relay/v1/rooms/{room}/events", s.events)
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !s.limit.allow(s.clientIP(r), s.cfg.Now()) {
		writeError(w, errRateLimited)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxBody)
	s.mux.ServeHTTP(w, r)
}

// Cleanup drops expired messages, devices gone for good and unused rooms.
// Run it periodically.
func (s *Server) Cleanup(ctx context.Context) error {
	now := s.cfg.Now()
	steps := []struct {
		query string
		arg   int64
	}{
		{`DELETE FROM deliveries WHERE created < ?`, now.Add(-s.cfg.DeliveryTTL).Unix()},
		{`DELETE FROM devices WHERE last_seen < ?`, now.Add(-s.cfg.DeviceIdle).Unix()},
		{`DELETE FROM rooms WHERE last_seen < ? OR NOT EXISTS (SELECT 1 FROM devices d WHERE d.room = rooms.id)`,
			now.Add(-s.cfg.RoomIdle).Unix()},
	}
	for _, step := range steps {
		if _, err := s.db.ExecContext(ctx, step.query, step.arg); err != nil {
			return err
		}
	}
	s.limit.sweep(now)
	return nil
}

// ---------------------------------------------------------------------------
// errors

type apiError struct {
	status  int
	code    string
	message string
}

func (e *apiError) Error() string { return e.code }

var (
	errBadRequest   = &apiError{http.StatusBadRequest, "bad_request", "invalid request"}
	errUnauthorized = &apiError{http.StatusUnauthorized, "unauthorized", "wrong room key"}
	errNoRoom       = &apiError{http.StatusNotFound, "room_not_found", "no such room"}
	errNotJoined    = &apiError{http.StatusForbidden, "not_joined", "device has not joined this room"}
	errRoomFull     = &apiError{http.StatusConflict, "room_full", "too many devices in this room"}
	errTooLarge     = &apiError{http.StatusRequestEntityTooLarge, "too_large", "request too large"}
	errStorageFull  = &apiError{http.StatusInsufficientStorage, "storage_full", "too many undelivered messages"}
	errRateLimited  = &apiError{http.StatusTooManyRequests, "rate_limited", "too many requests"}
	errInternal     = &apiError{http.StatusInternalServerError, "internal", "internal error"}
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	var e *apiError
	if !errors.As(err, &e) {
		log.Printf("relay: %v", err)
		e = errInternal
	}
	writeJSON(w, e.status, map[string]string{"error": e.code, "message": e.message})
}

func decodeBody(r *http.Request, v any) error {
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return errTooLarge
		}
		return errBadRequest
	}
	return nil
}

// ---------------------------------------------------------------------------
// auth

// Room and device ids are 16 random bytes, room keys 32 random bytes, all
// base64url without padding.
var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{22}$`)

// querier is satisfied by both *sql.DB and *sql.Tx.
type querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func roomKeyHash(r *http.Request) ([]byte, error) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return nil, errUnauthorized
	}
	key, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(token))
	if err != nil || len(key) != 32 {
		return nil, errUnauthorized
	}
	sum := sha256.Sum256(key)
	return sum[:], nil
}

// authorize checks the room id and its key.
func authorize(ctx context.Context, q querier, r *http.Request) (string, error) {
	room := r.PathValue("room")
	if !idPattern.MatchString(room) {
		return "", errBadRequest
	}
	hash, err := roomKeyHash(r)
	if err != nil {
		return "", err
	}
	var stored []byte
	err = q.QueryRowContext(ctx, `SELECT auth_hash FROM rooms WHERE id = ?`, room).Scan(&stored)
	if errors.Is(err, sql.ErrNoRows) {
		return "", errNoRoom
	}
	if err != nil {
		return "", err
	}
	if subtle.ConstantTimeCompare(stored, hash) != 1 {
		return "", errUnauthorized
	}
	return room, nil
}

// member authorizes the request and checks that device joined the room,
// marking both as seen.
func (s *Server) member(ctx context.Context, q querier, r *http.Request, device string) (string, error) {
	if !idPattern.MatchString(device) {
		return "", errBadRequest
	}
	room, err := authorize(ctx, q, r)
	if err != nil {
		return "", err
	}
	now := s.cfg.Now().Unix()
	res, err := q.ExecContext(ctx, `UPDATE devices SET last_seen = ? WHERE room = ? AND device = ?`, now, room, device)
	if err != nil {
		return "", err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return "", errNotJoined
	}
	if _, err := q.ExecContext(ctx, `UPDATE rooms SET last_seen = ? WHERE id = ?`, now, room); err != nil {
		return "", err
	}
	return room, nil
}

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			// the last hop is the address our own proxy saw
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ---------------------------------------------------------------------------
// handlers

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": "liangrenzhang-relay"})
}

func (s *Server) join(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Device string `json:"device"`
		Create bool   `json:"create"`
	}
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	if !idPattern.MatchString(req.Device) {
		writeError(w, errBadRequest)
		return
	}
	ctx := r.Context()
	var created, joined bool
	var peers int
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		now := s.cfg.Now()
		room, err := authorize(ctx, tx, r)
		if errors.Is(err, errNoRoom) && req.Create {
			hash, err := roomKeyHash(r)
			if err != nil {
				return err
			}
			room = r.PathValue("room")
			if _, err := tx.ExecContext(ctx, `INSERT INTO rooms (id, auth_hash, created, last_seen) VALUES (?, ?, ?, ?)`,
				room, hash, now.Unix(), now.Unix()); err != nil {
				return err
			}
			created = true
		} else if err != nil {
			return err
		}

		var exists bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM devices WHERE room = ? AND device = ?)`,
			room, req.Device).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			if _, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE room = ? AND last_seen < ?`,
				room, now.Add(-s.cfg.EvictIdle).Unix()); err != nil {
				return err
			}
			var count int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE room = ?`, room).Scan(&count); err != nil {
				return err
			}
			if count >= s.cfg.MaxDevices {
				return errRoomFull
			}
			if _, err := tx.ExecContext(ctx, `INSERT INTO devices (room, device, created, last_seen) VALUES (?, ?, ?, ?)`,
				room, req.Device, now.Unix(), now.Unix()); err != nil {
				return err
			}
			joined = true
		}
		if _, err := s.member(ctx, tx, r, req.Device); err != nil {
			return err
		}
		return tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE room = ? AND device != ?`,
			room, req.Device).Scan(&peers)
	})
	if err != nil {
		writeError(w, err)
		return
	}
	// joined: the device was not registered (new, or dropped after a long
	// absence), so it has missed messages and should ask for everything
	writeJSON(w, http.StatusOK, map[string]any{"created": created, "joined": joined, "peers": peers})
}

func (s *Server) send(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Device string   `json:"device"`
		Items  []string `json:"items"`
	}
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	if len(req.Items) == 0 || len(req.Items) > s.cfg.MaxItems {
		writeError(w, errBadRequest)
		return
	}
	bodies := make([][]byte, len(req.Items))
	size := 0
	for i, item := range req.Items {
		b, err := base64.StdEncoding.DecodeString(item)
		if err != nil || len(b) == 0 {
			writeError(w, errBadRequest)
			return
		}
		bodies[i] = b
		size += len(b)
	}

	ctx := r.Context()
	var room string
	var recipients []string
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		var err error
		room, err = s.member(ctx, tx, r, req.Device)
		if err != nil {
			return err
		}
		rows, err := tx.QueryContext(ctx, `SELECT device FROM devices WHERE room = ? AND device != ?`, room, req.Device)
		if err != nil {
			return err
		}
		for rows.Next() {
			var d string
			if err := rows.Scan(&d); err != nil {
				rows.Close()
				return err
			}
			recipients = append(recipients, d)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		// nobody else here yet: a device that joins later asks its partner
		// for everything, so there is nothing worth keeping
		if len(recipients) == 0 {
			return nil
		}

		var pending int64
		if err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(LENGTH(body)), 0) FROM deliveries WHERE room = ?`,
			room).Scan(&pending); err != nil {
			return err
		}
		if pending+int64(size*len(recipients)) > s.cfg.MaxRoomBytes {
			return errStorageFull
		}
		now := s.cfg.Now().Unix()
		for _, body := range bodies {
			for _, to := range recipients {
				if _, err := tx.ExecContext(ctx,
					`INSERT INTO deliveries (room, recipient, sender, body, created) VALUES (?, ?, ?, ?, ?)`,
					room, to, req.Device, body, now); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		writeError(w, err)
		return
	}
	for _, to := range recipients {
		s.hub.notify(room, to)
	}
	writeJSON(w, http.StatusOK, map[string]any{"recipients": len(recipients)})
}

type delivery struct {
	Seq  int64  `json:"seq"`
	From string `json:"from"`
	Data string `json:"data"`
}

func (s *Server) receive(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	device := q.Get("device")
	after, _ := strconv.ParseInt(q.Get("after"), 10, 64)
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}

	ctx := r.Context()
	items := []delivery{}
	more := false
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		room, err := s.member(ctx, tx, r, device)
		if err != nil {
			return err
		}
		rows, err := tx.QueryContext(ctx,
			`SELECT seq, sender, body FROM deliveries WHERE room = ? AND recipient = ? AND seq > ? ORDER BY seq LIMIT ?`,
			room, device, after, limit+1)
		if err != nil {
			return err
		}
		defer rows.Close()
		size := 0
		for rows.Next() {
			var d delivery
			var body []byte
			if err := rows.Scan(&d.Seq, &d.From, &body); err != nil {
				return err
			}
			if len(items) == limit || (len(items) > 0 && size+len(body) > s.cfg.MaxResponseBytes) {
				more = true
				break
			}
			d.Data = base64.StdEncoding.EncodeToString(body)
			size += len(body)
			items = append(items, d)
		}
		return rows.Err()
	})
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "more": more})
}

func (s *Server) ack(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Device string `json:"device"`
		Seq    int64  `json:"seq"`
	}
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	ctx := r.Context()
	var deleted int64
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		room, err := s.member(ctx, tx, r, req.Device)
		if err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx, `DELETE FROM deliveries WHERE room = ? AND recipient = ? AND seq <= ?`,
			room, req.Device, req.Seq)
		if err != nil {
			return err
		}
		deleted, _ = res.RowsAffected()
		return nil
	})
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": deleted})
}

func (s *Server) leave(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Device string `json:"device"`
	}
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	ctx := r.Context()
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		room, err := s.member(ctx, tx, r, req.Device)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE room = ? AND device = ?`, room, req.Device); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx,
			`DELETE FROM rooms WHERE id = ? AND NOT EXISTS (SELECT 1 FROM devices WHERE room = ?)`, room, room)
		return err
	})
	if err != nil && !errors.Is(err, errNotJoined) && !errors.Is(err, errNoRoom) {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{})
}

// events is a server-sent event stream that says "message" whenever
// something new arrives for the device. It carries no content: the app
// fetches and decrypts the messages itself.
func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	device := r.URL.Query().Get("device")
	ctx := r.Context()
	var room string
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		var err error
		room, err = s.member(ctx, tx, r, device)
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}

	ch, unsubscribe := s.hub.subscribe(room, device)
	defer unsubscribe()

	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	write := func(s string) bool {
		if _, err := fmt.Fprint(w, s); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	if !write("retry: 10000\n\nevent: ready\ndata: {}\n\n") {
		return
	}

	ticker := time.NewTicker(s.cfg.KeepAlive)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ch:
			if !write("event: message\ndata: {}\n\n") {
				return
			}
		case <-ticker.C:
			if !write(": keepalive\n\n") {
				return
			}
		}
	}
}

func (s *Server) inTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}
