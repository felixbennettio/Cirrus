package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"cirrus/server/internal/config"
)

// GET /api/v1/oauth/config tells the apps which Cloudflare OAuth client to
// use and which scopes to request, so the scopes can follow the client's
// settings at Cloudflare without an app update. With CF_ACCOUNT_ID and
// Cloudflare API credentials the scopes are synced from the Cloudflare API;
// otherwise, or until the first sync succeeds, they come from OAUTH_SCOPES.

const (
	oauthSyncTTL   = time.Hour   // how long synced scopes are used
	oauthRetryWait = time.Minute // wait after a failed sync
)

// cleanScopes drops empty and duplicate scopes, and offline_access and
// openid: the app adds offline_access itself.
func cleanScopes(in []string, skip ...string) []string {
	out := []string{}
	seen := map[string]bool{"": true, "offline_access": true, "openid": true}
	for _, s := range skip {
		seen[s] = true
	}
	for _, s := range in {
		s = strings.TrimSpace(s)
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func (a *App) apiOAuthConfig(w http.ResponseWriter, r *http.Request) {
	c := a.cfg.OAuth
	var scopes, optional []string
	source := ""
	if a.oauth != nil {
		if s, o, ok := a.oauth.current(r.Context()); ok {
			scopes, optional, source = s, o, "cloudflare"
		}
	}
	if source == "" {
		scopes = cleanScopes(c.Scopes)
		optional = cleanScopes(c.OptionalScopes, scopes...)
		source = "env"
	}
	if len(scopes) == 0 {
		writeError(w, http.StatusNotFound, "not_configured", "未配置 OAuth 权限范围", nil)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, map[string]any{
		"client_id":       c.ClientID,
		"scopes":          scopes,
		"optional_scopes": optional,
		"source":          source,
	})
}

// oauthSync keeps the scopes of the OAuth client as configured at
// Cloudflare. It refreshes lazily on request, one fetch at a time, and keeps
// the last good value when a fetch fails.
type oauthSync struct {
	cfg    config.OAuth
	client *http.Client
	now    func() time.Time
	log    *slog.Logger

	mu       sync.Mutex
	have     bool
	scopes   []string
	optional []string
	next     time.Time     // when to fetch again
	flight   chan struct{} // closed when the running fetch ends
}

func newOAuthSync(cfg config.OAuth, now func() time.Time, log *slog.Logger) *oauthSync {
	return &oauthSync{cfg: cfg, client: &http.Client{Timeout: 10 * time.Second}, now: now, log: log}
}

// current returns the synced scopes, fetching them first when due. Callers
// that arrive during a fetch share it; those that already have a value get
// it at once instead of waiting.
func (s *oauthSync) current(ctx context.Context) (scopes, optional []string, ok bool) {
	s.mu.Lock()
	if s.flight == nil && !s.now().Before(s.next) {
		s.flight = make(chan struct{})
		s.mu.Unlock()
		s.refresh(ctx)
		s.mu.Lock()
	} else if s.flight != nil && !s.have {
		ch := s.flight
		s.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
		}
		s.mu.Lock()
	}
	defer s.mu.Unlock()
	return s.scopes, s.optional, s.have
}

func (s *oauthSync) refresh(ctx context.Context) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	scopes, optional, err := s.fetch(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		s.log.Warn("oauth scope sync failed", "err", err, "keeping_last", s.have)
		s.next = s.now().Add(oauthRetryWait)
	} else {
		s.have, s.scopes, s.optional = true, scopes, optional
		s.next = s.now().Add(oauthSyncTTL)
		s.log.Info("oauth scopes synced", "client_id", s.cfg.ClientID, "scopes", len(scopes), "optional_scopes", len(optional))
	}
	close(s.flight)
	s.flight = nil
}

// fetch reads the OAuth client from the Cloudflare API. Errors never carry
// the credentials.
func (s *oauthSync) fetch(ctx context.Context) ([]string, []string, error) {
	u := strings.TrimRight(s.cfg.APIBase, "/") + "/accounts/" + url.PathEscape(s.cfg.AccountID) +
		"/oauth_clients/" + url.PathEscape(s.cfg.ClientID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Accept", "application/json")
	if s.cfg.APIToken != "" {
		req.Header.Set("Authorization", "Bearer "+s.cfg.APIToken)
	} else {
		req.Header.Set("X-Auth-Email", s.cfg.APIEmail)
		req.Header.Set("X-Auth-Key", s.cfg.APIKey)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("cloudflare: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, nil, fmt.Errorf("cloudflare: %w", err)
	}
	var env struct {
		Success bool `json:"success"`
		Errors  []struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"errors"`
		Result struct {
			Scopes         []string `json:"scopes"`
			OptionalScopes []string `json:"optional_scopes"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, nil, fmt.Errorf("cloudflare: HTTP %d: unexpected response", resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK || !env.Success {
		var msgs []string
		for _, e := range env.Errors {
			msgs = append(msgs, fmt.Sprintf("%d %s", e.Code, e.Message))
		}
		return nil, nil, fmt.Errorf("cloudflare: HTTP %d: %s", resp.StatusCode, strings.Join(msgs, "; "))
	}
	scopes := cleanScopes(env.Result.Scopes)
	if len(scopes) == 0 {
		return nil, nil, fmt.Errorf("cloudflare: the OAuth client has no scopes")
	}
	return scopes, cleanScopes(env.Result.OptionalScopes, scopes...), nil
}
