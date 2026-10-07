package app

import (
	"crypto/ed25519"
	"encoding/base64"
	"net/http"
	"strings"
	"testing"
	"time"

	"cirrus/server/internal/license"
)

func TestPubkeyAndHealth(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	m := expect(t, h.get("/api/v1/pubkey"), 200, "")
	if m["ed25519"] != vectorPubB64 {
		t.Fatalf("pubkey = %v", m["ed25519"])
	}
	if rec := h.get("/healthz"); rec.Code != 200 {
		t.Fatalf("healthz %d", rec.Code)
	}
	expect(t, h.get("/api/v1/nope"), 404, "not_found")
}

func TestActivate(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	l := h.issue("cirrus-linux", "Qing@Example.com")
	pubRaw, _ := base64.StdEncoding.DecodeString(vectorPubB64)
	pub := ed25519.PublicKey(pubRaw)

	// Success, with a key typed sloppily.
	sloppy := strings.ToLower(strings.ReplaceAll(l.Key, "-", " "))
	m := expect(t, h.post("/api/v1/activate", activateBody(sloppy, dev(1), "linux")), 200, "")
	claims, err := license.Verify(pub, m["activation"].(string))
	if err != nil {
		t.Fatalf("token: %v", err)
	}
	if claims.V != 1 || claims.Lic != l.ID || claims.Product != "cirrus-linux" || claims.Platform != "linux" ||
		claims.Device != dev(1) || claims.Owner != "q***@example.com" || claims.Iat != h.clock().Unix() {
		t.Fatalf("claims = %+v", claims)
	}
	lic := m["license"].(map[string]any)
	if lic["product"] != "cirrus-linux" || lic["platform"] != "linux" || lic["max_devices"] != 1.0 || lic["devices_used"] != 1.0 {
		t.Fatalf("license = %v", lic)
	}

	// Idempotent re-activation: a fresh token, no extra slot.
	h.advance(time.Hour)
	m = expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(1), "linux")), 200, "")
	if m["license"].(map[string]any)["devices_used"] != 1.0 {
		t.Fatal("re-activation used another slot")
	}
	c2, _ := license.Verify(pub, m["activation"].(string))
	if c2.Iat != claims.Iat+3600 {
		t.Fatal("re-activation did not issue a fresh token")
	}

	// Limit reached: 409 with the device list.
	m = expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(2), "linux")), 409, "activation_limit")
	devs := m["devices"].([]any)
	if len(devs) != 1 {
		t.Fatalf("devices = %v", devs)
	}
	d := devs[0].(map[string]any)
	if d["name"] != "host-"+dev(1)[:6] {
		t.Fatalf("device = %v", d)
	}
	if at, err := time.Parse(time.RFC3339, d["activated_at"].(string)); err != nil || !at.Equal(h.clock().Add(-time.Hour)) || !strings.HasSuffix(d["activated_at"].(string), "Z") {
		t.Fatalf("activated_at = %v (%v)", d["activated_at"], err)
	}

	// Wrong platform: 403 naming the licence's platform.
	m = expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(3), "windows")), 403, "wrong_platform")
	if m["platform"] != "linux" {
		t.Fatalf("platform = %v", m["platform"])
	}

	// Invalid keys.
	expect(t, h.post("/api/v1/activate", activateBody("CIRRUS-NOPE", dev(1), "linux")), 404, "invalid_key")
	other, _ := license.NewKey()
	expect(t, h.post("/api/v1/activate", activateBody(other, dev(1), "linux")), 404, "invalid_key")

	// Malformed requests.
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, "not-a-device", "linux")), 400, "bad_request")
	expect(t, h.post("/api/v1/activate", "{nope"), 400, "bad_request")

	// Revoked.
	h.st.SetRevoked(t.Context(), l.ID, true, h.clock())
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(1), "linux")), 410, "revoked")
}

func TestDeactivateAndValidate(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	l := h.issue("cirrus-windows", "a@example.com")
	kd := func(device string) map[string]string {
		return map[string]string{"license_key": l.Key, "device_id": device}
	}
	status := func() string {
		return expect(t, h.post("/api/v1/validate", kd(dev(1))), 200, "")["status"].(string)
	}

	if s := status(); s != "not_activated" {
		t.Fatalf("before activation: %s", s)
	}
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(1), "windows")), 200, "")
	if s := status(); s != "active" {
		t.Fatalf("after activation: %s", s)
	}
	if m := expect(t, h.post("/api/v1/deactivate", kd(dev(1))), 200, ""); m["ok"] != true {
		t.Fatalf("deactivate: %v", m)
	}
	if s := status(); s != "not_activated" {
		t.Fatalf("after deactivation: %s", s)
	}
	// Deactivating a device that is not activated is fine.
	expect(t, h.post("/api/v1/deactivate", kd(dev(9))), 200, "")
	// The freed slot can be used by another device.
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(2), "windows")), 200, "")

	expect(t, h.post("/api/v1/deactivate", map[string]string{"license_key": "x", "device_id": dev(1)}), 404, "invalid_key")
	expect(t, h.post("/api/v1/validate", map[string]string{"license_key": "x", "device_id": dev(1)}), 404, "invalid_key")

	h.st.SetRevoked(t.Context(), l.ID, true, h.clock())
	if s := expect(t, h.post("/api/v1/validate", kd(dev(2))), 200, "")["status"]; s != "revoked" {
		t.Fatalf("revoked licence: %v", s)
	}
}

