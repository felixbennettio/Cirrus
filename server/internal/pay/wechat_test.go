package pay

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

const (
	testMchID     = "1900000001"
	testWxAppID   = "wx0000000000000001"
	testV3Key     = "0123456789abcdef0123456789ABCDEF"
	testSerial    = "5157F09EFDC096DE15EBE81A47057A7232F1B8E1"
	testPubKeyID  = "PUB_KEY_ID_0000000000000024101100397200000006"
	testNotifyURL = "https://cirrus.example/pay/wechat/notify"
)

var wxNow = time.Date(2026, 10, 6, 4, 5, 6, 0, time.UTC)

// newTestWeChat uses testKeys: the first key is the merchant's API key, the
// second stands in for the WeChat Pay public key.
func newTestWeChat(t *testing.T, gateway string) *WeChat {
	t.Helper()
	merchant, platform := testKeys(t)
	w, err := NewWeChat(WeChatConfig{
		MchID: testMchID, AppID: testWxAppID, APIv3Key: testV3Key, CertSerial: testSerial,
		PrivateKey: pkcs8Base64(merchant), PublicKey: pkixBase64(&platform.PublicKey), PublicKeyID: testPubKeyID,
		Gateway: gateway, NotifyURL: testNotifyURL,
	})
	if err != nil {
		t.Fatal(err)
	}
	w.Now = func() time.Time { return wxNow }
	return w
}

var authRE = regexp.MustCompile(`^WECHATPAY2-SHA256-RSA2048 mchid="([0-9]+)",nonce_str="([0-9A-Z]{32})",signature="([A-Za-z0-9+/=]+)",timestamp="([0-9]+)",serial_no="([0-9A-F]+)"$`)

// checkAuthorization verifies an Authorization header against the
// documented format and the merchant's public key.
func checkAuthorization(t *testing.T, pub *rsa.PublicKey, header, method, uri, body string) {
	t.Helper()
	m := authRE.FindStringSubmatch(header)
	if m == nil {
		t.Fatalf("Authorization = %q", header)
	}
	if m[1] != testMchID || m[4] != strconv.FormatInt(wxNow.Unix(), 10) || m[5] != testSerial {
		t.Fatalf("Authorization fields: %q", m[1:])
	}
	if err := Verify(pub, method+"\n"+uri+"\n"+m[4]+"\n"+m[2]+"\n"+body+"\n", m[3]); err != nil {
		t.Fatalf("Authorization signature: %v", err)
	}
}

// wxSign returns the Wechatpay-* headers for body, signed with key.
func wxSign(t *testing.T, key *rsa.PrivateKey, serial string, at time.Time, body []byte) http.Header {
	t.Helper()
	ts, nonce := strconv.FormatInt(at.Unix(), 10), "593BEC0C930BF1AFEB40B4A08C8FB242"
	sig, err := Sign(key, ts+"\n"+nonce+"\n"+string(body)+"\n")
	if err != nil {
		t.Fatal(err)
	}
	h := http.Header{}
	h.Set("Wechatpay-Timestamp", ts)
	h.Set("Wechatpay-Nonce", nonce)
	h.Set("Wechatpay-Signature", sig)
	h.Set("Wechatpay-Serial", serial)
	h.Set("Wechatpay-Signature-Type", "WECHATPAY2-SHA256-RSA2048")
	return h
}

// wxNotifyBody encrypts tx like WeChat Pay does and wraps it in a
// notification.
func wxNotifyBody(t *testing.T, v3key string, tx any) []byte {
	t.Helper()
	plain, _ := json.Marshal(tx)
	block, _ := aes.NewCipher([]byte(v3key))
	gcm, _ := cipher.NewGCM(block)
	nonce, ad := "fdasflkja484", "transaction"
	ct := gcm.Seal(nil, []byte(nonce), plain, []byte(ad))
	b, _ := json.Marshal(map[string]any{
		"id": "EV-2018022511223320873", "create_time": "2026-10-06T12:05:06+08:00", "resource_type": "encrypt-resource",
		"event_type": "TRANSACTION.SUCCESS", "summary": "支付成功",
		"resource": map[string]string{"original_type": "transaction", "algorithm": "AEAD_AES_256_GCM",
			"ciphertext": base64.StdEncoding.EncodeToString(ct), "associated_data": ad, "nonce": nonce},
	})
	return b
}

func wxTx(no string, cents int64, state string) map[string]any {
	return map[string]any{
		"appid": testWxAppID, "mchid": testMchID, "out_trade_no": no, "transaction_id": "4200000000202610061234567890",
		"trade_type": "NATIVE", "trade_state": state, "trade_state_desc": "支付成功", "bank_type": "OTHERS",
		"success_time": "2026-10-06T12:05:06+08:00", "payer": map[string]string{"openid": "oUpF8uMuAJO_M2pxb1Q9zNjWeS6o"},
		"amount": map[string]any{"total": cents, "payer_total": cents, "currency": "CNY", "payer_currency": "CNY"},
	}
}

