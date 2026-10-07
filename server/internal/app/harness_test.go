package app

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"cirrus/server/internal/config"
	"cirrus/server/internal/license"
	"cirrus/server/internal/pay"
	"cirrus/server/internal/store"
)

// The test vector's key, so tokens can be checked against its public key.
const (
	vectorSeed   = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	vectorPubB64 = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
	adminPass    = "correct horse battery staple"
	testICP      = "沪ICP备00000000号-1"
)

type sentMail struct{ To, Subject, Body string }

type fakeMailer struct {
	mu   sync.Mutex
	sent []sentMail
}

func (f *fakeMailer) Send(_ context.Context, to, subject, body string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, sentMail{to, subject, body})
	return nil
}

func (f *fakeMailer) all() []sentMail {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]sentMail(nil), f.sent...)
}

type harness struct {
	t    *testing.T
	app  *App
	st   *store.Store
	cfg  *config.Config
	mail *fakeMailer
	dir  string

	mu  sync.Mutex
	now time.Time
}

type harnessOpt struct {
	env    map[string]string
	noMail bool
	alipay *pay.Alipay
	wechat *pay.WeChat
	noQR   []string             // static QR images not to create
	cfg    func(*config.Config) // adjusts the loaded configuration
	log    io.Writer            // server log (default: discarded)
}

func newHarness(t *testing.T, o harnessOpt) *harness {
	t.Helper()
	dir := t.TempDir()
	env := map[string]string{
		"DATA_DIR":       dir,
		"PUBLIC_URL":     "https://cirrus.test",
		"ADMIN_PASSWORD": adminPass,
		"CONTACT_EMAIL":  "support@cirrus.test",
		"OPERATOR_NAME":  "测试个体户",
		"ICP_NUMBER":     testICP,
	}
	for k, v := range o.env {
		env[k] = v
	}
	cfg, err := config.Load(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	if o.cfg != nil {
		o.cfg(cfg)
	}
	if o.log == nil {
		o.log = io.Discard
	}
	os.MkdirAll(filepath.Join(dir, "pay"), 0o755)
	for _, m := range []string{"alipay", "wechat"} {
		skip := false
		for _, n := range o.noQR {
			skip = skip || n == m
		}
		if !skip {
			os.WriteFile(filepath.Join(dir, "pay", m+".png"), []byte("\x89PNG fake "+m), 0o644)
		}
	}
	st, err := store.Open(filepath.Join(dir, "cirrus.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	seed, _ := hex.DecodeString(vectorSeed)
	h := &harness{t: t, st: st, cfg: cfg, dir: dir, now: time.Date(2026, 10, 6, 10, 0, 0, 0, time.UTC)}
	if o.alipay != nil {
		o.alipay.Now = h.clock
	}
	if o.wechat != nil {
		o.wechat.Now = h.clock
	}
	opts := Options{
		Config: cfg, Store: st, Key: ed25519.NewKeyFromSeed(seed), Alipay: o.alipay, WeChat: o.wechat,
		Logger: slog.New(slog.NewTextHandler(o.log, nil)), Now: h.clock,
	}
	if !o.noMail {
		h.mail = &fakeMailer{}
		opts.Mailer = h.mail
	}
	h.app, err = New(opts)
	if err != nil {
		t.Fatal(err)
	}
	h.app.SetLimiterClock(h.clock)
	return h
}

func (h *harness) clock() time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.now
}

func (h *harness) advance(d time.Duration) {
	h.mu.Lock()
	h.now = h.now.Add(d)
	h.mu.Unlock()
}

// do sends a request; body may be nil, a string (sent as is) or a value
// (sent as JSON).
func (h *harness) do(method, path string, body any, hdr map[string]string) *httptest.ResponseRecorder {
	h.t.Helper()
	var r io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		r = strings.NewReader(b)
	default:
		j, _ := json.Marshal(b)
		r = bytes.NewReader(j)
	}
	req := httptest.NewRequest(method, path, r)
	if _, isJSON := body.(string); body != nil && !isJSON {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range hdr {
		if k == "RemoteAddr" {
			req.RemoteAddr = v
			continue
		}
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.app.Handler().ServeHTTP(rec, req)
	return rec
}

func (h *harness) post(path string, body any) *httptest.ResponseRecorder {
	return h.do(http.MethodPost, path, body, nil)
}

func (h *harness) get(path string) *httptest.ResponseRecorder {
	return h.do(http.MethodGet, path, nil, nil)
}

func decode(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("response is not JSON (%d): %s", rec.Code, rec.Body.String())
	}
	return m
}

// expect checks the status and, when code is not empty, the error code.
func expect(t *testing.T, rec *httptest.ResponseRecorder, status int, code string) map[string]any {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("status = %d, want %d: %s", rec.Code, status, rec.Body.String())
	}
	m := decode(t, rec)
	if code != "" {
		if m["error"] != code {
			t.Fatalf("error = %v, want %s", m["error"], code)
		}
		if msg, _ := m["message"].(string); msg == "" {
			t.Fatalf("error without message: %v", m)
		}
	}
	return m
}

func (h *harness) issue(product, email string) store.License {
	h.t.Helper()
	p, ok := h.cfg.Product(product)
	if !ok {
		h.t.Fatalf("unknown product %s", product)
	}
	l, err := h.st.CreateLicense(context.Background(), store.NewLicense{
		Product: p.ID, Platform: p.Platform, MaxDevices: p.MaxDevices, Email: email,
	}, h.clock())
	if err != nil {
		h.t.Fatal(err)
	}
	return l
}

func dev(n int) string { return license.DeviceID("machine-" + itoa(n)) }

func activateBody(key, device, platform string) map[string]string {
	return map[string]string{"license_key": key, "device_id": device, "device_name": "host-" + device[:6],
		"platform": platform, "app_version": "1.2.3"}
}

// admin performs an authenticated admin request. POSTs carry the CSRF
// cookie, form token and a same-origin Origin header.
func (h *harness) admin(method, path string, form url.Values) *httptest.ResponseRecorder {
	h.t.Helper()
	tok := strings.Repeat("ab", 16)
	var body io.Reader
	if form != nil {
		form.Set("csrf", tok)
		body = strings.NewReader(form.Encode())
	}
	req := httptest.NewRequest(method, path, body)
	req.SetBasicAuth("admin", adminPass)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", "http://example.com")
		req.AddCookie(&http.Cookie{Name: csrfCookie, Value: tok})
	}
	rec := httptest.NewRecorder()
	h.app.Handler().ServeHTTP(rec, req)
	return rec
}

