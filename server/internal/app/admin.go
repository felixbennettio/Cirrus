package app

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"net/http"
	"net/url"
	"strings"

	"cirrus/server/internal/pay"
	"cirrus/server/internal/store"
)

const csrfCookie = "cirrus_csrf"

func ctEqual(x, y string) bool {
	hx, hy := sha256.Sum256([]byte(x)), sha256.Sum256([]byte(y))
	return subtle.ConstantTimeCompare(hx[:], hy[:]) == 1
}

// admin wraps an admin handler: HTTP Basic auth (user "admin",
// ADMIN_PASSWORD), a limit on failed logins per IP, and CSRF checks on POST.
// Without ADMIN_PASSWORD the admin pages do not exist.
func (a *App) admin(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if a.cfg.AdminPassword == "" {
			a.notFound(w, r)
			return
		}
		ip := ipFrom(r)
		if a.authLimit.Blocked(ip) {
			http.Error(w, "too many failed logins, try again later", http.StatusTooManyRequests)
			return
		}
		user, pass, ok := r.BasicAuth()
		if !ok || !(ctEqual(user, "admin") && ctEqual(pass, a.cfg.AdminPassword)) {
			if ok {
				a.authLimit.Allow(ip)
				a.log.Warn("admin login failed", "ip", ip)
			}
			w.Header().Set("WWW-Authenticate", `Basic realm="Cirrus admin", charset="UTF-8"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		if r.Method == http.MethodPost {
			r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
			if !a.checkCSRF(r) {
				http.Error(w, "CSRF check failed: reload the page and try again", http.StatusForbidden)
				return
			}
		}
		h(w, r)
	}
}

func (a *App) isHTTPS(r *http.Request) bool {
	return r.TLS != nil || (a.cfg.TrustProxy && r.Header.Get("X-Forwarded-Proto") == "https")
}

// csrfToken returns the per-browser token, setting the cookie on first use.
func (a *App) csrfToken(w http.ResponseWriter, r *http.Request) string {
	if c, err := r.Cookie(csrfCookie); err == nil && len(c.Value) == 32 {
		return c.Value
	}
	tok := randHex(16)
	http.SetCookie(w, &http.Cookie{
		Name: csrfCookie, Value: tok, Path: "/admin", HttpOnly: true,
		Secure: a.isHTTPS(r), SameSite: http.SameSiteStrictMode,
	})
	return tok
}

// checkCSRF requires a same-origin Origin (or Referer) header and the form
// token to match the cookie.
func (a *App) checkCSRF(r *http.Request) bool {
	src := r.Header.Get("Origin")
	if src == "" {
		src = r.Header.Get("Referer")
	}
	u, err := url.Parse(src)
	if src == "" || err != nil || u.Host == "" || (u.Host != r.Host && u.Host != a.cfg.PublicHost()) {
		return false
	}
	c, err := r.Cookie(csrfCookie)
	if err != nil || len(c.Value) != 32 {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(c.Value), []byte(r.PostFormValue("csrf"))) == 1
}

var flashes = map[string]string{
	"confirmed": "已确认收款并签发许可证",
	"cancelled": "订单已取消",
	"revoked":   "许可证已吊销",
	"unrevoked": "许可证已恢复",
	"reset":     "已释放全部设备",
	"removed":   "设备已移除",
	"issued":    "许可证已签发",
	"noted":     "备注已保存",
	"mailed":    "邮件已在后台发送，结果见下方事件记录",
	"nomail":    "未配置 SMTP，无法发送邮件",
	"paid":      "该订单已付款，不能取消",
	"bad_email": "邮箱地址无效",
	"bad_input": "输入无效",
}

func (a *App) adminPage(w http.ResponseWriter, r *http.Request, name string, data any) {
	p := a.newPage(w, r)
	p.EN = false // the admin pages are Chinese only
	p.CSRF = a.csrfToken(w, r)
	p.Flash = flashes[r.URL.Query().Get("msg")]
	p.Data = data
	a.render(w, name, http.StatusOK, p)
}

func seeOther(w http.ResponseWriter, r *http.Request, path, msg string) {
	if msg != "" {
		path += "?msg=" + url.QueryEscape(msg)
	}
	http.Redirect(w, r, path, http.StatusSeeOther)
}

type orderRow struct {
	store.Order
	Effective string
}

func (a *App) adminOrders(w http.ResponseWriter, r *http.Request) {
	status := r.URL.Query().Get("status")
	switch status {
	case "", store.StatusPending, store.StatusPaid, store.StatusExpired, store.StatusCancelled:
	default:
		status = ""
	}
	orders, err := a.st.ListOrders(r.Context(), status, 200)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	stats, err := a.st.Stats(r.Context())
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	now := a.now()
	rows := make([]orderRow, 0, len(orders))
	for _, o := range orders {
		rows = append(rows, orderRow{Order: o, Effective: o.EffectiveStatus(now)})
	}
	a.adminPage(w, r, "admin_orders", map[string]any{"Orders": rows, "Stats": stats, "Status": status, "PayModes": a.payModes()})
}

type payMode struct{ Name, Mode string }

// payModes says how each payment method is collected right now.
func (a *App) payModes() []payMode {
	var out []payMode
	for _, m := range []string{"alipay", "wechat"} {
		pm := payMode{Name: "支付宝"}
		if m == "wechat" {
			pm.Name = "微信"
		}
		static := a.static[m].Available()
		switch {
		case !a.cfg.MethodEnabled(m):
			pm.Mode = "未启用（PAY_METHODS）"
		case m == "alipay" && a.alipay != nil && a.alipay.Mode == pay.ModePage:
			pm.Mode = "支付宝 API（电脑网站支付），自动确认"
		case m == "alipay" && a.alipay != nil:
			pm.Mode = "支付宝 API（当面付），自动确认"
		case m == "wechat" && a.wechat != nil:
			pm.Mode = "微信支付 API（Native），自动确认"
		case static:
			pm.Mode = "静态收款码，人工确认"
		default:
			pm.Mode = "不可用（缺少 data/pay/" + m + ".png）"
		}
		if (m == "alipay" && a.alipay != nil || m == "wechat" && a.wechat != nil) && a.cfg.MethodEnabled(m) {
			if static {
				pm.Mode += "；接口失败时退回静态收款码"
			} else {
				pm.Mode += "；无备用静态收款码"
			}
		}
		out = append(out, pm)
	}
	return out
}

func (a *App) adminLicenses(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	lics, err := a.st.SearchLicenses(r.Context(), q, 100)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	a.adminPage(w, r, "admin_licenses", map[string]any{"Q": q, "Licenses": lics})
}

func (a *App) adminLicense(w http.ResponseWriter, r *http.Request) {
	l, err := a.st.LicenseByID(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		a.notFound(w, r)
		return
	} else if err != nil {
		a.internalError(w, r, err)
		return
	}
	devs, err := a.st.Activations(r.Context(), l.ID)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	evs, err := a.st.Events(r.Context(), l.ID, l.OrderNo, 100)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	data := map[string]any{"L": l, "Devices": devs, "Events": evs}
	if l.OrderNo != "" {
		if o, err := a.st.Order(r.Context(), l.OrderNo); err == nil {
			data["Order"] = o
		}
	}
	a.adminPage(w, r, "admin_license", data)
}

func (a *App) adminConfirm(w http.ResponseWriter, r *http.Request) {
	no := r.PathValue("no")
	ref := clean(r.PostFormValue("pay_ref"), 100)
	_, l, _, err := a.payOrder(r.Context(), no, ref, ipFrom(r), "admin")
	if errors.Is(err, store.ErrNotFound) {
		a.notFound(w, r)
		return
	} else if err != nil {
		a.internalError(w, r, err)
		return
	}
	seeOther(w, r, "/admin/licenses/"+l.ID, "confirmed")
}

func (a *App) adminCancel(w http.ResponseWriter, r *http.Request) {
	no := r.PathValue("no")
	switch err := a.st.CancelOrder(r.Context(), no); {
	case errors.Is(err, store.ErrNotFound):
		a.notFound(w, r)
	case errors.Is(err, store.ErrNotPending):
		seeOther(w, r, "/admin", "paid")
	case err != nil:
		a.internalError(w, r, err)
	default:
		a.event(r.Context(), "order_cancelled", "", no, ipFrom(r), "admin")
		seeOther(w, r, "/admin", "cancelled")
	}
}

func (a *App) adminLicenseAction(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	l, err := a.st.LicenseByID(ctx, r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		a.notFound(w, r)
		return
	} else if err != nil {
		a.internalError(w, r, err)
		return
	}
	back := "/admin/licenses/" + l.ID
	action := r.PathValue("action")
	var msg string
	switch action {
	case "revoke", "unrevoke":
		err = a.st.SetRevoked(ctx, l.ID, action == "revoke", a.now())
		msg = action + "d"
	case "reset":
		var n int
		n, err = a.st.AdminReset(ctx, l.ID)
		a.event(ctx, "admin_reset", l.ID, "", ipFrom(r), itoa(n)+" devices")
		msg = "reset"
	case "note":
		err = a.st.UpdateNote(ctx, l.ID, clean(r.PostFormValue("note"), 500))
		msg = "noted"
	case "resend":
		if a.mail == nil || l.Email == "" {
			seeOther(w, r, back, "nomail")
			return
		}
		a.background(func(ctx context.Context) { a.sendMail(ctx, l.Email, l.OrderNo, []store.License{l}) })
		msg = "mailed"
	default:
		a.notFound(w, r)
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	if action == "revoke" || action == "unrevoke" {
		a.event(ctx, action, l.ID, "", ipFrom(r), "admin")
	}
	seeOther(w, r, back, msg)
}

func (a *App) adminRemoveDevice(w http.ResponseWriter, r *http.Request) {
	id, dev := r.PathValue("id"), r.PathValue("device")
	switch err := a.st.RemoveDevice(r.Context(), id, dev); {
	case errors.Is(err, store.ErrNotFound):
		a.notFound(w, r)
	case err != nil:
		a.internalError(w, r, err)
	default:
		a.event(r.Context(), "admin_remove_device", id, "", ipFrom(r), dev[:min(len(dev), 12)])
		seeOther(w, r, "/admin/licenses/"+id, "removed")
	}
}

func (a *App) adminIssue(w http.ResponseWriter, r *http.Request) {
	p, ok := a.cfg.Product(r.PostFormValue("product"))
	if !ok {
		seeOther(w, r, "/admin/licenses", "bad_input")
		return
	}
	email := store.NormEmail(r.PostFormValue("email"))
	if email != "" && !validEmail(email) {
		seeOther(w, r, "/admin/licenses", "bad_email")
		return
	}
	l, err := a.st.CreateLicense(r.Context(), store.NewLicense{
		Product: p.ID, Platform: p.Platform, MaxDevices: p.MaxDevices, Email: email,
		Note: clean(r.PostFormValue("note"), 500),
	}, a.now())
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	a.event(r.Context(), "issued", l.ID, "", ipFrom(r), "admin")
	if email != "" && a.mail != nil && r.PostFormValue("send") == "1" {
		a.background(func(ctx context.Context) { a.sendMail(ctx, email, "", []store.License{l}) })
	}
	seeOther(w, r, "/admin/licenses/"+l.ID, "issued")
}
