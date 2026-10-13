package ledger_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"couple-ledger/server/internal/ledger"
	"couple-ledger/server/internal/push"
	_ "couple-ledger/server/migrations"
)

type fakePusher struct {
	sent chan sentPush
}

type sentPush struct {
	tokens []string
	msg    push.Message
}

func (f *fakePusher) Send(_ context.Context, tokens []string, msg push.Message) error {
	f.sent <- sentPush{tokens, msg}
	return nil
}

type harness struct {
	t      *testing.T
	app    *tests.TestApp
	mux    http.Handler
	pusher *fakePusher
}

func newHarness(t *testing.T, maxUsers int, now time.Time) *harness {
	t.Helper()

	app, err := tests.NewTestApp(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(app.Cleanup)

	// the scenarios below fire many requests from the same test IP
	app.Settings().RateLimits.Enabled = false
	if err := app.Save(app.Settings()); err != nil {
		t.Fatal(err)
	}

	loc, _ := time.LoadLocation("Asia/Shanghai")
	h := &harness{t: t, app: app, pusher: &fakePusher{sent: make(chan sentPush, 10)}}
	ledger.Register(app, ledger.Config{
		Location: loc,
		MaxUsers: maxUsers,
		Pusher:   h.pusher,
		Now:      func() time.Time { return now },
		Intn:     func(int) int { return 0 },
	})

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatal(err)
	}
	se := &core.ServeEvent{App: app, Router: router}
	err = app.OnServe().Trigger(se, func(e *core.ServeEvent) error {
		h.mux, err = e.Router.BuildMux()
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

type resp struct {
	status int
	body   map[string]any
	raw    string
}

func (r resp) items() []any {
	items, _ := r.body["items"].([]any)
	return items
}

func (r resp) str(key string) string {
	s, _ := r.body[key].(string)
	return s
}

func (h *harness) do(method, path, token string, body any) resp {
	h.t.Helper()
	var reader *bytes.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	h.mux.ServeHTTP(rec, req)

	r := resp{status: rec.Code, raw: rec.Body.String()}
	_ = json.Unmarshal(rec.Body.Bytes(), &r.body)
	return r
}

func (h *harness) expect(r resp, status int, what string) resp {
	h.t.Helper()
	if r.status != status {
		h.t.Fatalf("%s: status %d, want %d; body: %s", what, r.status, status, r.raw)
	}
	return r
}

type user struct {
	id, token string
}

func (h *harness) signup(username string) user {
	h.t.Helper()
	h.expect(h.do("POST", "/api/collections/users/records", "", map[string]any{
		"username": username, "password": "test-pass-123", "passwordConfirm": "test-pass-123", "name": username,
	}), 200, "signup "+username)
	r := h.expect(h.do("POST", "/api/collections/users/auth-with-password", "", map[string]any{
		"identity": username, "password": "test-pass-123",
	}), 200, "login "+username)
	return user{id: r.body["record"].(map[string]any)["id"].(string), token: r.str("token")}
}

func (h *harness) householdOf(u user) string {
	h.t.Helper()
	r := h.expect(h.do("GET", "/api/collections/users/records/"+u.id, u.token, nil), 200, "view self")
	return r.str("household")
}

// couple sets up alice + bob in one household and an outsider eve.
func (h *harness) couple() (alice, bob, eve user, household, code string) {
	h.t.Helper()
	alice = h.signup("alice")
	bob = h.signup("bob")
	eve = h.signup("eve")

	r := h.expect(h.do("POST", "/api/ledger/household", alice.token, map[string]any{"name": "测试小家"}), 200, "create household")
	household, code = r.str("id"), r.str("invite_code")
	h.expect(h.do("POST", "/api/ledger/household/join", bob.token, map[string]any{"code": code}), 200, "bob joins")
	return
}

func entryBody(id, household, owner, typ string, amount int, date string) map[string]any {
	return map[string]any{
		"id": id, "household": household, "owner": owner, "type": typ,
		"amount": amount, "category": "餐饮", "occurred_on": date,
	}
}

var seq int

func newID() string {
	seq++
	return fmt.Sprintf("e%014d", seq)
}

func TestPairing(t *testing.T) {
	h := newHarness(t, 3, time.Now())
	alice, bob, eve, household, code := h.couple()

	if h.householdOf(alice) != household || h.householdOf(bob) != household {
		t.Fatal("alice and bob should share the household")
	}
	if len(code) != 6 {
		t.Fatalf("invite code %q", code)
	}

	msgs := h.expect(h.do("GET", "/api/collections/alert_messages/records?perPage=200", alice.token, nil), 200, "list messages")
	if n := len(msgs.items()); n < 20 {
		t.Fatalf("expected seeded default messages, got %d", n)
	}

	h.expect(h.do("POST", "/api/ledger/household/join", eve.token, map[string]any{"code": code}), 400, "join full household")
	h.expect(h.do("POST", "/api/ledger/household/join", eve.token, map[string]any{"code": "000000"}), 404, "wrong code")
	h.expect(h.do("POST", "/api/ledger/household/join", eve.token, map[string]any{"code": "12ab"}), 400, "malformed code")
	h.expect(h.do("POST", "/api/ledger/household", alice.token, nil), 400, "second household")

	// membership can only change through the ledger routes
	r := h.do("PATCH", "/api/collections/users/records/"+eve.id, eve.token, map[string]any{"household": household})
	if r.status == 200 || h.householdOf(eve) != "" {
		t.Fatalf("eve must not join by patching herself: %d %s", r.status, r.raw)
	}
	r = h.do("POST", "/api/collections/users/records", "", map[string]any{
		"username": "mallory", "password": "test-pass-123", "passwordConfirm": "test-pass-123", "household": household,
	})
	if r.status == 200 {
		t.Fatal("signup must not set a household")
	}

	// partners can see each other's profile, outsiders cannot
	h.expect(h.do("GET", "/api/collections/users/records/"+alice.id, bob.token, nil), 200, "bob views alice")
	h.expect(h.do("GET", "/api/collections/users/records/"+alice.id, eve.token, nil), 404, "eve views alice")
	h.expect(h.do("GET", "/api/collections/households/records/"+household, eve.token, nil), 404, "eve views household")
}

func TestSignupLimit(t *testing.T) {
	h := newHarness(t, 2, time.Now())
	h.signup("alice")
	h.signup("bob")
	r := h.do("POST", "/api/collections/users/records", "", map[string]any{
		"username": "carol", "password": "test-pass-123", "passwordConfirm": "test-pass-123",
	})
	h.expect(r, 403, "third signup")
	if !strings.Contains(r.raw, "满员") {
		t.Fatalf("unexpected message: %s", r.raw)
	}
}

func TestEntryPrivacy(t *testing.T) {
	h := newHarness(t, 3, time.Now())
	alice, bob, eve, household, _ := h.couple()

	id := newID()
	h.expect(h.do("POST", "/api/collections/entries/records", alice.token,
		entryBody(id, household, alice.id, "expense", 1000, "2026-10-12")), 200, "alice creates entry")
	h.expect(h.do("POST", "/api/collections/entry_details/records", alice.token, map[string]any{
		"id": id, "entry": id, "owner": alice.id, "note": "给你买的生日礼物",
	}), 200, "alice creates note")

	// bob sees amount and category, but never the note
	list := h.expect(h.do("GET", "/api/collections/entries/records", bob.token, nil), 200, "bob lists entries")
	if len(list.items()) != 1 {
		t.Fatalf("bob should see 1 entry, got %s", list.raw)
	}
	entry := list.items()[0].(map[string]any)
	if entry["amount"].(float64) != 1000 || entry["category"] != "餐饮" {
		t.Fatalf("unexpected entry: %v", entry)
	}

	details := h.expect(h.do("GET", "/api/collections/entry_details/records", bob.token, nil), 200, "bob lists notes")
	if len(details.items()) != 0 {
		t.Fatalf("bob must not see alice's notes: %s", details.raw)
	}
	h.expect(h.do("GET", "/api/collections/entry_details/records/"+id, bob.token, nil), 404, "bob views note")
	own := h.expect(h.do("GET", "/api/collections/entry_details/records/"+id, alice.token, nil), 200, "alice views note")
	if own.str("note") != "给你买的生日礼物" {
		t.Fatalf("alice should read her note: %s", own.raw)
	}

	// inference through filters, sorting, expand or realtime options is rejected
	probes := []string{
		"filter=" + url.QueryEscape("entry_details_via_entry.note ~ '礼物'"),
		"filter=" + url.QueryEscape("@collection.entry_details.note ~ '礼物'"),
		"filter=" + url.QueryEscape("@COLLECTION.entries.amount > 0"),
		"sort=" + url.QueryEscape("entry_details_via_entry.note"),
		"expand=" + url.QueryEscape("entry_details_via_entry"),
	}
	for _, q := range probes {
		r := h.do("GET", "/api/collections/entries/records?"+q, bob.token, nil)
		if r.status != 403 || strings.Contains(r.raw, "礼物") {
			t.Fatalf("probe %q: status %d body %s", q, r.status, r.raw)
		}
	}
	// the owner can still sync her own notes with ordinary filters
	h.expect(h.do("GET", "/api/collections/entry_details/records?filter="+url.QueryEscape("updated >= '2000-01-01'"), alice.token, nil), 200, "alice syncs notes")

	// ownership is enforced
	h.expect(h.do("PATCH", "/api/collections/entries/records/"+id, bob.token, map[string]any{"amount": 1}), 404, "bob edits alice's entry")
	h.expect(h.do("POST", "/api/collections/entries/records", bob.token,
		entryBody(newID(), household, alice.id, "expense", 1, "2026-10-12")), 400, "bob records as alice")
	h.expect(h.do("POST", "/api/collections/entry_details/records", bob.token, map[string]any{
		"id": newID(), "entry": id, "owner": bob.id, "note": "x",
	}), 400, "bob attaches note to alice's entry")
	h.expect(h.do("PATCH", "/api/collections/entries/records/"+id, alice.token, map[string]any{"owner": bob.id}), 404, "alice reassigns owner")
	h.expect(h.do("PATCH", "/api/collections/entries/records/"+id, alice.token, map[string]any{"amount": 2000, "deleted": true}), 200, "alice soft deletes")
	if r := h.do("DELETE", "/api/collections/entries/records/"+id, alice.token, nil); r.status < 400 {
		t.Fatalf("hard delete must be disabled, got %d", r.status)
	}

	// outsiders see nothing
	if n := len(h.expect(h.do("GET", "/api/collections/entries/records", eve.token, nil), 200, "eve lists").items()); n != 0 {
		t.Fatalf("eve sees %d entries", n)
	}

	// validation
	h.expect(h.do("POST", "/api/collections/entries/records", alice.token,
		entryBody(newID(), household, alice.id, "expense", 100, "2026-02-30")), 400, "invalid date")
	h.expect(h.do("POST", "/api/collections/entries/records", alice.token,
		entryBody(newID(), household, alice.id, "expense", 0, "2026-10-01")), 400, "zero amount")
}

func TestRealtimeSubscriptionGuard(t *testing.T) {
	h := newHarness(t, 3, time.Now())
	_, bob, _, _, _ := h.couple()

	opts := url.QueryEscape(`{"query":{"filter":"entry_details_via_entry.note ~ 'x'"}}`)
	e := &core.RealtimeSubscribeRequestEvent{
		RequestEvent:  &core.RequestEvent{App: h.app},
		Subscriptions: []string{"entries?options=" + opts},
	}
	authRec, err := h.app.FindRecordById("users", bob.id)
	if err != nil {
		t.Fatal(err)
	}
	e.Auth = authRec
	err = h.app.OnRealtimeSubscribeRequest().Trigger(e, func(*core.RealtimeSubscribeRequestEvent) error { return nil })
	if err == nil {
		t.Fatal("subscription filter referencing entry_details must be rejected")
	}

	e.Subscriptions = []string{"entries", "entry_details", "alerts"}
	if err := h.app.OnRealtimeSubscribeRequest().Trigger(e, func(*core.RealtimeSubscribeRequestEvent) error { return nil }); err != nil {
		t.Fatalf("plain subscriptions must pass: %v", err)
	}
}

func TestBudgetAlerts(t *testing.T) {
	loc, _ := time.LoadLocation("Asia/Shanghai")
	h := newHarness(t, 3, time.Date(2026, 10, 12, 21, 0, 0, 0, loc))
	alice, bob, _, household, _ := h.couple()

	h.expect(h.do("POST", "/api/collections/devices/records", bob.token, map[string]any{
		"user": bob.id, "platform": "harmony", "push_token": "hm-token",
	}), 200, "bob registers device")

	// October–December: 30,000 income, 20,000 target -> 3,333.33 per month
	goal := h.expect(h.do("POST", "/api/collections/goals/records", alice.token, map[string]any{
		"household": household, "start_month": "2026-10", "end_month": "2026-12",
		"planned_income": 3000000, "savings_target": 2000000,
	}), 200, "create goal")
	h.expect(h.do("POST", "/api/collections/goals/records", bob.token, map[string]any{
		"household": household, "start_month": "2026-12", "end_month": "2027-03",
		"planned_income": 1, "savings_target": 1,
	}), 400, "overlapping goal")

	alerts := func(u user) []map[string]any {
		r := h.expect(h.do("GET", "/api/collections/alerts/records?sort=created", u.token, nil), 200, "list alerts")
		out := []map[string]any{}
		for _, it := range r.items() {
			out = append(out, it.(map[string]any))
		}
		return out
	}
	waitPush := func() sentPush {
		select {
		case p := <-h.pusher.sent:
			return p
		case <-time.After(3 * time.Second):
			t.Fatal("expected a push")
			return sentPush{}
		}
	}

	h.expect(h.do("POST", "/api/collections/entries/records", alice.token,
		entryBody(newID(), household, alice.id, "expense", 270000, "2026-10-03")), 200, "81%")
	if a := alerts(alice); len(a) != 1 || a[0]["kind"] != "month_80" || a[0]["read"] != false {
		t.Fatalf("alice alerts after 81%%: %v", a)
	}
	if a := alerts(bob); len(a) != 1 || a[0]["kind"] != "month_80" {
		t.Fatalf("bob alerts after 81%%: %v", a)
	}
	p := waitPush()
	if len(p.tokens) != 1 || p.tokens[0] != "hm-token" || p.msg.Title != "本月预算已用八成" {
		t.Fatalf("unexpected push %+v", p)
	}
	if strings.Contains(p.msg.Body, "{") {
		t.Fatalf("placeholders not rendered: %s", p.msg.Body)
	}

	// still above 80% only: nothing new
	h.expect(h.do("POST", "/api/collections/entries/records", alice.token,
		entryBody(newID(), household, alice.id, "expense", 10000, "2026-10-04")), 200, "84%")
	if a := alerts(alice); len(a) != 1 {
		t.Fatalf("no duplicate alerts expected: %v", a)
	}

	// income does not count as spending
	h.expect(h.do("POST", "/api/collections/entries/records", bob.token,
		entryBody(newID(), household, bob.id, "income", 900000, "2026-10-10")), 200, "income")
	if a := alerts(alice); len(a) != 1 {
		t.Fatalf("income must not trigger alerts: %v", a)
	}

	// jump past 100% and 120% at once: only the top level is announced
	h.expect(h.do("POST", "/api/collections/entries/records", bob.token,
		entryBody(newID(), household, bob.id, "expense", 130000, "2026-10-11")), 200, "123%")
	a := alerts(bob)
	if len(a) != 3 {
		t.Fatalf("bob should have 3 alerts, got %v", a)
	}
	byKind := map[string]map[string]any{}
	for _, it := range a {
		byKind[it["kind"].(string)] = it
	}
	if byKind["month_100"]["read"] != true || byKind["month_120"]["read"] != false {
		t.Fatalf("only month_120 should be unread: %v", a)
	}
	if p := waitPush(); p.msg.Title != "本月超支提醒" {
		t.Fatalf("expected the 120%% push, got %+v", p)
	}

	// alert records are read-only except the read flag
	id := byKind["month_120"]["id"].(string)
	h.expect(h.do("PATCH", "/api/collections/alerts/records/"+id, bob.token, map[string]any{"read": true}), 200, "mark read")
	h.expect(h.do("PATCH", "/api/collections/alerts/records/"+id, bob.token, map[string]any{"body": "hacked"}), 404, "edit body")
	h.expect(h.do("GET", "/api/collections/alerts/records/"+id, alice.token, nil), 404, "alice reads bob's alert")

	// custom copy: disable every default period_over message, add our own
	msgs := h.expect(h.do("GET", "/api/collections/alert_messages/records?perPage=200&filter="+url.QueryEscape("level='period_over'"), alice.token, nil), 200, "list period messages")
	for _, it := range msgs.items() {
		m := it.(map[string]any)
		mid := m["id"].(string)
		h.expect(h.do("DELETE", "/api/collections/alert_messages/records/"+mid, bob.token, nil), 404, "delete default")
		h.expect(h.do("PATCH", "/api/collections/alert_messages/records/"+mid, bob.token, map[string]any{"text": "改掉默认"}), 404, "edit default text")
		h.expect(h.do("PATCH", "/api/collections/alert_messages/records/"+mid, bob.token, map[string]any{"enabled": false}), 200, "disable default")
	}
	h.expect(h.do("POST", "/api/collections/alert_messages/records", alice.token, map[string]any{
		"household": household, "level": "period_over", "text": "老婆大人：额度花完啦，还差 ¥{还差}！",
		"enabled": true, "is_default": true, "created_by": alice.id,
	}), 400, "custom message cannot be default")
	custom := h.expect(h.do("POST", "/api/collections/alert_messages/records", alice.token, map[string]any{
		"household": household, "level": "period_over", "text": "老婆大人：额度花完啦，还差 ¥{还差}！",
		"enabled": true, "created_by": alice.id,
	}), 200, "custom message")
	h.expect(h.do("PATCH", "/api/collections/alert_messages/records/"+custom.str("id"), bob.token, map[string]any{"text": "老公大人：额度花完啦，还差 ¥{还差}！"}), 200, "edit custom")

	// total spent 410,000 + 600,000 > budget 1,000,000
	h.expect(h.do("POST", "/api/collections/entries/records", alice.token,
		entryBody(newID(), household, alice.id, "expense", 600000, "2026-10-12")), 200, "over period budget")
	p = waitPush()
	if p.msg.Title != "攒钱目标预警" || p.msg.Body != "老公大人：额度花完啦，还差 ¥21,100！" {
		t.Fatalf("expected the custom period message, got %+v", p)
	}

	// goal edits re-evaluate as well (no new levels here, so no new alerts)
	before := len(alerts(alice))
	h.expect(h.do("PATCH", "/api/collections/goals/records/"+goal.str("id"), bob.token, map[string]any{"planned_income": 3100000}), 200, "edit goal")
	if after := len(alerts(alice)); after != before {
		t.Fatalf("unexpected alerts after goal edit: %d -> %d", before, after)
	}

	// device tokens follow the latest login on that phone
	h.expect(h.do("POST", "/api/collections/devices/records", alice.token, map[string]any{
		"user": alice.id, "platform": "harmony", "push_token": "hm-token",
	}), 200, "alice takes over the phone")
	if n := len(h.expect(h.do("GET", "/api/collections/devices/records", bob.token, nil), 200, "bob devices").items()); n != 0 {
		t.Fatalf("bob's stale device should be removed, got %d", n)
	}
}