// Alipay test keys: the merchant app's key pair and one standing in for
// Alipay's.
var (
	rsaOnce          sync.Once
	appRSA, aliRSA   *rsa.PrivateKey
	testAlipayAppID  = "2021000000000001"
	testAlipayPublic string
)

func alipayKeys(t *testing.T) (*rsa.PrivateKey, *rsa.PrivateKey) {
	t.Helper()
	rsaOnce.Do(func() {
		appRSA, _ = rsa.GenerateKey(rand.Reader, 2048)
		aliRSA, _ = rsa.GenerateKey(rand.Reader, 2048)
		der, _ := x509.MarshalPKIXPublicKey(&aliRSA.PublicKey)
		testAlipayPublic = base64.StdEncoding.EncodeToString(der)
	})
	return appRSA, aliRSA
}

func newAlipay(t *testing.T, gateway, mode string) *pay.Alipay {
	t.Helper()
	app, _ := alipayKeys(t)
	der, _ := x509.MarshalPKCS8PrivateKey(app)
	a, err := pay.NewAlipay(testAlipayAppID, base64.StdEncoding.EncodeToString(der), testAlipayPublic, gateway,
		"https://cirrus.test/pay/alipay/notify")
	if err != nil {
		t.Fatal(err)
	}
	a.Mode = mode
	return a
}

// fakeGateway answers alipay.trade.precreate like Alipay would.
func fakeGateway(t *testing.T, fail bool) *httptest.Server {
	t.Helper()
	app, ali := alipayKeys(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		if err := pay.Verify(&app.PublicKey, pay.Content(r.PostForm, "sign"), r.PostForm.Get("sign")); err != nil {
			t.Errorf("gateway: bad request signature: %v", err)
		}
		var biz map[string]string
		json.Unmarshal([]byte(r.PostForm.Get("biz_content")), &biz)
		obj := `{"code":"10000","msg":"Success","out_trade_no":"` + biz["out_trade_no"] + `","qr_code":"https://qr.alipay.com/bax` + biz["out_trade_no"] + `"}`
		if fail {
			obj = `{"code":"40004","msg":"Business Failed","sub_code":"ACQ.ACCESS_FORBIDDEN","sub_msg":"no permission"}`
		}
		sig, _ := pay.Sign(ali, obj)
		w.Write([]byte(`{"alipay_trade_precreate_response":` + obj + `,"sign":"` + sig + `"}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// notify posts an Alipay notification signed with key.
func (h *harness) notify(key *rsa.PrivateKey, form url.Values) *httptest.ResponseRecorder {
	h.t.Helper()
	form.Set("sign_type", "RSA2")
	sig, err := pay.Sign(key, pay.Content(form, "sign", "sign_type"))
	if err != nil {
		h.t.Fatal(err)
	}
	form.Set("sign", sig)
	return h.do(http.MethodPost, "/pay/alipay/notify", form.Encode(), map[string]string{
		"Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
	})
}

func notifyForm(orderNo, amount, status string) url.Values {
	return url.Values{
		"notify_time": {"2026-10-06 18:05:00"}, "notify_type": {"trade_status_sync"}, "notify_id": {"n-" + orderNo},
		"app_id": {testAlipayAppID}, "charset": {"utf-8"}, "version": {"1.0"},
		"trade_no": {"2026100622001400000000" + orderNo[len(orderNo)-6:]}, "out_trade_no": {orderNo},
		"trade_status": {status}, "total_amount": {amount}, "receipt_amount": {amount},
		"subject": {"卷云 Cirrus Pro - Windows"}, "buyer_logon_id": {"q***@example.com"},
	}
}
