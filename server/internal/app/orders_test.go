package app

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"cirrus/server/internal/pay"
)

func (h *harness) createOrder(product, email, method string, hdr map[string]string) map[string]any {
	h.t.Helper()
	rec := h.do(http.MethodPost, "/api/v1/orders", map[string]string{"product": product, "email": email, "method": method}, hdr)
	return expect(h.t, rec, http.StatusCreated, "")
}

func (h *harness) order(no, token string) map[string]any {
	h.t.Helper()
	return expect(h.t, h.get("/api/v1/orders/"+no+"?token="+url.QueryEscape(token)), 200, "")
}

func TestManualOrderFlow(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	m := h.createOrder("cirrus-windows", " Buyer@Example.com ", "alipay", nil)
	no, tok := m["order_no"].(string), m["token"].(string)
	if !strings.HasPrefix(no, "C261006") || len(no) != 13 || len(tok) != 32 {
		t.Fatalf("order_no %q token %q", no, tok)
	}
	if m["amount"] != "198.00" || m["currency"] != "CNY" || m["status"] != "pending" {
		t.Fatalf("order = %v", m)
	}
	p := m["pay"].(map[string]any)
	if p["type"] != "static_qr" || p["qr_image"] != "/static/pay/alipay.png" || p["amount"] != "198.00" || p["note"] != no {
		t.Fatalf("pay = %v", p)
	}
	if rec := h.get("/static/pay/alipay.png"); rec.Code != 200 || rec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("static QR image: %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}

	// Poll: pending, no key; the token is required.
	o := h.order(no, tok)
	if o["status"] != "pending" || o["license_key"] != nil || o["pay"] == nil {
		t.Fatalf("pending order = %v", o)
	}
	expect(t, h.get("/api/v1/orders/"+no), 404, "order_not_found")
	expect(t, h.get("/api/v1/orders/"+no+"?token=wrong"), 404, "order_not_found")
	expect(t, h.get("/api/v1/orders/C000000000000?token="+tok), 404, "order_not_found")

	// The operator confirms the payment.
	rec := h.admin(http.MethodPost, "/admin/orders/"+no+"/confirm", url.Values{"pay_ref": {"支付宝 备注 " + no}})
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(rec.Header().Get("Location"), "/admin/licenses/lic_") {
		t.Fatalf("confirm: %d %s", rec.Code, rec.Header().Get("Location"))
	}
	// Confirming twice does not issue a second licence.
	rec2 := h.admin(http.MethodPost, "/admin/orders/"+no+"/confirm", url.Values{})
	if rec2.Header().Get("Location") != rec.Header().Get("Location") {
		t.Fatal("second confirm issued another licence")
	}

	o = h.order(no, tok)
	key, _ := o["license_key"].(string)
	if o["status"] != "paid" || !strings.HasPrefix(key, "CIRRUS-") || o["pay"] != nil {
		t.Fatalf("paid order = %v", o)
	}
	expect(t, h.post("/api/v1/activate", activateBody(key, dev(1), "windows")), 200, "")

	h.app.Wait()
	mails := h.mail.all()
	if len(mails) != 1 || mails[0].To != "buyer@example.com" || !strings.Contains(mails[0].Body, key) || !strings.Contains(mails[0].Body, no) {
		t.Fatalf("mails = %+v", mails)
	}
}

func TestOrderExpiry(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	m := h.createOrder("cirrus-linux", "x@example.com", "wechat", nil)
	no, tok := m["order_no"].(string), m["token"].(string)
	if m["pay"].(map[string]any)["qr_image"] != "/static/pay/wechat.png" {
		t.Fatalf("pay = %v", m["pay"])
	}
	exp, _ := time.Parse(time.RFC3339, m["expires_at"].(string))
	if !exp.Equal(h.clock().Add(24 * time.Hour)) {
		t.Fatalf("manual orders expire after 24 h, got %v", exp)
	}
	h.advance(24*time.Hour - time.Second)
	if s := h.order(no, tok)["status"]; s != "pending" {
		t.Fatalf("status before expiry: %v", s)
	}
	h.advance(time.Second)
	if s := h.order(no, tok)["status"]; s != "expired" {
		t.Fatalf("status after expiry: %v", s)
	}
	h.app.housekeeping(context.Background())
	got, _ := h.st.Order(context.Background(), no)
	if got.Status != "expired" {
		t.Fatalf("housekeeping did not expire the order: %s", got.Status)
	}
	// A late payment can still be confirmed.
	h.admin(http.MethodPost, "/admin/orders/"+no+"/confirm", url.Values{})
	if o := h.order(no, tok); o["status"] != "paid" || o["license_key"] == nil {
		t.Fatalf("late confirm: %v", o)
	}

	// A cancelled order reads as expired.
	m = h.createOrder("cirrus-linux", "x@example.com", "wechat", nil)
	rec := h.admin(http.MethodPost, "/admin/orders/"+m["order_no"].(string)+"/cancel", url.Values{})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("cancel: %d", rec.Code)
	}
	if s := h.order(m["order_no"].(string), m["token"].(string))["status"]; s != "expired" {
		t.Fatalf("cancelled order status: %v", s)
	}

	// Unpaid orders are purged 90 days later.
	h.advance(91 * 24 * time.Hour)
	h.app.housekeeping(context.Background())
	expect(t, h.get("/api/v1/orders/"+m["order_no"].(string)+"?token="+m["token"].(string)), 404, "order_not_found")
	if o := h.order(no, tok); o["status"] != "paid" {
		t.Fatal("paid order was purged")
	}
}

