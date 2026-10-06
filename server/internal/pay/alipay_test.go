package pay

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	keysOnce          sync.Once
	appKey, alipayKey *rsa.PrivateKey
)

// Two locally generated key pairs: the merchant app's, and one standing in
// for Alipay's.
func testKeys(t *testing.T) (*rsa.PrivateKey, *rsa.PrivateKey) {
	t.Helper()
	keysOnce.Do(func() {
		var err error
		if appKey, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
			panic(err)
		}
		if alipayKey, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
			panic(err)
		}
	})
	return appKey, alipayKey
}

func pkcs8Base64(k *rsa.PrivateKey) string {
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	return base64.StdEncoding.EncodeToString(der)
}

func pkixBase64(k *rsa.PublicKey) string {
	der, _ := x509.MarshalPKIXPublicKey(k)
	return base64.StdEncoding.EncodeToString(der)
}

func TestContent(t *testing.T) {
	p := url.Values{
		"timestamp":   {"2026-10-06 12:00:00"},
		"app_id":      {"2021000000000000"},
		"sign":        {"xxx"},
		"sign_type":   {"RSA2"},
		"empty":       {""},
		"biz_content": {`{"a":"b c&d"}`},
	}
	got := Content(p, "sign")
	want := `app_id=2021000000000000&biz_content={"a":"b c&d"}&sign_type=RSA2&timestamp=2026-10-06 12:00:00`
	if got != want {
		t.Fatalf("Content =\n%s\nwant\n%s", got, want)
	}
	if got := Content(p, "sign", "sign_type"); strings.Contains(got, "sign_type") {
		t.Fatalf("sign_type not excluded: %s", got)
	}
}

func TestSignVerify(t *testing.T) {
	app, other := testKeys(t)
	sig, err := Sign(app, "a=1&b=2")
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(&app.PublicKey, "a=1&b=2", sig); err != nil {
		t.Fatalf("verify: %v", err)
	}
	if Verify(&app.PublicKey, "a=1&b=3", sig) == nil {
		t.Fatal("verified altered content")
	}
	if Verify(&other.PublicKey, "a=1&b=2", sig) == nil {
		t.Fatal("verified with the wrong key")
	}
	if Verify(&app.PublicKey, "a=1&b=2", "!!!") == nil {
		t.Fatal("verified non-base64 signature")
	}
	// PKCS#1 v1.5 is deterministic.
	sig2, _ := Sign(app, "a=1&b=2")
	if sig2 != sig {
		t.Fatal("RSA2 signature not deterministic")
	}
}

func TestParseKeys(t *testing.T) {
	app, _ := testKeys(t)
	pkcs1 := x509.MarshalPKCS1PrivateKey(app)
	pkcs8, _ := x509.MarshalPKCS8PrivateKey(app)
	privForms := []string{
		pkcs8Base64(app),
		base64.StdEncoding.EncodeToString(pkcs1),
		string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: pkcs1})),
		string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8})),
		strings.ReplaceAll(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8})), "\n", `\n`),
	}
	for i, s := range privForms {
		k, err := ParsePrivateKey(s)
		if err != nil || !k.Equal(app) {
			t.Errorf("private form %d: %v", i, err)
		}
	}
	pkix, _ := x509.MarshalPKIXPublicKey(&app.PublicKey)
	pubForms := []string{
		pkixBase64(&app.PublicKey),
		base64.StdEncoding.EncodeToString(x509.MarshalPKCS1PublicKey(&app.PublicKey)),
		string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pkix})),
	}
	for i, s := range pubForms {
		k, err := ParsePublicKey(s)
		if err != nil || !k.Equal(&app.PublicKey) {
			t.Errorf("public form %d: %v", i, err)
		}
	}
	for _, bad := range []string{"", "not base64!", base64.StdEncoding.EncodeToString([]byte("junk"))} {
		if _, err := ParsePrivateKey(bad); err == nil {
			t.Errorf("ParsePrivateKey(%q) succeeded", bad)
		}
		if _, err := ParsePublicKey(bad); err == nil {
			t.Errorf("ParsePublicKey(%q) succeeded", bad)
		}
	}
}

// fakeGateway checks the request the way Alipay does (signature with the
// app's public key) and answers with a response signed by "Alipay".
func fakeGateway(t *testing.T, app, ali *rsa.PrivateKey, respond func(form url.Values) (obj string, sign bool)) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || !strings.HasPrefix(r.Header.Get("Content-Type"), "application/x-www-form-urlencoded") {
			t.Errorf("bad request %s %s", r.Method, r.Header.Get("Content-Type"))
		}
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if err := Verify(&app.PublicKey, Content(r.PostForm, "sign"), r.PostForm.Get("sign")); err != nil {
			t.Errorf("request signature: %v", err)
			w.Write([]byte(`{"alipay_trade_precreate_response":{"code":"40002","msg":"Invalid Arguments","sub_code":"isv.invalid-signature"}}`))
			return
		}
		obj, sign := respond(r.PostForm)
		body := `{"alipay_trade_precreate_response":` + obj
		if sign {
			s, _ := Sign(ali, obj)
			body += `,"sign":"` + s + `"`
		}
		w.Header().Set("Content-Type", "text/html;charset=utf-8")
		w.Write([]byte(body + "}"))
	}))
}