func TestWeChatAuthorization(t *testing.T) {
	merchant, _ := testKeys(t)
	w := newTestWeChat(t, "https://api.mch.weixin.qq.com")
	body := `{"appid":"wx0000000000000001"}`
	h1, err := w.Authorization("POST", "/v3/pay/transactions/native", body)
	if err != nil {
		t.Fatal(err)
	}
	checkAuthorization(t, &merchant.PublicKey, h1, "POST", "/v3/pay/transactions/native", body)
	h2, _ := w.Authorization("POST", "/v3/pay/transactions/native", body)
	if h1 == h2 {
		t.Fatal("nonce is not random")
	}
	// Each part is signed: changing the URL breaks the signature.
	m := authRE.FindStringSubmatch(h1)
	if Verify(&merchant.PublicKey, "POST\n/v3/other\n"+m[4]+"\n"+m[2]+"\n"+body+"\n", m[3]) == nil {
		t.Fatal("signature does not cover the URL")
	}
}

// fakeWxGateway answers Native orders like WeChat Pay would. respond returns
// the status, body and response signing key (nil: unsigned) and serial.
func fakeWxGateway(t *testing.T, respond func(req map[string]any) (int, string, *rsa.PrivateKey, string)) *httptest.Server {
	t.Helper()
	merchant, _ := testKeys(t)
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Method != http.MethodPost || r.URL.Path != NativePath {
			t.Errorf("request %s %s", r.Method, r.URL.Path)
		}
		for k, v := range map[string]string{"Accept": "application/json", "Content-Type": "application/json", "Wechatpay-Serial": testPubKeyID} {
			if r.Header.Get(k) != v {
				t.Errorf("header %s = %q", k, r.Header.Get(k))
			}
		}
		if r.Header.Get("User-Agent") == "" {
			t.Error("no User-Agent")
		}
		checkAuthorization(t, &merchant.PublicKey, r.Header.Get("Authorization"), r.Method, r.URL.RequestURI(), string(body))
		var req map[string]any
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("body: %v", err)
		}
		status, resp, key, serial := respond(req)
		if key != nil {
			for k, v := range wxSign(t, key, serial, time.Now(), []byte(resp)) {
				rw.Header()[k] = v
			}
		}
		rw.Header().Set("Content-Type", "application/json")
		rw.WriteHeader(status)
		rw.Write([]byte(resp))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestWeChatCreate(t *testing.T) {
	_, platform := testKeys(t)
	var got map[string]any
	gw := fakeWxGateway(t, func(req map[string]any) (int, string, *rsa.PrivateKey, string) {
		got = req
		return 200, `{"code_url":"weixin://wxpay/bizpayurl?pr=p4lpSuKzz"}`, platform, testPubKeyID
	})
	w := newTestWeChat(t, gw.URL+"/")
	info, err := w.Create(context.Background(), Order{No: "C261006123456", Subject: "卷云 Cirrus Pro - Windows", AmountCents: 19800})
	if err != nil {
		t.Fatal(err)
	}
	if info.Type != TypeQR || info.QRText != "weixin://wxpay/bizpayurl?pr=p4lpSuKzz" {
		t.Fatalf("info = %+v", info)
	}
	want := map[string]any{
		"appid": testWxAppID, "mchid": testMchID, "description": "卷云 Cirrus Pro - Windows", "out_trade_no": "C261006123456",
		"notify_url": testNotifyURL, "time_expire": "2026-10-06T14:05:06+08:00",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %v, want %v", k, got[k], v)
		}
	}
	amt, _ := got["amount"].(map[string]any)
	if amt["total"] != float64(19800) || amt["currency"] != "CNY" {
		t.Errorf("amount = %v", got["amount"])
	}
	if w.Name() != "wechat_native" || w.Method() != "wechat" || w.TTL() != 2*time.Hour || !w.Available() {
		t.Error("provider identity")
	}

	// An unsigned response (no Wechatpay-Signature) is accepted.
	gw2 := fakeWxGateway(t, func(map[string]any) (int, string, *rsa.PrivateKey, string) {
		return 200, `{"code_url":"weixin://wxpay/bizpayurl?pr=x"}`, nil, ""
	})
	if info, err := newTestWeChat(t, gw2.URL).Create(context.Background(), Order{No: "C1", AmountCents: 1}); err != nil || info.QRText == "" {
		t.Fatalf("unsigned response: %+v %v", info, err)
	}
}