func TestOrderValidation(t *testing.T) {
	h := newHarness(t, harnessOpt{env: map[string]string{"PAY_METHODS": "alipay,wechat"}, noQR: []string{"wechat"}})
	cases := []struct {
		body   map[string]string
		status int
		code   string
	}{
		{map[string]string{"product": "cirrus-ios", "email": "a@example.com", "method": "alipay"}, 400, "invalid_product"},
		{map[string]string{"product": "cirrus-linux", "email": "not-an-email", "method": "alipay"}, 400, "invalid_email"},
		{map[string]string{"product": "cirrus-linux", "email": "A <a@example.com>", "method": "alipay"}, 400, "invalid_email"},
		{map[string]string{"product": "cirrus-linux", "email": "a@example.com", "method": "paypal"}, 400, "invalid_method"},
		{map[string]string{"product": "cirrus-linux", "email": "a@example.com", "method": "wechat"}, 503, "method_unavailable"},
	}
	for _, c := range cases {
		expect(t, h.post("/api/v1/orders", c.body), c.status, c.code)
	}

	h2 := newHarness(t, harnessOpt{env: map[string]string{"PAY_METHODS": "wechat", "PRICE_CNY_ANDROID": "68"}})
	expect(t, h2.post("/api/v1/orders", map[string]string{"product": "cirrus-linux", "email": "a@example.com", "method": "alipay"}), 503, "method_unavailable")
	m := h2.createOrder("cirrus-android", "a@example.com", "wechat", nil)
	if m["amount"] != "68.00" {
		t.Fatalf("per-product price: %v", m["amount"])
	}
}