func newTestAlipay(t *testing.T, gateway string) *Alipay {
	t.Helper()
	app, ali := testKeys(t)
	a, err := NewAlipay("2021000000000001", pkcs8Base64(app), pkixBase64(&ali.PublicKey), gateway, "https://cirrus.example/pay/alipay/notify")
	if err != nil {
		t.Fatal(err)
	}
	a.Now = func() time.Time { return time.Date(2026, 10, 6, 4, 5, 6, 0, time.UTC) }
	return a
}

func TestPrecreate(t *testing.T) {
	app, ali := testKeys(t)
	var got url.Values
	gw := fakeGateway(t, app, ali, func(f url.Values) (string, bool) {
		got = f
		var biz map[string]string
		json.Unmarshal([]byte(f.Get("biz_content")), &biz)
		return fmt.Sprintf(`{"code":"10000","msg":"Success","out_trade_no":"%s","qr_code":"https:\/\/qr.alipay.com\/bax0123"}`, biz["out_trade_no"]), true
	})
	defer gw.Close()
	a := newTestAlipay(t, gw.URL)

	info, err := a.Create(context.Background(), Order{No: "C261006123456", Subject: "卷云 Cirrus Pro · Windows", AmountCents: 19800})
	if err != nil {
		t.Fatal(err)
	}
	if info.Type != TypeQR || info.QRText != "https://qr.alipay.com/bax0123" {
		t.Fatalf("info = %+v", info)
	}
	checks := map[string]string{
		"app_id": "2021000000000001", "method": "alipay.trade.precreate", "format": "JSON", "charset": "utf-8",
		"sign_type": "RSA2", "version": "1.0", "timestamp": "2026-10-06 12:05:06",
		"notify_url": "https://cirrus.example/pay/alipay/notify",
	}
	for k, v := range checks {
		if got.Get(k) != v {
			t.Errorf("param %s = %q, want %q", k, got.Get(k), v)
		}
	}
	var biz map[string]string
	if err := json.Unmarshal([]byte(got.Get("biz_content")), &biz); err != nil {
		t.Fatal(err)
	}
	if biz["out_trade_no"] != "C261006123456" || biz["total_amount"] != "198.00" || biz["subject"] != "卷云 Cirrus Pro · Windows" {
		t.Errorf("biz_content = %v", biz)
	}
}

func TestPageURL(t *testing.T) {
	app, _ := testKeys(t)
	a := newTestAlipay(t, "https://openapi-sandbox.dl.alipaydev.com/gateway.do")
	a.Mode = ModePage
	if a.Name() != "alipay_page" || a.TTL() != 2*time.Hour {
		t.Fatal("page provider name/ttl")
	}
	for _, mobile := range []bool{false, true} {
		info, err := a.Create(context.Background(), Order{No: "C261006000001", Subject: "卷云 Cirrus Pro - Linux",
			AmountCents: 19800, ReturnURL: "https://cirrus.example/buy?order=C261006000001", Mobile: mobile})
		if err != nil {
			t.Fatal(err)
		}
		if info.Type != TypeRedirect || !strings.HasPrefix(info.URL, "https://openapi-sandbox.dl.alipaydev.com/gateway.do?") {
			t.Fatalf("info = %+v", info)
		}
		u, _ := url.Parse(info.URL)
		q := u.Query()
		// Alipay verifies the request with the app's public key.
		if err := Verify(&app.PublicKey, Content(q, "sign"), q.Get("sign")); err != nil {
			t.Fatalf("mobile=%v: signature: %v", mobile, err)
		}
		wantMethod, wantProduct := "alipay.trade.page.pay", "FAST_INSTANT_TRADE_PAY"
		if mobile {
			wantMethod, wantProduct = "alipay.trade.wap.pay", "QUICK_WAP_WAY"
		}
		var biz map[string]string
		json.Unmarshal([]byte(q.Get("biz_content")), &biz)
		if q.Get("method") != wantMethod || biz["product_code"] != wantProduct || biz["total_amount"] != "198.00" ||
			biz["out_trade_no"] != "C261006000001" || q.Get("sign_type") != "RSA2" ||
			q.Get("notify_url") != "https://cirrus.example/pay/alipay/notify" ||
			q.Get("return_url") != "https://cirrus.example/buy?order=C261006000001" {
			t.Fatalf("mobile=%v: params %v biz %v", mobile, q, biz)
		}
		if mobile != (biz["quit_url"] != "") {
			t.Errorf("quit_url only on wap: %v", biz)
		}
		// Any change to a signed parameter breaks the signature.
		q.Set("biz_content", strings.Replace(q.Get("biz_content"), "198.00", "0.01", 1))
		if Verify(&app.PublicKey, Content(q, "sign"), q.Get("sign")) == nil {
			t.Fatal("tampered page URL verified")
		}
	}
}

