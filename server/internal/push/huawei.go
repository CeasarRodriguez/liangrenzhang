package push

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	huaweiTokenURL    = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
	huaweiPushURL     = "https://push-api.cloud.huawei.com/v3/%s/messages:send"
	huaweiSuccessCode = "80000000"
)

// HuaweiConfig configures the HarmonyOS NEXT Push Kit (REST v3) sender.
//
// Authentication uses either a service account key file (JWT signed with
// PS256) or a project-level OAuth client (client_credentials). Exactly one
// of them must be provided.
type HuaweiConfig struct {
	ProjectID string

	ServiceAccountFile string

	ClientID     string
	ClientSecret string

	// Category is the notification category, e.g. "MARKETING" (no special
	// permission needed) or a self-classified category once approved.
	Category string
	// TestMessage marks pushes as test messages, which unpublished debug
	// builds need for delivery.
	TestMessage bool

	// Endpoint overrides, for tests.
	PushURL  string
	TokenURL string

	HTTPClient *http.Client
}

type serviceAccount struct {
	KeyID      string `json:"key_id"`
	PrivateKey string `json:"private_key"`
	SubAccount string `json:"sub_account"`
}

type Huawei struct {
	cfg HuaweiConfig
	sa  *serviceAccount
	key *rsa.PrivateKey

	mu          sync.Mutex
	accessToken string
	expiresAt   time.Time
}

func NewHuawei(cfg HuaweiConfig) (*Huawei, error) {
	if cfg.ProjectID == "" {
		return nil, errors.New("huawei push: missing project id")
	}
	if cfg.Category == "" {
		cfg.Category = "MARKETING"
	}
	if cfg.PushURL == "" {
		cfg.PushURL = fmt.Sprintf(huaweiPushURL, url.PathEscape(cfg.ProjectID))
	}
	if cfg.TokenURL == "" {
		cfg.TokenURL = huaweiTokenURL
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 15 * time.Second}
	}

	h := &Huawei{cfg: cfg}

	switch {
	case cfg.ServiceAccountFile != "":
		raw, err := os.ReadFile(cfg.ServiceAccountFile)
		if err != nil {
			return nil, fmt.Errorf("huawei push: read service account: %w", err)
		}
		h.sa = &serviceAccount{}
		if err := json.Unmarshal(raw, h.sa); err != nil {
			return nil, fmt.Errorf("huawei push: parse service account: %w", err)
		}
		h.key, err = jwt.ParseRSAPrivateKeyFromPEM([]byte(h.sa.PrivateKey))
		if err != nil {
			return nil, fmt.Errorf("huawei push: parse private key: %w", err)
		}
	case cfg.ClientID != "" && cfg.ClientSecret != "":
	default:
		return nil, errors.New("huawei push: need a service account file or client id/secret")
	}

	return h, nil
}

// authorization returns the Authorization header value.
func (h *Huawei) authorization(ctx context.Context) (string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.accessToken != "" && time.Now().Before(h.expiresAt) {
		return "Bearer " + h.accessToken, nil
	}

	if h.sa != nil {
		now := time.Now()
		t := jwt.NewWithClaims(jwt.SigningMethodPS256, jwt.MapClaims{
			"iss": h.sa.SubAccount,
			"aud": huaweiTokenURL,
			"iat": now.Unix(),
			"exp": now.Add(time.Hour).Unix(),
		})
		t.Header["kid"] = h.sa.KeyID
		signed, err := t.SignedString(h.key)
		if err != nil {
			return "", fmt.Errorf("huawei push: sign jwt: %w", err)
		}
		h.accessToken = signed
		h.expiresAt = now.Add(50 * time.Minute)
		return "Bearer " + signed, nil
	}

	form := url.Values{
		"grant_type":    {"client_credentials"},
		"client_id":     {h.cfg.ClientID},
		"client_secret": {h.cfg.ClientSecret},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.cfg.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	res, err := h.cfg.HTTPClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("huawei push: token request: %w", err)
	}
	defer res.Body.Close()

	var tok struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
		Error       any    `json:"error"`
	}
	body, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	if err := json.Unmarshal(body, &tok); err != nil || tok.AccessToken == "" {
		return "", fmt.Errorf("huawei push: token response %d: %s", res.StatusCode, truncate(body))
	}

	h.accessToken = tok.AccessToken
	h.expiresAt = time.Now().Add(time.Duration(max(tok.ExpiresIn-300, 60)) * time.Second)
	return "Bearer " + tok.AccessToken, nil
}

func (h *Huawei) Send(ctx context.Context, tokens []string, msg Message) error {
	if len(tokens) == 0 {
		return nil
	}

	auth, err := h.authorization(ctx)
	if err != nil {
		return err
	}

	payload := map[string]any{
		"payload": map[string]any{
			"notification": map[string]any{
				"category":    h.cfg.Category,
				"title":       msg.Title,
				"body":        msg.Body,
				"clickAction": map[string]any{"actionType": 0},
			},
		},
		"target": map[string]any{"token": tokens},
	}
	if h.cfg.TestMessage {
		payload["pushOptions"] = map[string]any{"testMessage": true}
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.cfg.PushURL, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", auth)
	req.Header.Set("push-type", "0")

	res, err := h.cfg.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("huawei push: send: %w", err)
	}
	defer res.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	var result struct {
		Code string `json:"code"`
		Msg  string `json:"msg"`
	}
	_ = json.Unmarshal(body, &result)
	if res.StatusCode != http.StatusOK || result.Code != huaweiSuccessCode {
		if res.StatusCode == http.StatusUnauthorized {
			h.mu.Lock()
			h.accessToken = ""
			h.mu.Unlock()
		}
		return fmt.Errorf("huawei push: status %d: %s", res.StatusCode, truncate(body))
	}

	return nil
}

func truncate(b []byte) string {
	if len(b) > 300 {
		return string(b[:300]) + "..."
	}
	return string(b)
}