func TestWeChatCreateErrors(t *testing.T) {
	merchant, platform := testKeys(t)
	cases := map[string]func(map[string]any) (int, string, *rsa.PrivateKey, string){
		"api error": func(map[string]any) (int, string, *rsa.PrivateKey, string) {
			return 400, `{"code":"PARAM_ERROR","message":"appid和mch_id不匹配"}`, platform, testPubKeyID
		},
		"forged signature": func(map[string]any) (int, string, *rsa.PrivateKey, string) {
			return 200, `{"code_url":"weixin://wxpay/bizpayurl?pr=x"}`, merchant, testPubKeyID
		},
		"wrong serial": func(map[string]any) (int, string, *rsa.PrivateKey, string) {
			return 200, `{"code_url":"weixin://wxpay/bizpayurl?pr=x"}`, platform, "PUB_KEY_ID_OTHER"
		},
		"no code_url": func(map[string]any) (int, string, *rsa.PrivateKey, string) {
			return 200, `{}`, platform, testPubKeyID
		},
	}
	for name, respond := range cases {
		gw := fakeWxGateway(t, respond)
		_, err := newTestWeChat(t, gw.URL).Create(context.Background(), Order{No: "C1", AmountCents: 100})
		if err == nil {
			t.Errorf("%s: no error", name)
		} else if name == "api error" && !strings.Contains(err.Error(), "PARAM_ERROR") {
			t.Errorf("%s: %v", name, err)
		}
	}
	// Unreachable gateway.
	if _, err := newTestWeChat(t, "http://127.0.0.1:1").Create(context.Background(), Order{No: "C1", AmountCents: 1}); err == nil {
		t.Error("unreachable gateway: no error")
	}
}

func TestWeChatVerifyResponse(t *testing.T) {
	merchant, platform := testKeys(t)
	w := newTestWeChat(t, "https://api.mch.weixin.qq.com")
	body := []byte(`{"code_url":"weixin://wxpay/bizpayurl?pr=x"}`)
	if err := w.VerifyResponse(wxSign(t, platform, testPubKeyID, wxNow, body), body); err != nil {
		t.Fatal(err)
	}
	if w.VerifyResponse(wxSign(t, merchant, testPubKeyID, wxNow, body), body) == nil {
		t.Error("wrong key accepted")
	}
	if w.VerifyResponse(wxSign(t, platform, "PUB_KEY_ID_OTHER", wxNow, body), body) == nil {
		t.Error("wrong serial accepted")
	}
	if w.VerifyResponse(wxSign(t, platform, testPubKeyID, wxNow, body), append(body, ' ')) == nil {
		t.Error("changed body accepted")
	}
}

func TestWeChatVerifyNotify(t *testing.T) {
	merchant, platform := testKeys(t)
	w := newTestWeChat(t, "https://api.mch.weixin.qq.com")
	body := wxNotifyBody(t, testV3Key, wxTx("C261006123456", 19800, "SUCCESS"))
	tx, err := w.VerifyNotify(wxSign(t, platform, testPubKeyID, wxNow.Add(-4*time.Minute), body), body)
	if err != nil {
		t.Fatal(err)
	}
	if tx.MchID != testMchID || tx.AppID != testWxAppID || tx.OutTradeNo != "C261006123456" || tx.TradeState != "SUCCESS" ||
		tx.Amount.Total != 19800 || tx.TransactionID != "4200000000202610061234567890" {
		t.Fatalf("tx = %+v", tx)
	}

	bad := map[string]struct {
		h    http.Header
		body []byte
	}{
		"forged":        {wxSign(t, merchant, testPubKeyID, wxNow, body), body},
		"wrong serial":  {wxSign(t, platform, "PUB_KEY_ID_OTHER", wxNow, body), body},
		"stale":         {wxSign(t, platform, testPubKeyID, wxNow.Add(-6*time.Minute), body), body},
		"future":        {wxSign(t, platform, testPubKeyID, wxNow.Add(6*time.Minute), body), body},
		"tampered":      {wxSign(t, platform, testPubKeyID, wxNow, body), append([]byte(" "), body...)},
		"no signature":  {http.Header{"Wechatpay-Serial": {testPubKeyID}}, body},
		"wrong v3 key":  {nil, wxNotifyBody(t, strings.Repeat("x", 32), wxTx("C1", 1, "SUCCESS"))},
		"not encrypted": {nil, []byte(`{"resource":{"algorithm":"NONE","ciphertext":"e30="}}`)},
	}
	for name, c := range bad {
		h := c.h
		if h == nil {
			h = wxSign(t, platform, testPubKeyID, wxNow, c.body)
		}
		if _, err := w.VerifyNotify(h, c.body); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestNewWeChat(t *testing.T) {
	merchant, platform := testKeys(t)
	der, _ := x509.MarshalPKCS8PrivateKey(merchant)
	pemOneLine := strings.ReplaceAll(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "\n", `\n`)
	ok := WeChatConfig{MchID: testMchID, AppID: testWxAppID, APIv3Key: testV3Key, CertSerial: testSerial,
		PrivateKey: pemOneLine, PublicKey: pkixBase64(&platform.PublicKey), PublicKeyID: testPubKeyID}
	if _, err := NewWeChat(ok); err != nil {
		t.Fatalf("PEM with literal \\n: %v", err)
	}
	for name, mod := range map[string]func(*WeChatConfig){
		"short v3 key": func(c *WeChatConfig) { c.APIv3Key = "short" },
		"bad private":  func(c *WeChatConfig) { c.PrivateKey = "not a key" },
		"bad public":   func(c *WeChatConfig) { c.PublicKey = pkcs8Base64(merchant) },
	} {
		c := ok
		mod(&c)
		if _, err := NewWeChat(c); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}