func TestPrecreateErrors(t *testing.T) {
	app, ali := testKeys(t)
	cases := map[string]func(url.Values) (string, bool){
		"business error": func(url.Values) (string, bool) {
			return `{"code":"40004","msg":"Business Failed","sub_code":"ACQ.TRADE_HAS_SUCCESS"}`, true
		},
		"unsigned success": func(url.Values) (string, bool) {
			return `{"code":"10000","msg":"Success","out_trade_no":"C1","qr_code":"x"}`, false
		},
		"wrong trade no": func(url.Values) (string, bool) {
			return `{"code":"10000","msg":"Success","out_trade_no":"C2","qr_code":"x"}`, true
		},
		"missing qr code":   func(url.Values) (string, bool) { return `{"code":"10000","msg":"Success","out_trade_no":"C1"}`, true },
		"not json response": func(url.Values) (string, bool) { return `nope`, false },
	}
	for name, respond := range cases {
		t.Run(name, func(t *testing.T) {
			gw := fakeGateway(t, app, ali, respond)
			defer gw.Close()
			if _, err := newTestAlipay(t, gw.URL).Create(context.Background(), Order{No: "C1", Subject: "s", AmountCents: 100}); err == nil {
				t.Fatal("expected an error")
			}
		})
	}

	// A response signed by someone other than Alipay is rejected.
	forger, _ := rsa.GenerateKey(rand.Reader, 2048)
	gw := fakeGateway(t, app, forger, func(url.Values) (string, bool) {
		return `{"code":"10000","msg":"Success","out_trade_no":"C1","qr_code":"https://qr.alipay.com/evil"}`, true
	})
	defer gw.Close()
	if _, err := newTestAlipay(t, gw.URL).Create(context.Background(), Order{No: "C1", Subject: "s", AmountCents: 100}); err == nil {
		t.Fatal("forged response accepted")
	}
}

// SignNotify signs a notification the way Alipay does (all params except
// sign and sign_type).
func signNotify(t *testing.T, key *rsa.PrivateKey, form url.Values) url.Values {
	t.Helper()
	form.Set("sign_type", "RSA2")
	s, err := Sign(key, Content(form, "sign", "sign_type"))
	if err != nil {
		t.Fatal(err)
	}
	form.Set("sign", s)
	return form
}

func TestVerifyNotify(t *testing.T) {
	_, ali := testKeys(t)
	a := newTestAlipay(t, "http://unused")
	form := signNotify(t, ali, url.Values{
		"notify_time": {"2026-10-06 12:10:00"}, "notify_type": {"trade_status_sync"}, "notify_id": {"n1"},
		"app_id": {"2021000000000001"}, "charset": {"utf-8"}, "version": {"1.0"},
		"trade_no": {"2026100622001400000000000001"}, "out_trade_no": {"C1"}, "trade_status": {"TRADE_SUCCESS"},
		"total_amount": {"198.00"}, "subject": {"卷云 Cirrus Pro"},
		"fund_bill_list": {`[{"amount":"198.00","fundChannel":"ALIPAYACCOUNT"}]`},
	})
	if err := a.VerifyNotify(form); err != nil {
		t.Fatalf("verify: %v", err)
	}
	tampered := url.Values{}
	for k, v := range form {
		tampered[k] = append([]string(nil), v...)
	}
	tampered.Set("total_amount", "0.01")
	if a.VerifyNotify(tampered) == nil {
		t.Fatal("tampered notification verified")
	}
	app, _ := testKeys(t)
	if a.VerifyNotify(signNotify(t, app, url.Values{"out_trade_no": {"C1"}})) == nil {
		t.Fatal("notification signed with the wrong key verified")
	}
	noSig := url.Values{"out_trade_no": {"C1"}}
	if a.VerifyNotify(noSig) == nil {
		t.Fatal("unsigned notification verified")
	}
	rsa1 := signNotify(t, ali, url.Values{"out_trade_no": {"C1"}})
	rsa1.Set("sign_type", "RSA")
	if a.VerifyNotify(rsa1) == nil {
		t.Fatal("sign_type RSA accepted")
	}
}

func TestStatic(t *testing.T) {
	dir := t.TempDir()
	s := NewStatic("wechat", dir)
	if s.Available() {
		t.Fatal("available without image")
	}
	os.MkdirAll(filepath.Join(dir, "pay"), 0o755)
	os.WriteFile(filepath.Join(dir, "pay", "wechat.png"), []byte("png"), 0o644)
	if !s.Available() || s.TTL() != 24*time.Hour || s.Name() != "manual" {
		t.Fatal("static provider")
	}
	info, _ := s.Create(context.Background(), Order{No: "C1"})
	if info.Type != TypeStaticQR || info.QRImage != "/static/pay/wechat.png" {
		t.Fatalf("info %+v", info)
	}
}