func TestAlipayPrecreateAndNotify(t *testing.T) {
	gw := fakeGateway(t, false)
	h := newHarness(t, harnessOpt{alipay: newAlipay(t, gw.URL, pay.ModePrecreate)})
	_, ali := alipayKeys(t)

	m := h.createOrder("cirrus-windows", "f2f@example.com", "alipay", nil)
	no, tok := m["order_no"].(string), m["token"].(string)
	p := m["pay"].(map[string]any)
	if p["type"] != "qr" || p["qr_text"] != "https://qr.alipay.com/bax"+no || !strings.HasPrefix(p["qr_image"].(string), "/api/v1/orders/"+no+"/qr.png?token=") {
		t.Fatalf("pay = %v", p)
	}
	exp, _ := time.Parse(time.RFC3339, m["expires_at"].(string))
	if !exp.Equal(h.clock().Add(2 * time.Hour)) {
		t.Fatalf("Alipay orders expire after 2 h, got %v", exp)
	}
	png := h.get(p["qr_image"].(string))
	if png.Code != 200 || png.Header().Get("Content-Type") != "image/png" || !strings.HasPrefix(png.Body.String(), "\x89PNG") {
		t.Fatalf("qr.png: %d %s", png.Code, png.Header().Get("Content-Type"))
	}
	if h.get("/api/v1/orders/"+no+"/qr.png?token=wrong").Code != 404 {
		t.Fatal("qr.png without the token")
	}

	pending := func() {
		t.Helper()
		if s := h.order(no, tok)["status"]; s != "pending" {
			t.Fatalf("order should still be pending, is %v", s)
		}
	}
	rejected := func(rec *httptest.ResponseRecorder, what string) {
		t.Helper()
		if rec.Body.String() == "success" || rec.Code == 200 {
			t.Fatalf("%s: notification accepted (%d %s)", what, rec.Code, rec.Body.String())
		}
	}

	// Bad signature: signed by someone else.
	forger, _ := rsa.GenerateKey(rand.Reader, 2048)
	rejected(h.notify(forger, notifyForm(no, "198.00", "TRADE_SUCCESS")), "bad signature")
	// Tampered after signing.
	f := notifyForm(no, "198.00", "TRADE_SUCCESS")
	f.Set("sign_type", "RSA2")
	sig, _ := pay.Sign(ali, pay.Content(f, "sign", "sign_type"))
	f.Set("sign", sig)
	f.Set("trade_status", "TRADE_SUCCESS ")
	rejected(h.do(http.MethodPost, "/pay/alipay/notify", f.Encode(), map[string]string{"Content-Type": "application/x-www-form-urlencoded"}), "tampered")
	// Wrong app_id, correctly signed.
	f = notifyForm(no, "198.00", "TRADE_SUCCESS")
	f.Set("app_id", "2021000000009999")
	rejected(h.notify(ali, f), "wrong app_id")
	// Wrong amount.
	rejected(h.notify(ali, notifyForm(no, "1.98", "TRADE_SUCCESS")), "wrong amount")
	// Unknown order.
	rejected(h.notify(ali, notifyForm("C261006999999", "198.00", "TRADE_SUCCESS")), "unknown order")
	pending()

	// Not paid yet: acknowledged, nothing happens.
	if rec := h.notify(ali, notifyForm(no, "198.00", "WAIT_BUYER_PAY")); rec.Body.String() != "success" {
		t.Fatalf("WAIT_BUYER_PAY: %s", rec.Body.String())
	}
	pending()

	// Paid.
	rec := h.notify(ali, notifyForm(no, "198", "TRADE_SUCCESS"))
	if rec.Code != 200 || rec.Body.String() != "success" {
		t.Fatalf("TRADE_SUCCESS: %d %s", rec.Code, rec.Body.String())
	}
	o := h.order(no, tok)
	key, _ := o["license_key"].(string)
	if o["status"] != "paid" || key == "" {
		t.Fatalf("order after notify: %v", o)
	}
	// Repeated notifications are idempotent.
	for _, st := range []string{"TRADE_SUCCESS", "TRADE_FINISHED"} {
		if rec := h.notify(ali, notifyForm(no, "198.00", st)); rec.Body.String() != "success" {
			t.Fatalf("repeat %s: %s", st, rec.Body.String())
		}
	}
	if o := h.order(no, tok); o["license_key"] != key {
		t.Fatal("repeated notify changed the licence")
	}
	lics, _ := h.st.LicensesByEmail(context.Background(), "f2f@example.com")
	if len(lics) != 1 || lics[0].Key != key || lics[0].OrderNo != no {
		t.Fatalf("licences = %+v", lics)
	}
	stored, _ := h.st.Order(context.Background(), no)
	if stored.PayRef != notifyForm(no, "", "").Get("trade_no") {
		t.Fatalf("pay_ref = %q", stored.PayRef)
	}
	h.app.Wait()
	if mails := h.mail.all(); len(mails) != 1 || !strings.Contains(mails[0].Body, key) {
		t.Fatalf("mails = %+v", mails)
	}
	expect(t, h.post("/api/v1/activate", activateBody(key, dev(1), "windows")), 200, "")
}

func TestAlipayNotifyDisabled(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	if rec := h.do(http.MethodPost, "/pay/alipay/notify", "a=b", map[string]string{"Content-Type": "application/x-www-form-urlencoded"}); rec.Code != 404 {
		t.Fatalf("notify without Alipay configured: %d", rec.Code)
	}
}

func TestAlipayFallbackToStatic(t *testing.T) {
	gw := fakeGateway(t, true)
	h := newHarness(t, harnessOpt{alipay: newAlipay(t, gw.URL, pay.ModePrecreate)})
	m := h.createOrder("cirrus-linux", "a@example.com", "alipay", nil)
	if p := m["pay"].(map[string]any); p["type"] != "static_qr" {
		t.Fatalf("pay = %v", p)
	}
	h2 := newHarness(t, harnessOpt{alipay: newAlipay(t, gw.URL, pay.ModePrecreate), noQR: []string{"alipay"}})
	expect(t, h2.post("/api/v1/orders", map[string]string{"product": "cirrus-linux", "email": "a@example.com", "method": "alipay"}), 502, "payment_error")
}

