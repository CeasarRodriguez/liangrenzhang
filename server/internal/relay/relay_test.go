package relay

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fixture struct {
	t   *testing.T
	db  *sql.DB
	srv *Server
	now time.Time
}

func newFixture(t *testing.T, cfg Config) *fixture {
	t.Helper()
	db, err := OpenDB(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	f := &fixture{t: t, db: db, now: time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)}
	cfg.Now = func() time.Time { return f.now }
	f.srv = New(db, cfg)
	return f
}

func randomID(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

type room struct{ id, key string }

func newRoom() room { return room{id: randomID(16), key: randomID(32)} }

// do sends a request and decodes the JSON response.
func (f *fixture) do(method, path, key string, body any) (int, map[string]any) {
	f.t.Helper()
	var reader *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	rec := httptest.NewRecorder()
	f.srv.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func (f *fixture) join(r room, device string, create bool) (int, map[string]any) {
	return f.do("POST", "/relay/v1/rooms/"+r.id+"/join", r.key, map[string]any{"device": device, "create": create})
}

func (f *fixture) send(r room, device string, items ...string) (int, map[string]any) {
	enc := make([]string, len(items))
	for i, it := range items {
		enc[i] = base64.StdEncoding.EncodeToString([]byte(it))
	}
	return f.do("POST", "/relay/v1/rooms/"+r.id+"/messages", r.key, map[string]any{"device": device, "items": enc})
}

func (f *fixture) receive(r room, device string, after int64) []delivery {
	f.t.Helper()
	req := httptest.NewRequest("GET", "/relay/v1/rooms/"+r.id+"/messages?device="+device+"&after="+itoa(after), nil)
	req.Header.Set("Authorization", "Bearer "+r.key)
	rec := httptest.NewRecorder()
	f.srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		f.t.Fatalf("receive: %d %s", rec.Code, rec.Body)
	}
	var out struct{ Items []delivery }
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		f.t.Fatal(err)
	}
	return out.Items
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }

func (f *fixture) count(query string, args ...any) int {
	f.t.Helper()
	var n int
	if err := f.db.QueryRow(query, args...).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	return n
}

func decoded(d delivery) string {
	b, _ := base64.StdEncoding.DecodeString(d.Data)
	return string(b)
}

func TestJoinAndAuth(t *testing.T) {
	f := newFixture(t, Config{})
	r := newRoom()
	a, b := randomID(16), randomID(16)

	// a mistyped pairing code must not silently open an empty room
	if code, out := f.join(r, b, false); code != http.StatusNotFound || out["error"] != "room_not_found" {
		t.Fatalf("join missing room: %d %v", code, out)
	}
	if code, out := f.join(r, a, true); code != http.StatusOK || out["created"] != true || out["joined"] != true ||
		out["peers"] != 0.0 {
		t.Fatalf("create room: %d %v", code, out)
	}
	if code, out := f.join(r, b, false); code != http.StatusOK || out["created"] != false || out["peers"] != 1.0 {
		t.Fatalf("join room: %d %v", code, out)
	}
	// joining again is harmless
	if code, out := f.join(r, b, true); code != http.StatusOK || out["created"] != false || out["joined"] != false {
		t.Fatalf("rejoin: %d %v", code, out)
	}

	wrong := room{id: r.id, key: randomID(32)}
	if code, _ := f.join(wrong, randomID(16), true); code != http.StatusUnauthorized {
		t.Fatalf("wrong key join: %d", code)
	}
	if code, _ := f.send(wrong, a, "x"); code != http.StatusUnauthorized {
		t.Fatalf("wrong key send: %d", code)
	}
	if code, _ := f.do("POST", "/relay/v1/rooms/"+r.id+"/join", "", map[string]any{"device": a}); code != http.StatusUnauthorized {
		t.Fatalf("no key: %d", code)
	}
	if code, _ := f.join(room{id: "short", key: r.key}, a, true); code != http.StatusBadRequest {
		t.Fatalf("bad room id: %d", code)
	}

	// only the hash of the key is stored
	var stored []byte
	if err := f.db.QueryRow(`SELECT auth_hash FROM rooms WHERE id = ?`, r.id).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.RawURLEncoding.DecodeString(r.key)
	if bytes.Equal(stored, raw) {
		t.Fatal("room key stored in plain")
	}
}

