package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"cirrus/server/internal/i18n"
	"cirrus/server/internal/money"
	"cirrus/server/internal/pay"
	"cirrus/server/internal/store"
)

var cst = time.FixedZone("CST", 8*3600)

func tokenHash(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

func (a *App) productInfo(id string) (string, int, bool) {
	p, ok := a.cfg.Product(id)
	return p.Platform, p.MaxDevices, ok
}

// provider picks how a payment method is collected: the Alipay or WeChat
// Pay API when configured, otherwise the static collection QR code if its
// image exists. nil means the method is unavailable.
func (a *App) provider(method string) pay.Provider {
	if !a.cfg.MethodEnabled(method) {
		return nil
	}
	if method == "alipay" && a.alipay != nil {
		return a.alipay
	}
	if method == "wechat" && a.wechat != nil {
		return a.wechat
	}
	if s := a.static[method]; s != nil && s.Available() {
		return s
	}
	return nil
}

func (a *App) newOrderNo() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		panic(err)
	}
	return fmt.Sprintf("C%s%06d", a.now().In(cst).Format("060102"), n.Int64())
}

func (a *App) apiCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Product string `json:"product"`
		Email   string `json:"email"`
		Method  string `json:"method"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	p, ok := a.onSale(strings.TrimSpace(req.Product))
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_product", tr(r, "api.invalid_product"), nil)
		return
	}
	email := store.NormEmail(req.Email)
	if !validEmail(email) {
		writeError(w, http.StatusBadRequest, "invalid_email", tr(r, "api.invalid_email"), nil)
		return
	}
	method := strings.ToLower(strings.TrimSpace(req.Method))
	if method != "alipay" && method != "wechat" {
		writeError(w, http.StatusBadRequest, "invalid_method", tr(r, "api.invalid_method"), nil)
		return
	}
	prov := a.provider(method)
	if prov == nil {
		writeError(w, http.StatusServiceUnavailable, "method_unavailable", tr(r, "api.method_unavailable"), nil)
		return
	}

	now := a.now()
	token := randHex(16)
	var o store.Order
	for attempt := 0; ; attempt++ {
		no := a.newOrderNo()
		info, err := prov.Create(r.Context(), a.payOrderFor(r, no, p.ID))
		if err != nil && prov != a.static[method] && a.static[method].Available() {
			// The payment API is down: fall back to the static collection code.
			a.log.Error("payment provider failed, using static QR", "provider", prov.Name(), "err", err)
			prov = a.static[method]
			info, err = prov.Create(r.Context(), pay.Order{No: no})
		}
		if err != nil {
			a.log.Error("payment provider failed", "provider", prov.Name(), "err", err)
			writeError(w, http.StatusBadGateway, "payment_error", tr(r, "api.payment_error"), nil)
			return
		}
		o = store.Order{
			No: no, TokenHash: tokenHash(token), Product: p.ID, Email: email, Method: method, Provider: prov.Name(),
			AmountCents: p.PriceCents, Currency: "CNY", Status: store.StatusPending, PayData: info.QRText,
			CreatedAt: now, ExpiresAt: now.Add(prov.TTL()), Lang: apiLang(r),
		}
		err = a.st.InsertOrder(r.Context(), o)
		if errors.Is(err, store.ErrConflict) && attempt < 5 {
			continue
		}
		if err != nil {
			a.internalError(w, r, err)
			return
		}
		break
	}
	a.event(r.Context(), "order_created", "", o.No, ipFrom(r), fmt.Sprintf("%s %s %s", o.Product, o.Method, o.Provider))
	writeJSON(w, http.StatusCreated, map[string]any{
		"order_no":   o.No,
		"token":      token,
		"amount":     money.Format(o.AmountCents),
		"currency":   o.Currency,
		"status":     store.StatusPending,
		"product":    o.Product,
		"method":     o.Method,
		"expires_at": rfc3339(o.ExpiresAt),
		"pay":        a.payJSON(r, o, token),
	})
}

// payOrderFor describes an order to a payment provider.
func (a *App) payOrderFor(r *http.Request, no, productID string) pay.Order {
	p, _ := a.product(productID)
	return pay.Order{
		No:          no,
		Subject:     strings.NewReplacer("&", " ", "=", " ", "/", " ").Replace(a.cfg.SiteName + " Pro - " + p.NameEN),
		AmountCents: p.PriceCents,
		// Only brings the buyer back to the page; the payment status always
		// comes from the server, never from return_url parameters.
		ReturnURL: a.cfg.PublicURL + "/buy?order=" + url.QueryEscape(no),
		Mobile:    isMobile(r.UserAgent()),
	}
}

func isMobile(ua string) bool {
	return strings.Contains(ua, "Mobi") || strings.Contains(ua, "Android") || strings.Contains(ua, "iPhone")
}

// payJSON is the "pay" object: how to pay a pending order.
func (a *App) payJSON(r *http.Request, o store.Order, token string) map[string]any {
	amount := money.Format(o.AmountCents)
	switch o.Provider {
	case "alipay_f2f", "wechat_native":
		return map[string]any{
			"type":     pay.TypeQR,
			"qr_text":  o.PayData,
			"qr_image": "/api/v1/orders/" + url.PathEscape(o.No) + "/qr.png?token=" + url.QueryEscape(token),
			"amount":   amount,
		}
	case "alipay_page":
		// The signed URL carries a timestamp, so build a fresh one each time.
		pj := map[string]any{"type": pay.TypeRedirect, "amount": amount}
		if a.alipay != nil {
			po := a.payOrderFor(r, o.No, o.Product)
			po.AmountCents = o.AmountCents
			if u, err := a.alipay.PageURL(po); err == nil {
				pj["url"] = u
			} else {
				a.log.Error("alipay page url", "order", o.No, "err", err)
			}
		}
		return pj
	}
	return map[string]any{
		"type":     pay.TypeStaticQR,
		"qr_image": "/static/pay/" + o.Method + ".png",
		"amount":   amount,
		"note":     o.No,
	}
}

// orderWithToken loads the order when the token matches.
func (a *App) orderWithToken(r *http.Request) (store.Order, string, bool) {
	no := r.PathValue("order_no")
	tok := r.URL.Query().Get("token")
	o, err := a.st.Order(r.Context(), no)
	if err != nil || tok == "" || subtle.ConstantTimeCompare([]byte(tokenHash(tok)), []byte(o.TokenHash)) != 1 {
		return o, tok, false
	}
	return o, tok, true
}

// apiStatus maps internal statuses onto the contract's pending, paid and
// expired; an order cancelled by the operator reads as expired.
func apiStatus(o store.Order, now time.Time) string {
	switch s := o.EffectiveStatus(now); s {
	case store.StatusCancelled:
		return store.StatusExpired
	default:
		return s
	}
}

func (a *App) apiGetOrder(w http.ResponseWriter, r *http.Request) {
	o, tok, ok := a.orderWithToken(r)
	if !ok {
		writeError(w, http.StatusNotFound, "order_not_found", tr(r, "api.order_not_found"), nil)
		return
	}
	status := apiStatus(o, a.now())
	resp := map[string]any{
		"order_no":   o.No,
		"status":     status,
		"product":    o.Product,
		"method":     o.Method,
		"amount":     money.Format(o.AmountCents),
		"currency":   o.Currency,
		"created_at": rfc3339(o.CreatedAt),
		"expires_at": rfc3339(o.ExpiresAt),
	}
	switch status {
	case store.StatusPending:
		resp["pay"] = a.payJSON(r, o, tok)
	case store.StatusPaid:
		resp["license_key"] = o.LicenseKey
		resp["paid_at"] = rfc3339(o.PaidAt)
	}
	writeJSON(w, http.StatusOK, resp)
}

func (a *App) apiOrderQR(w http.ResponseWriter, r *http.Request) {
	o, _, ok := a.orderWithToken(r)
	if !ok || (o.Provider != "alipay_f2f" && o.Provider != "wechat_native") || o.PayData == "" || o.EffectiveStatus(a.now()) != store.StatusPending {
		http.NotFound(w, r)
		return
	}
	png, err := qrcode.Encode(o.PayData, qrcode.Medium, 320)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "private, no-store")
	w.Write(png)
}

// alipayNotify handles Alipay's asynchronous payment notification.
func (a *App) alipayNotify(w http.ResponseWriter, r *http.Request) {
	if a.alipay == nil {
		http.NotFound(w, r)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "failure", http.StatusBadRequest)
		return
	}
	f := r.PostForm
	no := f.Get("out_trade_no")
	ip := ipFrom(r)
	fail := func(reason string) {
		a.log.Warn("alipay notify rejected", "reason", reason, "out_trade_no", no, "ip", ip)
		a.event(r.Context(), "notify_rejected", "", no, ip, reason)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("failure"))
	}
	if err := a.alipay.VerifyNotify(f); err != nil {
		fail("signature: " + err.Error())
		return
	}
	if f.Get("app_id") != a.alipay.AppID {
		fail("app_id " + f.Get("app_id"))
		return
	}
	o, err := a.st.Order(r.Context(), no)
	if err != nil {
		fail("unknown order")
		return
	}
	cents, err := money.Parse(f.Get("total_amount"))
	if err != nil || cents != o.AmountCents {
		fail("total_amount " + f.Get("total_amount"))
		return
	}
	switch f.Get("trade_status") {
	case "TRADE_SUCCESS", "TRADE_FINISHED":
		if _, _, _, err := a.payOrder(r.Context(), no, f.Get("trade_no"), ip, "alipay"); err != nil {
			a.log.Error("alipay notify: pay order", "out_trade_no", no, "err", err)
			http.Error(w, "failure", http.StatusInternalServerError) // Alipay retries
			return
		}
	default:
		// WAIT_BUYER_PAY, TRADE_CLOSED: nothing to do.
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("success"))
}

// wechatNotify handles WeChat Pay's payment notification (APIv3, JSON).
// WeChat Pay retries until it gets a 2xx.
func (a *App) wechatNotify(w http.ResponseWriter, r *http.Request) {
	if a.wechat == nil {
		http.NotFound(w, r)
		return
	}
	ip := ipFrom(r)
	no := ""
	reply := func(status int, msg string) {
		writeJSON(w, status, map[string]string{"code": "FAIL", "message": msg})
	}
	fail := func(reason string) {
		a.log.Warn("wechat notify rejected", "reason", reason, "out_trade_no", no, "ip", ip)
		a.event(r.Context(), "notify_rejected", "", no, ip, "wechat: "+reason)
		reply(http.StatusBadRequest, reason)
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		fail("cannot read body")
		return
	}
	tx, err := a.wechat.VerifyNotify(r.Header, body)
	if err != nil {
		fail("signature: " + err.Error())
		return
	}
	no = tx.OutTradeNo
	if tx.MchID != a.wechat.MchID {
		fail("mchid " + tx.MchID)
		return
	}
	if tx.AppID != a.wechat.AppID {
		fail("appid " + tx.AppID)
		return
	}
	if tx.TradeState != "SUCCESS" {
		fail("trade_state " + tx.TradeState)
		return
	}
	o, err := a.st.Order(r.Context(), no)
	if err != nil {
		fail("unknown order")
		return
	}
	if tx.Amount.Total != o.AmountCents {
		fail(fmt.Sprintf("amount %d", tx.Amount.Total))
		return
	}
	if _, _, _, err := a.payOrder(r.Context(), no, tx.TransactionID, ip, "wechat"); err != nil {
		a.log.Error("wechat notify: pay order", "out_trade_no", no, "err", err)
		reply(http.StatusInternalServerError, "internal error") // WeChat Pay retries
		return
	}
	w.WriteHeader(http.StatusOK)
}

// payOrder marks the order paid, issues the licence and emails it. It is
// idempotent: an order that is already paid keeps its licence.
func (a *App) payOrder(ctx context.Context, no, payRef, ip, via string) (store.Order, store.License, bool, error) {
	o, l, issued, err := a.st.PayOrder(ctx, no, payRef, a.now(), a.productInfo)
	if err != nil {
		return o, l, false, err
	}
	if issued {
		a.log.Info("order paid", "order", no, "license", l.ID, "via", via)
		a.event(ctx, "order_paid", l.ID, no, ip, strings.TrimSpace(via+" "+payRef))
		if a.mail != nil {
			lic := l
			a.background(func(ctx context.Context) { a.sendMail(ctx, o.Email, o.No, o.Lang, []store.License{lic}) })
		}
	}
	return o, l, issued, nil
}

type contextFunc = func(ctx context.Context)

// background runs fn after the response, with its own timeout.
func (a *App) background(fn contextFunc) {
	a.bg.Add(1)
	go func() {
		defer a.bg.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		fn(ctx)
	}()
}

// sendMail emails licence keys to their owner, in the language the buyer
// used on the website. Other languages get the English text below theirs;
// without a known language (licences issued in /admin) the email is in
// Simplified Chinese and English, as before.
func (a *App) sendMail(ctx context.Context, to, orderNo, lang string, lics []store.License) {
	if a.mail == nil || len(lics) == 0 {
		return
	}
	if _, ok := i18n.Get(lang); !ok {
		lang = i18n.ZhHans
	}
	subject := i18n.T(lang, "mail.subject", "site", a.cfg.SiteName)
	body := a.mailBody(lang, orderNo, lics)
	if lang != i18n.EN {
		subject += " / " + i18n.T(i18n.EN, "mail.subject", "site", a.cfg.SiteName)
		body += "\n--\n\n" + a.mailBody(i18n.EN, orderNo, lics)
	}
	if err := a.mail.Send(ctx, to, subject, body); err != nil {
		a.log.Error("send licence email", "order", orderNo, "err", err)
		a.event(ctx, "mail_failed", lics[0].ID, orderNo, "", err.Error())
		return
	}
	a.event(ctx, "mail_sent", lics[0].ID, orderNo, "", "")
}

// mailBody is the licence email in one language: the keys, each with the
// download link of its platform, then how to activate and move devices.
func (a *App) mailBody(lang, orderNo string, lics []store.License) string {
	var b strings.Builder
	b.WriteString(i18n.T(lang, "mail.greeting") + "\n\n")
	b.WriteString(i18n.N(lang, "mail.intro", len(lics), "site", a.cfg.SiteName) + "\n\n")
	for _, l := range lics {
		name := i18n.T(lang, "product.name", "platform", platformName(l.Platform))
		line := i18n.T(lang, "mail.product", "product", name, "devices", i18n.N(lang, "devices", l.MaxDevices))
		if l.Revoked {
			line += " " + i18n.T(lang, "mail.revoked")
		}
		b.WriteString("  " + line + "\n  " + l.Key + "\n")
		if dl := a.downloadLink(l.Platform); dl != "" {
			b.WriteString("  " + i18n.T(lang, "mail.download", "url", dl) + "\n")
		}
		b.WriteString("\n")
	}
	if orderNo != "" {
		b.WriteString(i18n.T(lang, "mail.order", "order", orderNo) + "\n\n")
	}
	contact := a.cfg.ContactEmail
	if contact == "" {
		contact = a.cfg.PublicURL + "/support"
	}
	b.WriteString(i18n.T(lang, "mail.activate") + "\n")
	b.WriteString(i18n.T(lang, "mail.move", "url", a.cfg.PublicURL+"/license?lang="+lang) + "\n")
	b.WriteString(i18n.T(lang, "mail.keep", "contact", contact) + "\n")
	return b.String()
}
