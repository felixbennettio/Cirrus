package app

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"html/template"
	"io/fs"
	"net/http"
	"os"
	"strings"
	"time"

	"cirrus/server/internal/money"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

var pageNames = []string{
	"index", "buy", "license", "privacy", "terms", "support", "notfound", "oauth",
	"admin_orders", "admin_licenses", "admin_license",
}

type site struct {
	Name        string
	Operator    string
	Contact     string
	ICP         string
	PolicyDate  string
	DownloadURL string
	AppStoreURL string
	PublicURL   string
	Year        int
	SMTP        bool
}

type productView struct {
	ID         string
	Platform   string
	NameZH     string
	NameEN     string
	MaxDevices int
	Price      string // "198"
	PriceUSD   string
}

type methodView struct {
	ID        string
	NameZH    string
	NameEN    string
	Available bool
}

// page is the data every template gets.
type page struct {
	EN       bool
	Path     string
	LangURL  string
	Site     site
	Products []productView
	Methods  []methodView
	CSRF     string
	Flash    string
	Data     any
	I18N     map[string]string
}

// T picks the Chinese or English text.
func (p *page) T(zh, en string) string {
	if p.EN {
		return en
	}
	return zh
}

// Admin reports whether this is an admin page.
func (p *page) Admin() bool { return strings.HasPrefix(p.Path, "/admin") }

// Active returns "active" for the nav link of the current page.
func (p *page) Active(path string) string {
	if p.Path == path || (path != "/" && path != "/admin" && strings.HasPrefix(p.Path, path)) {
		return "active"
	}
	return ""
}

func (a *App) loadTemplates() error {
	h := sha256.New()
	fs.WalkDir(staticFS, "static", func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			b, _ := staticFS.ReadFile(path)
			h.Write([]byte(path))
			h.Write(b)
		}
		return nil
	})
	a.assetVer = hex.EncodeToString(h.Sum(nil))[:10]

	funcs := template.FuncMap{
		"asset": a.asset,
		"money": money.Format,
		"time": func(t time.Time) string {
			if t.IsZero() {
				return "—"
			}
			return t.In(cst).Format("2006-01-02 15:04")
		},
		"platform": platformName,
		"product": func(id string) string {
			if p, ok := a.cfg.Product(id); ok {
				return p.NameZH
			}
			return id
		},
		"short": func(s string, n int) string {
			if len(s) <= n {
				return s
			}
			return s[:n] + "…"
		},
	}
	a.pages = make(map[string]*template.Template, len(pageNames))
	for _, name := range pageNames {
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(templateFS, "templates/layout.html", "templates/"+name+".html")
		if err != nil {
			return err
		}
		a.pages[name] = t
	}
	return nil
}

// asset is the versioned URL of an embedded static file.
func (a *App) asset(name string) string { return "/static/" + name + "?v=" + a.assetVer }

func (a *App) staticHandler() http.Handler {
	sub, _ := fs.Sub(staticFS, "static")
	files := http.StripPrefix("/static/", http.FileServer(http.FS(sub)))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/") {
			a.notFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "public, max-age=604800")
		files.ServeHTTP(w, r)
	})
}