func TestDeliveredMessagesAreDeleted(t *testing.T) {
	f := newFixture(t, Config{})
	r := newRoom()
	a, b := randomID(16), randomID(16)
	f.join(r, a, true)
	f.join(r, b, false)

	if code, out := f.send(r, a, "one", "two"); code != http.StatusOK || out["recipients"] != 1.0 {
		t.Fatalf("send: %d %v", code, out)
	}
	if got := f.receive(r, a, 0); len(got) != 0 {
		t.Fatalf("sender got its own messages: %v", got)
	}
	got := f.receive(r, b, 0)
	if len(got) != 2 || decoded(got[0]) != "one" || decoded(got[1]) != "two" || got[0].From != a {
		t.Fatalf("receive: %+v", got)
	}
	if rest := f.receive(r, b, got[0].Seq); len(rest) != 1 || decoded(rest[0]) != "two" {
		t.Fatalf("receive after cursor: %+v", rest)
	}

	if code, out := f.do("POST", "/relay/v1/rooms/"+r.id+"/ack", r.key,
		map[string]any{"device": b, "seq": got[1].Seq}); code != http.StatusOK || out["deleted"] != 2.0 {
		t.Fatalf("ack: %d %v", code, out)
	}
	if n := f.count(`SELECT COUNT(*) FROM deliveries`); n != 0 {
		t.Fatalf("%d deliveries left after ack", n)
	}
	if got := f.receive(r, b, 0); len(got) != 0 {
		t.Fatalf("acked messages delivered again: %v", got)
	}
}

func TestOneCopyPerOtherDevice(t *testing.T) {
	f := newFixture(t, Config{})
	r := newRoom()
	a, b, c := randomID(16), randomID(16), randomID(16)
	f.join(r, a, true)
	f.join(r, b, false)
	f.join(r, c, false)

	if _, out := f.send(r, a, "hi"); out["recipients"] != 2.0 {
		t.Fatalf("recipients: %v", out)
	}
	if len(f.receive(r, b, 0)) != 1 || len(f.receive(r, c, 0)) != 1 {
		t.Fatal("each other device gets its own copy")
	}
	// b acknowledging does not delete c's copy
	f.do("POST", "/relay/v1/rooms/"+r.id+"/ack", r.key, map[string]any{"device": b, "seq": 1 << 40})
	if len(f.receive(r, c, 0)) != 1 {
		t.Fatal("c's copy was deleted by b's ack")
	}
}

func TestNothingKeptWithoutRecipients(t *testing.T) {
	f := newFixture(t, Config{})
	r := newRoom()
	a := randomID(16)
	f.join(r, a, true)
	if code, out := f.send(r, a, "alone"); code != http.StatusOK || out["recipients"] != 0.0 {
		t.Fatalf("send: %d %v", code, out)
	}
	if n := f.count(`SELECT COUNT(*) FROM deliveries`); n != 0 {
		t.Fatalf("stored %d messages nobody can receive", n)
	}
}

func TestDeviceMustJoin(t *testing.T) {
	f := newFixture(t, Config{})
	r := newRoom()
	f.join(r, randomID(16), true)
	stranger := randomID(16)
	if code, out := f.send(r, stranger, "x"); code != http.StatusForbidden || out["error"] != "not_joined" {
		t.Fatalf("send from stranger: %d %v", code, out)
	}
}

func TestLimits(t *testing.T) {
	f := newFixture(t, Config{MaxDevices: 2, MaxRoomBytes: 10, MaxBody: 1024})
	r := newRoom()
	a, b := randomID(16), randomID(16)
	f.join(r, a, true)
	f.join(r, b, false)

	if code, out := f.join(r, randomID(16), false); code != http.StatusConflict || out["error"] != "room_full" {
		t.Fatalf("third device: %d %v", code, out)
	}
	if code, out := f.send(r, a, "0123456789x"); code != http.StatusInsufficientStorage || out["error"] != "storage_full" {
		t.Fatalf("over room quota: %d %v", code, out)
	}
	if code, out := f.send(r, a, strings.Repeat("x", 2048)); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over body limit: %d %v", code, out)
	}

	// a device gone for a month makes room for a new phone
	f.now = f.now.Add(31 * day)
	f.join(r, a, false)
	if code, out := f.join(r, randomID(16), false); code != http.StatusOK {
		t.Fatalf("join after eviction: %d %v", code, out)
	}
	// the evicted phone comes back to a full room
	if code, out := f.join(r, b, false); code != http.StatusConflict {
		t.Fatalf("evicted device rejoining a full room: %d %v", code, out)
	}
}

