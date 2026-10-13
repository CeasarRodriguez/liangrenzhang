package push

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

// handlerClient serves requests in-process, without opening a port.
func handlerClient(h http.HandlerFunc) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		rec := httptest.NewRecorder()
		h(rec, r)
		return rec.Result(), nil
	})}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

const fakeHost = "http://huawei.test"

func TestHuaweiClientCredentials(t *testing.T) {
	var tokenCalls int
	var gotBody map[string]any
	var gotHeaders http.Header

	client := handlerClient(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			tokenCalls++
			_ = r.ParseForm()
			if r.Form.Get("client_id") != "cid" || r.Form.Get("grant_type") != "client_credentials" {
				t.Errorf("bad token form: %v", r.Form)
			}
			_, _ = io.WriteString(w, `{"access_token":"tok123","expires_in":3600}`)
		case "/send":
			gotHeaders = r.Header.Clone()
			_ = json.NewDecoder(r.Body).Decode(&gotBody)
			_, _ = io.WriteString(w, `{"code":"80000000","msg":"Success"}`)
		}
	})

	h, err := NewHuawei(HuaweiConfig{
		ProjectID: "p1", ClientID: "cid", ClientSecret: "secret", TestMessage: true,
		PushURL: fakeHost + "/send", TokenURL: fakeHost + "/token", HTTPClient: client,
	})
	if err != nil {
		t.Fatal(err)
	}

	for range 2 {
		if err := h.Send(context.Background(), []string{"device-token"}, Message{Title: "标题", Body: "正文"}); err != nil {
			t.Fatal(err)
		}
	}

	if tokenCalls != 1 {
		t.Errorf("token should be cached, got %d token calls", tokenCalls)
	}
	if gotHeaders.Get("Authorization") != "Bearer tok123" || gotHeaders.Get("push-type") != "0" {
		t.Errorf("unexpected headers: %v", gotHeaders)
	}
	n := gotBody["payload"].(map[string]any)["notification"].(map[string]any)
	if n["title"] != "标题" || n["body"] != "正文" || n["category"] != "MARKETING" {
		t.Errorf("unexpected notification: %v", n)
	}
	if gotBody["pushOptions"].(map[string]any)["testMessage"] != true {
		t.Errorf("expected testMessage")
	}
	if tokens := gotBody["target"].(map[string]any)["token"].([]any); len(tokens) != 1 || tokens[0] != "device-token" {
		t.Errorf("unexpected target: %v", tokens)
	}
}

func TestHuaweiServiceAccountJWT(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	saFile := filepath.Join(t.TempDir(), "sa.json")
	raw, _ := json.Marshal(map[string]string{"key_id": "kid-1", "sub_account": "sub-1", "private_key": pemKey})
	if err := os.WriteFile(saFile, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	var auth string
	client := handlerClient(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		_, _ = io.WriteString(w, `{"code":"80000000"}`)
	})

	h, err := NewHuawei(HuaweiConfig{ProjectID: "p1", ServiceAccountFile: saFile, PushURL: fakeHost, HTTPClient: client})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.Send(context.Background(), []string{"x"}, Message{Title: "t", Body: "b"}); err != nil {
		t.Fatal(err)
	}

	parsed, err := jwt.Parse(strings.TrimPrefix(auth, "Bearer "), func(tk *jwt.Token) (any, error) {
		return &key.PublicKey, nil
	}, jwt.WithValidMethods([]string{"PS256"}))
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Header["kid"] != "kid-1" {
		t.Errorf("kid = %v", parsed.Header["kid"])
	}
	claims := parsed.Claims.(jwt.MapClaims)
	if claims["iss"] != "sub-1" || claims["aud"] != huaweiTokenURL {
		t.Errorf("claims = %v", claims)
	}
}

func TestHuaweiSendError(t *testing.T) {
	client := handlerClient(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			_, _ = io.WriteString(w, `{"access_token":"tok","expires_in":3600}`)
			return
		}
		_, _ = io.WriteString(w, `{"code":"80300007","msg":"invalid token"}`)
	})

	h, _ := NewHuawei(HuaweiConfig{ProjectID: "p", ClientID: "a", ClientSecret: "b", PushURL: fakeHost + "/send", TokenURL: fakeHost + "/token", HTTPClient: client})
	if err := h.Send(context.Background(), []string{"x"}, Message{}); err == nil || !strings.Contains(err.Error(), "80300007") {
		t.Errorf("expected push error, got %v", err)
	}
}
