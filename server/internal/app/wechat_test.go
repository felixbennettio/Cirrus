package app

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"cirrus/server/internal/pay"
)

const (
	wxMchID    = "1900000001"
	wxAppID    = "wx0000000000000001"
	wxV3Key    = "0123456789abcdef0123456789ABCDEF"
	wxPubKeyID = "PUB_KEY_ID_0000000000000024101100397200000006"
)

// newWeChat uses alipayKeys: the app key is the merchant's API key, the
// "Alipay" key stands in for the WeChat Pay public key.
func newWeChat(t *testing.T, gateway string) *pay.WeChat {
	t.Helper()
	merchant, platform := alipayKeys(t)
	der, _ := x509.MarshalPKCS8PrivateKey(merchant)
	pub, _ := x509.MarshalPKIXPublicKey(&platform.PublicKey)
	w, err := pay.NewWeChat(pay.WeChatConfig{
		MchID: wxMchID, AppID: wxAppID, APIv3Key: wxV3Key, CertSerial: "5157F09EFDC096DE15EBE81A47057A7232F1B8E1",
		PrivateKey: base64.StdEncoding.EncodeToString(der), PublicKey: base64.StdEncoding.EncodeToString(pub),
		PublicKeyID: wxPubKeyID, Gateway: gateway, NotifyURL: "https://cirrus.test/pay/wechat/notify",
	})
	if err != nil {
		t.Fatal(err)
	}
	return w
}

// fakeWxGateway answers Native orders like WeChat Pay would, or fails.
func fakeWxGateway(t *testing.T, fail bool) *httptest.Server {
	t.Helper()
	_, platform := alipayKeys(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "WECHATPAY2-SHA256-RSA2048 ") {
			t.Errorf("gateway: Authorization %q", r.Header.Get("Authorization"))
		}
		body, _ := io.ReadAll(r.Body)
		var req struct {
			OutTradeNo string `json:"out_trade_no"`
		}
		json.Unmarshal(body, &req)
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte(`{"code":"SYSTEM_ERROR","message":"系统错误"}`))
			return
		}
		resp := []byte(`{"code_url":"weixin://wxpay/bizpayurl?pr=` + req.OutTradeNo + `"}`)
		for k, v := range wxHeaders(t, platform, wxPubKeyID, time.Now(), resp) {
			w.Header()[k] = v
		}
		w.Write(resp)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func wxHeaders(t *testing.T, key *rsa.PrivateKey, serial string, at time.Time, body []byte) http.Header {
	t.Helper()
	ts, nonce := strconv.FormatInt(at.Unix(), 10), "593BEC0C930BF1AFEB40B4A08C8FB242"
	sig, err := pay.Sign(key, ts+"\n"+nonce+"\n"+string(body)+"\n")
	if err != nil {
		t.Fatal(err)
	}
	return http.Header{"Wechatpay-Timestamp": {ts}, "Wechatpay-Nonce": {nonce}, "Wechatpay-Signature": {sig},
		"Wechatpay-Serial": {serial}, "Content-Type": {"application/json"}}
}

// wxNotice is one notification: the decrypted transaction and how the
// envelope is signed.
type wxNotice struct {
	mchID, appID, state, serial string
	cents                       int64
	key                         *rsa.PrivateKey
	at                          time.Time
}

func (h *harness) wxNotify(no string, n wxNotice) *httptest.ResponseRecorder {
	h.t.Helper()
	tx, _ := json.Marshal(map[string]any{
		"appid": n.appID, "mchid": n.mchID, "out_trade_no": no, "transaction_id": "42000000002026100600" + no[len(no)-6:],
		"trade_type": "NATIVE", "trade_state": n.state, "success_time": "2026-10-06T18:05:00+08:00",
		"amount": map[string]any{"total": n.cents, "payer_total": n.cents, "currency": "CNY"},
	})
	nonceS := "fdasflkja484"
	block, _ := aes.NewCipher([]byte(wxV3Key))
	gcm, _ := cipher.NewGCM(block)
	ct := gcm.Seal(nil, []byte(nonceS), tx, []byte("transaction"))
	body, _ := json.Marshal(map[string]any{
		"id": "EV-" + no, "create_time": "2026-10-06T18:05:00+08:00", "resource_type": "encrypt-resource",
		"event_type": "TRANSACTION.SUCCESS", "summary": "支付成功",
		"resource": map[string]string{"original_type": "transaction", "algorithm": "AEAD_AES_256_GCM",
			"ciphertext": base64.StdEncoding.EncodeToString(ct), "associated_data": "transaction", "nonce": nonceS},
	})
	hdr := map[string]string{}
	for k, v := range wxHeaders(h.t, n.key, n.serial, n.at, body) {
		hdr[k] = v[0]
	}
	return h.do(http.MethodPost, "/pay/wechat/notify", string(body), hdr)
}