func TestCleanup(t *testing.T) {
	f := newFixture(t, Config{})
	r := newRoom()
	a, b := randomID(16), randomID(16)
	f.join(r, a, true)
	f.join(r, b, false)
	f.send(r, a, "never picked up")

	f.now = f.now.Add(29 * day)
	if err := f.srv.Cleanup(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT COUNT(*) FROM deliveries`); n != 1 {
		t.Fatalf("message dropped too early (%d left)", n)
	}

	f.now = f.now.Add(2 * day)
	f.join(r, a, false) // a is still around
	if err := f.srv.Cleanup(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT COUNT(*) FROM deliveries`); n != 0 {
		t.Fatalf("undelivered message kept past the TTL (%d left)", n)
	}

	// b never comes back; a stops using the app too
	f.now = f.now.Add(61 * day)
	if err := f.srv.Cleanup(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT COUNT(*) FROM devices`); n != 0 {
		t.Fatalf("%d idle devices kept", n)
	}
	if n := f.count(`SELECT COUNT(*) FROM rooms`); n != 0 {
		t.Fatalf("%d empty rooms kept", n)
	}

	// a phone coming back after all that reopens the room and learns that
	// it missed everything in between
	if code, out := f.join(r, a, true); code != http.StatusOK || out["created"] != true || out["joined"] != true {
		t.Fatalf("rejoin after cleanup: %d %v", code, out)
	}
}

func TestLeave(t *testing.T) {
	f := newFixture(t, Config{})
	r := newRoom()
	a, b := randomID(16), randomID(16)
	f.join(r, a, true)
	f.join(r, b, false)
	f.send(r, a, "for b")

	f.do("POST", "/relay/v1/rooms/"+r.id+"/leave", r.key, map[string]any{"device": b})
	if n := f.count(`SELECT COUNT(*) FROM deliveries`); n != 0 {
		t.Fatalf("messages for a device that left kept: %d", n)
	}
	f.do("POST", "/relay/v1/rooms/"+r.id+"/leave", r.key, map[string]any{"device": a})
	if code, _ := f.join(r, a, false); code != http.StatusNotFound {
		t.Fatalf("room survived both devices leaving: %d", code)
	}
}

func TestRateLimit(t *testing.T) {
	f := newFixture(t, Config{Rate: 0.001, Burst: 2})
	for i := range 2 {
		if code, _ := f.do("GET", "/relay/health", "", nil); code != http.StatusOK {
			t.Fatalf("request %d: %d", i, code)
		}
	}
	if code, _ := f.do("GET", "/relay/health", "", nil); code != http.StatusTooManyRequests {
		t.Fatalf("over the limit: %d", code)
	}
}

// streamWriter is a ResponseWriter that hands the body to a reader as it is
// written, so event streams can be tested without opening a port.
type streamWriter struct {
	header http.Header
	status chan int
	pipe   *io.PipeWriter
}

func (w *streamWriter) Header() http.Header         { return w.header }
func (w *streamWriter) WriteHeader(code int)        { w.status <- code }
func (w *streamWriter) Write(b []byte) (int, error) { return w.pipe.Write(b) }
func (w *streamWriter) Flush()                      {}

func TestEventsWakeTheRecipient(t *testing.T) {
	f := newFixture(t, Config{KeepAlive: time.Hour})
	r := newRoom()
	a, b := randomID(16), randomID(16)
	f.join(r, a, true)
	f.join(r, b, false)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req := httptest.NewRequestWithContext(ctx, "GET", "/relay/v1/rooms/"+r.id+"/events?device="+b, nil)
	req.Header.Set("Authorization", "Bearer "+r.key)
	pr, pw := io.Pipe()
	w := &streamWriter{header: http.Header{}, status: make(chan int, 1), pipe: pw}
	done := make(chan struct{})
	go func() {
		defer close(done)
		f.srv.ServeHTTP(w, req)
		pw.Close()
	}()
	defer func() { cancel(); pr.Close(); <-done }()

	if code := <-w.status; code != http.StatusOK || w.header.Get("Content-Type") != "text/event-stream" {
		t.Fatalf("events: %d %s", code, w.header.Get("Content-Type"))
	}
	lines := bufio.NewScanner(pr)
	waitFor := func(event string) {
		t.Helper()
		for lines.Scan() {
			if lines.Text() == "event: "+event {
				return
			}
		}
		t.Fatalf("stream ended before %q: %v", event, lines.Err())
	}
	waitFor("ready")
	f.send(r, a, "ping me")
	waitFor("message")
}