// payImage serves the operator's collection QR codes from DATA_DIR/pay.
func (a *App) payImage(w http.ResponseWriter, r *http.Request) {
	method, ok := strings.CutSuffix(r.PathValue("file"), ".png")
	s := a.static[method]
	if !ok || s == nil {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(s.File())
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeContent(w, r, "", st.ModTime(), f)
}

// isEN picks the language: ?lang= (remembered in a cookie), then the
// cookie, else Simplified Chinese.
func isEN(w http.ResponseWriter, r *http.Request) bool {
	if q := r.URL.Query().Get("lang"); q == "en" || q == "zh" {
		http.SetCookie(w, &http.Cookie{Name: "lang", Value: q, Path: "/", MaxAge: 365 * 24 * 3600, SameSite: http.SameSiteLaxMode})
		return q == "en"
	}
	c, err := r.Cookie("lang")
	return err == nil && c.Value == "en"
}

func (a *App) newPage(w http.ResponseWriter, r *http.Request) *page {
	p := &page{EN: isEN(w, r), Path: r.URL.Path}
	q := r.URL.Query()
	q.Set("lang", p.T("en", "zh"))
	p.LangURL = r.URL.Path + "?" + q.Encode()
	c := a.cfg
	p.Site = site{
		Name: c.SiteName, Operator: c.OperatorName, Contact: c.ContactEmail, ICP: c.ICPNumber,
		PolicyDate: c.PolicyDate, DownloadURL: c.DownloadURL, AppStoreURL: c.AppStoreURL, PublicURL: c.PublicURL,
		Year: a.now().In(cst).Year(), SMTP: a.mail != nil,
	}
	for _, pr := range c.Products {
		p.Products = append(p.Products, productView{
			ID: pr.ID, Platform: pr.Platform, NameZH: pr.NameZH, NameEN: pr.NameEN, MaxDevices: pr.MaxDevices,
			Price: money.Short(pr.PriceCents), PriceUSD: pr.PriceUSD,
		})
	}
	for _, m := range c.PayMethods {
		mv := methodView{ID: m, NameZH: "支付宝", NameEN: "Alipay", Available: a.provider(m) != nil}
		if m == "wechat" {
			mv.NameZH, mv.NameEN = "微信支付", "WeChat Pay"
		}
		p.Methods = append(p.Methods, mv)
	}
	return p
}

func (a *App) render(w http.ResponseWriter, name string, status int, p *page) {
	var buf bytes.Buffer
	if err := a.pages[name].ExecuteTemplate(&buf, "layout", p); err != nil {
		a.log.Error("render", "page", name, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if w.Header().Get("Cache-Control") == "" {
		w.Header().Set("Cache-Control", "no-cache")
	}
	w.Header().Set("Vary", "Cookie")
	w.WriteHeader(status)
	w.Write(buf.Bytes())
}

func (a *App) pageHandler(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p := a.newPage(w, r)
		if name == "license" {
			p.I18N = licenseI18N(p.EN)
		}
		a.render(w, name, http.StatusOK, p)
	}
}

// oauthCallback is the redirect URL the iOS, Android and macOS apps register
// with Cloudflare, which only accepts http(s) redirects. oauth.js hands the
// authorization response (code and state, or an error) to the app through
// io.felixbennett.cirrus:/oauth/callback. The code is useless without the
// app's PKCE verifier; the page keeps nothing and is never cached.
func (a *App) oauthCallback(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Robots-Tag", "noindex")
	p := a.newPage(w, r)
	// Never echo the code into the page; oauth.js carries it over on a
	// language switch.
	p.LangURL = r.URL.Path + "?lang=" + p.T("en", "zh")
	a.render(w, "oauth", http.StatusOK, p)
}

func (a *App) notFound(w http.ResponseWriter, r *http.Request) {
	a.render(w, "notfound", http.StatusNotFound, a.newPage(w, r))
}

type buyData struct {
	Selected    string
	ReturnOrder string
}

func (a *App) buyPage(w http.ResponseWriter, r *http.Request) {
	p := a.newPage(w, r)
	sel := r.URL.Query().Get("product")
	if _, ok := a.cfg.Product(sel); !ok {
		sel = a.cfg.Products[0].ID
	}
	// ?order= is where Alipay's cashier sends the buyer back. It only tells
	// the page to resume polling; the status always comes from the API.
	ret := r.URL.Query().Get("order")
	if len(ret) > 32 {
		ret = ""
	}
	p.Data = buyData{Selected: sel, ReturnOrder: ret}
	p.I18N = buyI18N(p.EN)
	a.render(w, "buy", http.StatusOK, p)
}

func pick(en bool, zh, enm map[string]string) map[string]string {
	if en {
		return enm
	}
	return zh
}

// Strings for buy.js. Chinese error texts come from the API's "message";
// the English page maps error codes ("err_<code>").
func buyI18N(en bool) map[string]string {
	return pick(en, map[string]string{
		"alipay":       "支付宝",
		"wechat":       "微信",
		"creating":     "正在创建订单…",
		"err_generic":  "出错了，请稍后再试",
		"err_network":  "网络错误，请检查网络后重试",
		"waiting":      "等待付款… 付款后本页面会自动更新",
		"waiting_man":  "等待确认收款… 我们会尽快人工确认，确认后本页面会自动显示许可证",
		"copy":         "复制",
		"copied":       "已复制",
		"redirecting":  "正在跳转到支付宝收银台…",
		"no_order":     "未在本浏览器找到该订单。如果已经付款，许可证会发送到你的邮箱，也可以在“许可证”页面用订单号和查询凭证查询。",
		"step_scan":    "打开{m}，扫描上方收款码",
		"step_amount":  "输入金额 ¥{a}（请勿多付或少付）",
		"step_note":    "在付款备注（添加备注 / 转账说明）中填写订单号 {o}",
		"step_wait":    "付款后请保持本页面打开；收款确认后这里会显示许可证",
		"save_hint":    "长按或右键保存收款码图片，再在{m}中“扫一扫 → 从相册选取”。",
		"scan_dynamic": "请使用支付宝扫码付款",
		"open_app":     "在手机上打开支付宝付款",
	}, map[string]string{
		"alipay":                 "Alipay",
		"wechat":                 "WeChat",
		"creating":               "Creating your order…",
		"err_generic":            "Something went wrong. Please try again.",
		"err_network":            "Network error. Please check your connection and retry.",
		"err_invalid_email":      "Please enter a valid email address.",
		"err_invalid_product":    "Unknown product.",
		"err_invalid_method":     "Unsupported payment method.",
		"err_method_unavailable": "This payment method is not available right now. Please choose another.",
		"err_payment_error":      "Could not start the payment. Please try again or use another method.",
		"err_rate_limited":       "Too many requests. Please wait a moment.",
		"waiting":                "Waiting for payment… this page updates by itself.",
		"waiting_man":            "Waiting for the payment to be confirmed. We confirm payments by hand as soon as possible; your key will appear here.",
		"copy":                   "Copy",
		"copied":                 "Copied",
		"redirecting":            "Taking you to the Alipay checkout…",
		"no_order":               "This order was not found in this browser. If you have paid, the key is emailed to you, and you can look the order up on the Licence page with its number and token.",
		"step_scan":              "Open {m} and scan the QR code above",
		"step_amount":            "Enter the amount ¥{a} exactly",
		"step_note":              "Write the order number {o} in the payment note",
		"step_wait":              "Keep this page open; your licence key appears here once the payment is confirmed",
		"save_hint":              "On a phone, save the QR image and choose it from your photos in {m}'s scanner.",
		"scan_dynamic":           "Scan with Alipay to pay",
		"open_app":               "Open Alipay on this phone",
	})
}

func licenseI18N(en bool) map[string]string {
	return pick(en, map[string]string{
		"reset_ok":    "已释放全部设备，现在可以在新设备上激活了。",
		"resend_ok":   "如果该邮箱购买过许可证，邮件将在几分钟内送达。请同时检查垃圾邮件文件夹。",
		"pending":     "订单待付款",
		"paid":        "已付款",
		"expired":     "订单已过期。如果你已经付款，请联系客服并提供订单号。",
		"err_generic": "出错了，请稍后再试",
		"err_network": "网络错误，请检查网络后重试",
		"copy":        "复制",
		"copied":      "已复制",
	}, map[string]string{
		"reset_ok":            "All devices have been released. You can activate on your new device now.",
		"resend_ok":           "If this address has bought a licence, an email is on its way. Please check your spam folder too.",
		"pending":             "Waiting for payment",
		"paid":                "Paid",
		"expired":             "This order has expired. If you have paid, please contact support with the order number.",
		"err_generic":         "Something went wrong. Please try again.",
		"err_network":         "Network error. Please check your connection and retry.",
		"err_invalid_key":     "This licence key is not valid. Please check it.",
		"err_email_mismatch":  "The email does not match the one used to buy this licence.",
		"err_too_soon":        "Devices can be reset once every 30 days. Please try again in {n} day(s) or contact support.",
		"err_revoked":         "This licence has been revoked.",
		"err_order_not_found": "Order not found, or the token is wrong.",
		"err_rate_limited":    "Too many requests. Please wait a moment.",
		"err_invalid_email":   "Please enter a valid email address.",
		"err_not_available":   "Email delivery is not available. Please contact support.",
		"copy":                "Copy",
		"copied":              "Copied",
	})
}