func TestWeChatNativeOrderAndNotify(t *testing.T) {
	gw := fakeWxGateway(t, false)
	h := newHarness(t, harnessOpt{wechat: newWeChat(t, gw.URL), noQR: []string{"wechat"}})
	merchant, platform := alipayKeys(t)

	// The buy page offers WeChat although there is no static QR image.
	if body := h.get("/buy").Body.String(); !strings.Contains(body, `value="wechat" required`) {
		t.Fatal("WeChat should be available with the API configured")
	}
	if body := h.admin(http.MethodGet, "/admin", nil).Body.String(); !strings.Contains(body, "微信：微信支付 API（Native），自动确认；无备用静态收款码") ||
		!strings.Contains(body, "支付宝：静态收款码，人工确认") {
		t.Fatal("admin page should show the payment modes")
	}

	m := h.createOrder("cirrus-linux", "wx@example.com", "wechat", nil)
	no, tok := m["order_no"].(string), m["token"].(string)
	p := m["pay"].(map[string]any)
	if p["type"] != "qr" || p["qr_text"] != "weixin://wxpay/bizpayurl?pr="+no || p["amount"] != "198.00" ||
		p["qr_image"] != "/api/v1/orders/"+no+"/qr.png?token="+tok {
		t.Fatalf("pay = %v", p)
	}
	exp, _ := time.Parse(time.RFC3339, m["expires_at"].(string))
	if !exp.Equal(h.clock().Add(2 * time.Hour)) {
		t.Fatalf("WeChat orders expire after 2 h, got %v", exp)
	}
	if png := h.get(p["qr_image"].(string)); png.Code != 200 || !strings.HasPrefix(png.Body.String(), "\x89PNG") {
		t.Fatalf("qr.png: %d", png.Code)
	}
	if stored, _ := h.st.Order(context.Background(), no); stored.Provider != "wechat_native" {
		t.Fatalf("provider = %q", stored.Provider)
	}

	now := h.clock()
	good := wxNotice{mchID: wxMchID, appID: wxAppID, state: "SUCCESS", serial: wxPubKeyID, cents: 19800, key: platform, at: now}
	with := func(f func(*wxNotice)) wxNotice { n := good; f(&n); return n }
	forger, _ := rsa.GenerateKey(rand.Reader, 2048)
	bad := map[string]wxNotice{
		"bad signature":   with(func(n *wxNotice) { n.key = forger }),
		"merchant key":    with(func(n *wxNotice) { n.key = merchant }),
		"wrong serial":    with(func(n *wxNotice) { n.serial = "PUB_KEY_ID_0000000000000000000000000000000001" }),
		"stale timestamp": with(func(n *wxNotice) { n.at = now.Add(-6 * time.Minute) }),
		"wrong mchid":     with(func(n *wxNotice) { n.mchID = "1900000002" }),
		"wrong appid":     with(func(n *wxNotice) { n.appID = "wx0000000000000002" }),
		"wrong amount":    with(func(n *wxNotice) { n.cents = 1 }),
		"not paid":        with(func(n *wxNotice) { n.state = "NOTPAY" }),
	}
	for name, n := range bad {
		rec := h.wxNotify(no, n)
		var r map[string]string
		json.Unmarshal(rec.Body.Bytes(), &r)
		if rec.Code != http.StatusBadRequest || r["code"] != "FAIL" || r["message"] == "" {
			t.Fatalf("%s: %d %s", name, rec.Code, rec.Body.String())
		}
	}
	if rec := h.wxNotify("C261006999999", good); rec.Code != http.StatusBadRequest {
		t.Fatalf("unknown order: %d", rec.Code)
	}
	if s := h.order(no, tok)["status"]; s != "pending" {
		t.Fatalf("order should still be pending, is %v", s)
	}

	// Paid, with a timestamp 4 minutes old.
	rec := h.wxNotify(no, with(func(n *wxNotice) { n.at = now.Add(-4 * time.Minute) }))
	if rec.Code != http.StatusOK || rec.Body.Len() != 0 {
		t.Fatalf("notify: %d %q", rec.Code, rec.Body.String())
	}
	o := h.order(no, tok)
	key, _ := o["license_key"].(string)
	if o["status"] != "paid" || key == "" {
		t.Fatalf("order after notify: %v", o)
	}
	// A duplicate notification is acknowledged and changes nothing.
	if rec := h.wxNotify(no, good); rec.Code != http.StatusOK {
		t.Fatalf("duplicate: %d %s", rec.Code, rec.Body.String())
	}
	if o := h.order(no, tok); o["license_key"] != key {
		t.Fatal("duplicate notify changed the licence")
	}
	lics, _ := h.st.LicensesByEmail(context.Background(), "wx@example.com")
	if len(lics) != 1 || lics[0].Key != key || lics[0].OrderNo != no {
		t.Fatalf("licences = %+v", lics)
	}
	if stored, _ := h.st.Order(context.Background(), no); stored.PayRef != "42000000002026100600"+no[len(no)-6:] {
		t.Fatalf("pay_ref = %q", stored.PayRef)
	}
	h.app.Wait()
	if mails := h.mail.all(); len(mails) != 1 || !strings.Contains(mails[0].Body, key) {
		t.Fatalf("mails = %+v", mails)
	}
	expect(t, h.post("/api/v1/activate", activateBody(key, dev(1), "linux")), 200, "")
}

