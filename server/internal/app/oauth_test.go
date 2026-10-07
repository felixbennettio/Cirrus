package app

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"cirrus/server/internal/config"
)

const defaultClientID = "9c147a5155baf903357222bd4d31ad50"

// fakeCF serves GET /accounts/acc/oauth_clients/{id} like the Cloudflare API.
type fakeCF struct {
	srv     *httptest.Server
	hits    atomic.Int32
	mu      sync.Mutex
	status  int
	body    string
	auth    func(r *http.Request) bool
	release chan struct{} // when set, requests wait for it
}

func newFakeCF(t *testing.T, auth func(r *http.Request) bool) *fakeCF {
	f := &fakeCF{status: 200, auth: auth,
		body: `{"success":true,"errors":[],"result":{"id":"` + defaultClientID + `","name":"Cirrus",` +
			`"scopes":["account:read","zone:read","offline_access","openid","dns:edit"],"optional_scopes":["workers:write","openid","zone:read"]}}`}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.hits.Add(1)
		f.mu.Lock()
		status, body, release := f.status, f.body, f.release
		f.mu.Unlock()
		if release != nil {
			<-release
		}
		if r.Method != http.MethodGet || r.URL.Path != "/client/v4/accounts/acc/oauth_clients/"+defaultClientID {
			t.Errorf("cloudflare: %s %s", r.Method, r.URL.Path)
		}
		if !f.auth(r) {
			w.WriteHeader(403)
			w.Write([]byte(`{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		w.Write([]byte(body))
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeCF) set(status int, body string) {
	f.mu.Lock()
	f.status, f.body = status, body
	f.mu.Unlock()
}

func bearer(r *http.Request) bool {
	return r.Header.Get("Authorization") == "Bearer cf-token-secret" && r.Header.Get("X-Auth-Key") == ""
}

func globalKey(r *http.Request) bool {
	return r.Header.Get("X-Auth-Email") == "ops@example.com" && r.Header.Get("X-Auth-Key") == "cf-global-secret" &&
		r.Header.Get("Authorization") == ""
}

func oauthHarness(t *testing.T, cf *fakeCF, env map[string]string, log *bytes.Buffer) *harness {
	o := harnessOpt{env: env}
	if log != nil {
		o.log = log
	}
	if cf != nil {
		o.cfg = func(c *config.Config) { c.OAuth.APIBase = cf.srv.URL + "/client/v4/" }
	}
	return newHarness(t, o)
}

func (h *harness) oauthConfig(status int) map[string]any {
	h.t.Helper()
	rec := h.get("/api/v1/oauth/config")
	m := expect(h.t, rec, status, "")
	if status == 200 && rec.Header().Get("Cache-Control") != "public, max-age=300" {
		h.t.Fatalf("Cache-Control = %q", rec.Header().Get("Cache-Control"))
	}
	return m
}

func list(v any) string {
	var out []string
	for _, s := range v.([]any) {
		out = append(out, s.(string))
	}
	return strings.Join(out, " ")
}

func TestOAuthConfigEnv(t *testing.T) {
	h := oauthHarness(t, nil, map[string]string{
		"OAUTH_SCOPES": "account:read, zone:read offline_access,zone:read", "OAUTH_OPTIONAL_SCOPES": "openid workers:write account:read",
	}, nil)
	m := h.oauthConfig(200)
	if m["client_id"] != defaultClientID || m["source"] != "env" || list(m["scopes"]) != "account:read zone:read" ||
		list(m["optional_scopes"]) != "workers:write" {
		t.Fatalf("config = %v", m)
	}
	h2 := oauthHarness(t, nil, map[string]string{"OAUTH_CLIENT_ID": "abc", "OAUTH_SCOPES": "a:read"}, nil)
	if m := h2.oauthConfig(200); m["client_id"] != "abc" || list(m["scopes"]) != "a:read" || len(m["optional_scopes"].([]any)) != 0 {
		t.Fatalf("config = %v", m)
	}
}

func TestOAuthConfigNotConfigured(t *testing.T) {
	h := oauthHarness(t, nil, nil, nil)
	expect(t, h.get("/api/v1/oauth/config"), 404, "not_configured")
	// Sync failing with nothing to fall back to.
	cf := newFakeCF(t, bearer)
	cf.set(500, `{"success":false,"errors":[{"code":1,"message":"boom"}]}`)
	h2 := oauthHarness(t, cf, map[string]string{"CF_ACCOUNT_ID": "acc", "CF_API_TOKEN": "cf-token-secret"}, nil)
	expect(t, h2.get("/api/v1/oauth/config"), 404, "not_configured")
}

func TestOAuthSync(t *testing.T) {
	for name, c := range map[string]struct {
		env  map[string]string
		auth func(*http.Request) bool
	}{
		"token":      {map[string]string{"CF_ACCOUNT_ID": "acc", "CF_API_TOKEN": "cf-token-secret"}, bearer},
		"global key": {map[string]string{"CF_ACCOUNT_ID": "acc", "CF_API_EMAIL": "ops@example.com", "CF_API_KEY": "cf-global-secret"}, globalKey},
	} {
		t.Run(name, func(t *testing.T) {
			cf := newFakeCF(t, c.auth)
			var log bytes.Buffer
			c.env["OAUTH_SCOPES"] = "env:read"
			h := oauthHarness(t, cf, c.env, &log)
			m := h.oauthConfig(200)
			if m["source"] != "cloudflare" || m["client_id"] != defaultClientID || list(m["scopes"]) != "account:read zone:read dns:edit" ||
				list(m["optional_scopes"]) != "workers:write" {
				t.Fatalf("config = %v", m)
			}
			if !strings.Contains(log.String(), "oauth scopes synced") || !strings.Contains(log.String(), "scopes=3") {
				t.Fatalf("log = %s", log.String())
			}
			for _, secret := range []string{"cf-token-secret", "cf-global-secret"} {
				if strings.Contains(log.String(), secret) || strings.Contains(h.get("/api/v1/oauth/config").Body.String(), secret) {
					t.Fatal("credentials leaked")
				}
			}
		})
	}
	// Wrong credentials: the Cloudflare error is logged, OAUTH_SCOPES is served.
	cf := newFakeCF(t, globalKey)
	var log bytes.Buffer
	h := oauthHarness(t, cf, map[string]string{"CF_ACCOUNT_ID": "acc", "CF_API_TOKEN": "cf-token-secret", "OAUTH_SCOPES": "env:read"}, &log)
	if m := h.oauthConfig(200); m["source"] != "env" || list(m["scopes"]) != "env:read" {
		t.Fatalf("config = %v", m)
	}
	if !strings.Contains(log.String(), "Authentication error") || strings.Contains(log.String(), "cf-token-secret") {
		t.Fatalf("log = %s", log.String())
	}
}

func TestOAuthSyncCacheAndErrors(t *testing.T) {
	cf := newFakeCF(t, bearer)
	h := oauthHarness(t, cf, map[string]string{"CF_ACCOUNT_ID": "acc", "CF_API_TOKEN": "cf-token-secret"}, nil)
	h.oauthConfig(200)
	h.oauthConfig(200)
	h.advance(59 * time.Minute)
	h.oauthConfig(200)
	if n := cf.hits.Load(); n != 1 {
		t.Fatalf("fetched %d times within the hour", n)
	}

	// After an hour the next request refreshes.
	cf.set(200, `{"success":true,"result":{"scopes":["account:read"],"optional_scopes":[]}}`)
	h.advance(2 * time.Minute)
	if m := h.oauthConfig(200); cf.hits.Load() != 2 || list(m["scopes"]) != "account:read" || len(m["optional_scopes"].([]any)) != 0 {
		t.Fatalf("after refresh: %v (%d fetches)", m, cf.hits.Load())
	}

	// Errors keep the last good value and are retried after a minute.
	h.advance(61 * time.Minute)
	for _, bad := range []struct {
		status int
		body   string
	}{
		{500, `{"success":false,"errors":[{"code":1,"message":"boom"}]}`},
		{200, `not json`},
		{200, `{"success":true,"result":{"scopes":["offline_access"]}}`},
	} {
		cf.set(bad.status, bad.body)
		before := cf.hits.Load()
		if m := h.oauthConfig(200); m["source"] != "cloudflare" || list(m["scopes"]) != "account:read" {
			t.Fatalf("%s: %v", bad.body, m)
		}
		h.oauthConfig(200)
		if cf.hits.Load() != before+1 {
			t.Fatalf("%s: retried at once", bad.body)
		}
		h.advance(61 * time.Second)
	}
	cf.set(200, `{"success":true,"result":{"scopes":["zone:read"]}}`)
	if m := h.oauthConfig(200); list(m["scopes"]) != "zone:read" {
		t.Fatalf("recovered: %v", m)
	}
}

func TestOAuthSyncSingleFlight(t *testing.T) {
	cf := newFakeCF(t, bearer)
	release := make(chan struct{})
	cf.release = release
	h := oauthHarness(t, cf, map[string]string{"CF_ACCOUNT_ID": "acc", "CF_API_TOKEN": "cf-token-secret"}, nil)
	var wg sync.WaitGroup
	results := make([]string, 8)
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			rec := httptest.NewRecorder()
			h.app.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/oauth/config", nil))
			results[i] = rec.Body.String()
		}(i)
	}
	for cf.hits.Load() == 0 {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond)
	close(release)
	wg.Wait()
	if n := cf.hits.Load(); n != 1 {
		t.Fatalf("%d fetches for concurrent requests", n)
	}
	for _, r := range results {
		if !strings.Contains(r, `"source":"cloudflare"`) {
			t.Fatalf("response = %s", r)
		}
	}
}