func TestReset(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	l := h.issue("cirrus-android", "owner@example.com")
	for i := 1; i <= 3; i++ {
		expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(i), "android")), 200, "")
	}
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(4), "android")), 409, "activation_limit")

	body := func(email string) map[string]string { return map[string]string{"license_key": l.Key, "email": email} }
	expect(t, h.post("/api/v1/reset", body("someone@else.com")), 403, "email_mismatch")
	expect(t, h.post("/api/v1/reset", map[string]string{"license_key": "bad", "email": "owner@example.com"}), 404, "invalid_key")

	expect(t, h.post("/api/v1/reset", body("  Owner@Example.COM ")), 200, "")
	got, _ := h.st.LicenseByID(t.Context(), l.ID)
	if got.DevicesUsed != 0 {
		t.Fatalf("devices after reset: %d", got.DevicesUsed)
	}
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(4), "android")), 200, "")

	// Once per 30 days.
	h.advance(time.Hour)
	m := expect(t, h.post("/api/v1/reset", body("owner@example.com")), 429, "too_soon")
	if m["retry_after_days"] != 30.0 {
		t.Fatalf("retry_after_days = %v", m["retry_after_days"])
	}
	h.advance(29 * 24 * time.Hour)
	m = expect(t, h.post("/api/v1/reset", body("owner@example.com")), 429, "too_soon")
	if m["retry_after_days"] != 1.0 {
		t.Fatalf("retry_after_days = %v", m["retry_after_days"])
	}
	h.advance(23 * time.Hour) // exactly 30 days after the first reset
	expect(t, h.post("/api/v1/reset", body("owner@example.com")), 200, "")
}

func TestRateLimit(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	body := map[string]string{"license_key": "CIRRUS-00000-00000-00000-00000", "email": "a@example.com"}
	for i := 0; i < 5; i++ {
		expect(t, h.post("/api/v1/reset", body), 404, "invalid_key")
	}
	rec := h.post("/api/v1/reset", body)
	expect(t, rec, http.StatusTooManyRequests, "rate_limited")
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("no Retry-After header")
	}
	// Another client behind the proxy has its own bucket.
	proxied := map[string]string{"RemoteAddr": "172.18.0.1:5000", "X-Real-IP": "203.0.113.7"}
	expect(t, h.do("POST", "/api/v1/reset", body, proxied), 404, "invalid_key")
	// Forwarding headers from a public peer are ignored.
	spoof := map[string]string{"X-Real-IP": "198.51.100.1", "X-Forwarded-For": "198.51.100.2"}
	expect(t, h.do("POST", "/api/v1/reset", body, spoof), http.StatusTooManyRequests, "rate_limited")
	// Tokens refill.
	h.advance(11 * time.Minute)
	expect(t, h.post("/api/v1/reset", body), 404, "invalid_key")
}

func TestClientIP(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	cases := []struct {
		remote string
		hdr    map[string]string
		want   string
	}{
		{"203.0.113.9:1", nil, "203.0.113.9"},
		{"203.0.113.9:1", map[string]string{"X-Real-IP": "1.1.1.1"}, "203.0.113.9"},
		{"127.0.0.1:1", map[string]string{"X-Real-IP": "1.1.1.1"}, "1.1.1.1"},
		{"172.17.0.1:1", map[string]string{"X-Forwarded-For": "9.9.9.9, 2.2.2.2"}, "2.2.2.2"},
		{"10.0.0.1:1", map[string]string{"X-Real-IP": "garbage"}, "10.0.0.1"},
	}
	for _, c := range cases {
		r, _ := http.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.remote
		for k, v := range c.hdr {
			r.Header.Set(k, v)
		}
		if got := h.app.clientIP(r); got != c.want {
			t.Errorf("clientIP(%s %v) = %s, want %s", c.remote, c.hdr, got, c.want)
		}
	}

	// Behind a CDN: its header wins over the reverse proxy's X-Real-IP (the
	// CDN node), but only from the reverse proxy and only when it parses.
	h.cfg.ClientIPHeader = "EO-Connecting-IP"
	cdn := []struct {
		remote string
		hdr    map[string]string
		want   string
	}{
		{"127.0.0.1:1", map[string]string{"EO-Connecting-IP": "8.8.8.8", "X-Real-IP": "43.174.246.1"}, "8.8.8.8"},
		{"127.0.0.1:1", map[string]string{"EO-Connecting-IP": "x", "X-Real-IP": "43.174.246.1"}, "43.174.246.1"},
		{"203.0.113.9:1", map[string]string{"EO-Connecting-IP": "8.8.8.8"}, "203.0.113.9"},
	}
	for _, c := range cdn {
		r, _ := http.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.remote
		for k, v := range c.hdr {
			r.Header.Set(k, v)
		}
		if got := h.app.clientIP(r); got != c.want {
			t.Errorf("CLIENT_IP_HEADER: clientIP(%s %v) = %s, want %s", c.remote, c.hdr, got, c.want)
		}
	}

	h.cfg.TrustProxy = false
	r, _ := http.NewRequest("GET", "/", nil)
	r.RemoteAddr = "127.0.0.1:1"
	r.Header.Set("X-Real-IP", "1.1.1.1")
	r.Header.Set("EO-Connecting-IP", "8.8.8.8")
	if got := h.app.clientIP(r); got != "127.0.0.1" {
		t.Errorf("TRUST_PROXY off: %s", got)
	}
}