func TestWeChatFallbackToStatic(t *testing.T) {
	gw := fakeWxGateway(t, true)
	h := newHarness(t, harnessOpt{wechat: newWeChat(t, gw.URL)})
	m := h.createOrder("cirrus-linux", "a@example.com", "wechat", nil)
	if p := m["pay"].(map[string]any); p["type"] != "static_qr" || p["qr_image"] != "/static/pay/wechat.png" {
		t.Fatalf("pay = %v", p)
	}
	if !strings.Contains(h.admin(http.MethodGet, "/admin", nil).Body.String(), "接口失败时退回静态收款码") {
		t.Fatal("admin page should mention the fallback")
	}
	h2 := newHarness(t, harnessOpt{wechat: newWeChat(t, gw.URL), noQR: []string{"wechat"}})
	expect(t, h2.post("/api/v1/orders", map[string]string{"product": "cirrus-linux", "email": "a@example.com", "method": "wechat"}), 502, "payment_error")
}

func TestWeChatDisabled(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	if rec := h.do(http.MethodPost, "/pay/wechat/notify", "{}", nil); rec.Code != 404 {
		t.Fatalf("notify without WeChat configured: %d", rec.Code)
	}
	// Static QR as before.
	if p := h.createOrder("cirrus-linux", "a@example.com", "wechat", nil)["pay"].(map[string]any); p["type"] != "static_qr" {
		t.Fatalf("pay = %v", p)
	}
	// PAY_METHODS still decides: the API does not bring WeChat back.
	gw := fakeWxGateway(t, false)
	h2 := newHarness(t, harnessOpt{wechat: newWeChat(t, gw.URL), env: map[string]string{"PAY_METHODS": "alipay"}})
	expect(t, h2.post("/api/v1/orders", map[string]string{"product": "cirrus-linux", "email": "a@example.com", "method": "wechat"}), 503, "method_unavailable")
	if !strings.Contains(h2.admin(http.MethodGet, "/admin", nil).Body.String(), "微信：未启用（PAY_METHODS）") {
		t.Fatal("admin page should say WeChat is off")
	}
}