func TestAlipayPageMode(t *testing.T) {
	const gateway = "https://openapi-sandbox.dl.alipaydev.com/gateway.do"
	h := newHarness(t, harnessOpt{alipay: newAlipay(t, gateway, pay.ModePage)})
	app, ali := alipayKeys(t)

	check := func(payObj map[string]any, no, wantMethod, wantProduct string) {
		t.Helper()
		if payObj["type"] != "redirect" {
			t.Fatalf("pay = %v", payObj)
		}
		raw := payObj["url"].(string)
		if !strings.HasPrefix(raw, gateway+"?") {
			t.Fatalf("url = %s", raw)
		}
		u, _ := url.Parse(raw)
		q := u.Query()
		if err := pay.Verify(&app.PublicKey, pay.Content(q, "sign"), q.Get("sign")); err != nil {
			t.Fatalf("signature: %v", err)
		}
		var biz map[string]string
		json.Unmarshal([]byte(q.Get("biz_content")), &biz)
		if q.Get("method") != wantMethod || biz["product_code"] != wantProduct || biz["out_trade_no"] != no ||
			biz["total_amount"] != "198.00" || q.Get("notify_url") != "https://cirrus.test/pay/alipay/notify" ||
			q.Get("return_url") != "https://cirrus.test/buy?order="+no {
			t.Fatalf("params %v biz %v", q, biz)
		}
	}

	desktop := map[string]string{"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130"}
	m := h.createOrder("cirrus-windows", "page@example.com", "alipay", desktop)
	no, tok := m["order_no"].(string), m["token"].(string)
	check(m["pay"].(map[string]any), no, "alipay.trade.page.pay", "FAST_INSTANT_TRADE_PAY")

	// Polling returns a freshly signed URL.
	h.advance(time.Minute)
	o := expect(t, h.do("GET", "/api/v1/orders/"+no+"?token="+tok, nil, desktop), 200, "")
	check(o["pay"].(map[string]any), no, "alipay.trade.page.pay", "FAST_INSTANT_TRADE_PAY")
	if o["pay"].(map[string]any)["url"] == m["pay"].(map[string]any)["url"] {
		t.Fatal("URL not regenerated")
	}

	phone := map[string]string{"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148"}
	m2 := h.createOrder("cirrus-windows", "page@example.com", "alipay", phone)
	check(m2["pay"].(map[string]any), m2["order_no"].(string), "alipay.trade.wap.pay", "QUICK_WAP_WAY")

	// The same notification handler confirms page payments.
	if rec := h.notify(ali, notifyForm(no, "198.00", "TRADE_SUCCESS")); rec.Body.String() != "success" {
		t.Fatalf("notify: %s", rec.Body.String())
	}
	if o := h.order(no, tok); o["status"] != "paid" || o["license_key"] == nil {
		t.Fatalf("order = %v", o)
	}
	// Returning to /buy?order= only shows the page; it never changes state.
	if rec := h.get("/buy?order=" + m2["order_no"].(string) + "&trade_status=TRADE_SUCCESS"); rec.Code != 200 {
		t.Fatalf("return page: %d", rec.Code)
	}
	if o := h.order(m2["order_no"].(string), m2["token"].(string)); o["status"] != "pending" {
		t.Fatal("return_url changed the order status")
	}
}

func TestResend(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	l1 := h.issue("cirrus-linux", "keys@example.com")
	l2 := h.issue("cirrus-android", "keys@example.com")
	expect(t, h.post("/api/v1/resend", map[string]string{"email": "Keys@Example.com"}), 200, "")
	expect(t, h.post("/api/v1/resend", map[string]string{"email": "keys@example.com"}), 200, "") // per-email cooldown
	expect(t, h.post("/api/v1/resend", map[string]string{"email": "nobody@example.com"}), 200, "")
	// Three per IP: the fourth request is limited.
	expect(t, h.post("/api/v1/resend", map[string]string{"email": "other@example.com"}), 429, "rate_limited")
	other := map[string]string{"RemoteAddr": "198.51.100.20:4000"}
	expect(t, h.do("POST", "/api/v1/resend", map[string]string{"email": "bad"}, other), 400, "invalid_email")
	h.app.Wait()
	mails := h.mail.all()
	if len(mails) != 1 || mails[0].To != "keys@example.com" || !strings.Contains(mails[0].Body, l1.Key) || !strings.Contains(mails[0].Body, l2.Key) {
		t.Fatalf("mails = %+v", mails)
	}

	h2 := newHarness(t, harnessOpt{noMail: true})
	expect(t, h2.post("/api/v1/resend", map[string]string{"email": "keys@example.com"}), 404, "not_available")
}
