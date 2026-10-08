package app

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
	"html"
	"html/template"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"cirrus/server/internal/i18n"
	"cirrus/server/internal/money"
)

//go:embed templates/*.html templates/legal/*.html
var templateFS embed.FS

//go:embed static
var staticFS embed.FS

var pageNames = []string{
	"index", "buy", "license", "privacy", "terms", "support", "download", "notfound", "oauth",
	"admin_orders", "admin_licenses", "admin_license", "admin_prices",
}

// legalPages have one document per language in templates/legal/<page>.<lang>.html.
var legalPages = map[string]bool{"privacy": true, "terms": true}

// jsPages get the strings of the website's scripts (i18n "js." ids).
var jsPages = map[string]bool{"buy": true, "license": true, "admin_license": true}

const langCookie = "lang"

type site struct {
	Name        string
	Operator    string
	Contact     string
	ICP         string
	PolicyDate  string
	DownloadURL string // general download link (DOWNLOAD_URL)
	AppStoreURL string
	PublicURL   string
	Year        int
	SMTP        bool
}

type productView struct {
	ID         string
	Platform   string
	Name       string // localized, e.g. "macOS 版"
	NameZH     string // for the admin pages
	MaxDevices int
	Devices    string // localized, e.g. "3 devices"
	Price      string // localized CNY price, e.g. "CN¥198"
	PriceUSD   string // localized reference price, e.g. "≈ US$39.99"
}

type methodView struct {
	ID        string
	Name      string
	Available bool
}

// langLink is an entry of the language menu and of the hreflang links.
type langLink struct {
	Code    string
	Name    string
	URL     string // this page in that language
	AltURL  string // absolute, for <link rel="alternate">
	Current bool
}

// page is the data every template gets.
type page struct {
	Lang      string
	Langs     []langLink
	Path      string
	NoIndex   bool // no hreflang alternates (error, OAuth and admin pages)
	Site      site
	Products  []productView
	Methods   []methodView
	Downloads []dlPlatform
	Gallery   []shotGroupView // home page only
	Hero      *heroShots      // home page only
	CSRF      string
	Flash     string
	Data      any
	I18N      map[string]string
}

// T returns the message in the page's language; args are name/value pairs
// for its {placeholders}.
func (p *page) T(key string, args ...any) string { return i18n.T(p.Lang, key, args...) }

// H returns the message as HTML, with template.HTML arguments (links)
// inserted as they are.
func (p *page) H(key string, args ...any) template.HTML { return i18n.HTML(p.Lang, key, args...) }

// N returns the plural form of the message for n.
func (p *page) N(key string, n int, args ...any) string { return i18n.N(p.Lang, key, n, args...) }

// Admin reports whether this is an admin page.
func (p *page) Admin() bool { return strings.HasPrefix(p.Path, "/admin") }

// Active returns "active" for the nav link of the current page.
func (p *page) Active(path string) string {
	if p.Path == path || (path != "/" && path != "/admin" && strings.HasPrefix(p.Path, path)) {
		return "active"
	}
	return ""
}

// HasDownloads reports whether the downloads page has anything to offer.
func (p *page) HasDownloads() bool {
	return len(p.Downloads) > 0 || p.Site.DownloadURL != "" || p.Site.AppStoreURL != ""
}

// HasChecksums reports whether any download has a SHA-256 checksum.
func (p *page) HasChecksums() bool {
	for _, d := range p.Downloads {
		for _, f := range d.Files {
			if f.SHA256 != "" {
				return true
			}
		}
	}
	return false
}

// CurrentLang is the language menu entry of the page's language.
func (p *page) CurrentLang() langLink {
	for _, l := range p.Langs {
		if l.Current {
			return l
		}
	}
	return langLink{Code: p.Lang}
}

// PlatformName is the display name of a platform.
func (p *page) PlatformName(platform string) string { return platformName(platform) }

// Size formats a file size.
func (p *page) Size(n int64) string {
	if n < 1_000_000 {
		return p.T("download.size_kb", "size", (n+999)/1000)
	}
	return p.T("download.size_mb", "size", i18n.Number(p.Lang, fmt.Sprintf("%.1f", float64(n)/1e6)))
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
		// HTML pieces for .H messages.
		"link": func(href, text string) template.HTML {
			return template.HTML(`<a href="` + html.EscapeString(href) + `">` + html.EscapeString(text) + `</a>`)
		},
		"mailto": func(addr string) template.HTML {
			e := html.EscapeString(addr)
			return template.HTML(`<a href="mailto:` + e + `">` + e + `</a>`)
		},
		"code": func(s string) template.HTML { return template.HTML(`<code>` + html.EscapeString(s) + `</code>`) },
		"strong": func(s string) template.HTML {
			return template.HTML(`<strong>` + html.EscapeString(s) + `</strong>`)
		},
		// An empty element that scripts fill in, e.g. (el "span" "p-amount").
		"el": func(tag, id string) template.HTML {
			if tag != "span" && tag != "code" {
				tag = "span"
			}
			return template.HTML(`<` + tag + ` id="` + html.EscapeString(id) + `"></` + tag + `>`)
		},
	}
	a.pages = make(map[string]*template.Template)
	parse := func(key string, files ...string) error {
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(templateFS, append([]string{"templates/layout.html"}, files...)...)
		if err != nil {
			return err
		}
		a.pages[key] = t
		return nil
	}
	for _, name := range pageNames {
		if !legalPages[name] {
			if err := parse(name, "templates/"+name+".html"); err != nil {
				return err
			}
			continue
		}
		for _, l := range i18n.Languages {
			if err := parse(name+"/"+l.Code, "templates/"+name+".html", "templates/legal/"+name+"."+l.Code+".html"); err != nil {
				return err
			}
		}
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

// pageLang picks the website language: ?lang= (remembered in a cookie),
// then the cookie, then the browser's Accept-Language, else English. The
// old values "zh" and "en" keep working.
func (a *App) pageLang(w http.ResponseWriter, r *http.Request) string {
	if q := r.URL.Query().Get("lang"); q != "" {
		if l, ok := i18n.Parse(q); ok {
			http.SetCookie(w, &http.Cookie{Name: langCookie, Value: l, Path: "/", MaxAge: 365 * 24 * 3600,
				Secure: a.isHTTPS(r), SameSite: http.SameSiteLaxMode})
			return l
		}
	}
	if c, err := r.Cookie(langCookie); err == nil {
		if l, ok := i18n.Parse(c.Value); ok {
			return l
		}
	}
	if l, ok := i18n.Negotiate(r.Header.Get("Accept-Language")); ok {
		return l
	}
	return i18n.EN
}

// apiLang is the language of API error messages: Accept-Language (the
// website's scripts send the page language), then the lang cookie, else
// Simplified Chinese as documented in docs/licensing.md.
func apiLang(r *http.Request) string {
	if l, ok := i18n.Negotiate(r.Header.Get("Accept-Language")); ok {
		return l
	}
	if c, err := r.Cookie(langCookie); err == nil {
		if l, ok := i18n.Parse(c.Value); ok {
			return l
		}
	}
	return i18n.ZhHans
}

// tr is an API message in the request's language.
func tr(r *http.Request, key string, args ...any) string { return i18n.T(apiLang(r), key, args...) }

// trN is a plural API message in the request's language.
func trN(r *http.Request, key string, n int, args ...any) string {
	return i18n.N(apiLang(r), key, n, args...)
}

// productViews localizes the products on sale.
func (a *App) productViews(lang string) []productView {
	var out []productView
	for _, pr := range a.products() {
		out = append(out, productView{
			ID: pr.ID, Platform: pr.Platform, NameZH: pr.NameZH, MaxDevices: pr.MaxDevices,
			Name:     i18n.T(lang, "product.name", "platform", platformName(pr.Platform)),
			Devices:  i18n.N(lang, "devices", pr.MaxDevices),
			Price:    i18n.T(lang, "price.cny", "amount", i18n.Number(lang, money.Short(pr.PriceCents))),
			PriceUSD: i18n.T(lang, "price.usd", "amount", i18n.Number(lang, pr.PriceUSD)),
		})
	}
	return out
}

func (a *App) newPage(w http.ResponseWriter, r *http.Request) *page {
	lang := a.pageLang(w, r)
	c := a.cfg
	p := &page{
		Lang: lang, Path: r.URL.Path,
		Site: site{
			Name: c.SiteName, Operator: c.OperatorName, Contact: c.ContactEmail, ICP: c.ICPNumber,
			PolicyDate: c.PolicyDate, DownloadURL: c.DownloadURL, AppStoreURL: c.AppStoreURL, PublicURL: c.PublicURL,
			Year: a.now().In(cst).Year(), SMTP: a.mail != nil,
		},
		Products:  a.productViews(lang),
		Downloads: a.downloads(),
	}
	q := r.URL.Query()
	for _, l := range i18n.Languages {
		q.Set("lang", l.Code)
		p.Langs = append(p.Langs, langLink{
			Code: l.Code, Name: l.Name, Current: l.Code == lang,
			URL:    r.URL.Path + "?" + q.Encode(),
			AltURL: c.PublicURL + r.URL.Path + "?lang=" + url.QueryEscape(l.Code),
		})
	}
	for _, m := range c.PayMethods {
		mv := methodView{ID: m, Name: p.T("method.alipay"), Available: a.provider(m) != nil}
		if m == "wechat" {
			mv.Name = p.T("method.wechat")
		}
		p.Methods = append(p.Methods, mv)
	}
	return p
}

func (a *App) render(w http.ResponseWriter, name string, status int, p *page) {
	if jsPages[name] {
		p.I18N = i18n.JS(p.Lang)
	}
	t := a.pages[name]
	if legalPages[name] {
		t = a.pages[name+"/"+p.Lang]
	}
	var buf bytes.Buffer
	if err := t.ExecuteTemplate(&buf, "layout", p); err != nil {
		a.log.Error("render", "page", name, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	// Pages depend on the language (cookie or Accept-Language): a shared
	// cache (the CDN) must not keep them.
	if h.Get("Cache-Control") == "" {
		h.Set("Cache-Control", "private, no-cache")
	}
	h.Set("Vary", "Cookie, Accept-Language")
	h.Set("Content-Language", p.Lang)
	w.WriteHeader(status)
	w.Write(buf.Bytes())
}

func (a *App) pageHandler(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p := a.newPage(w, r)
		if name == "index" {
			p.Gallery, p.Hero = a.gallery(p.Lang), a.hero(p.Lang)
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
	p.NoIndex = true
	// Never echo the code into the page; oauth.js carries it over on a
	// language switch.
	for i := range p.Langs {
		p.Langs[i].URL = r.URL.Path + "?lang=" + url.QueryEscape(p.Langs[i].Code)
	}
	a.render(w, "oauth", http.StatusOK, p)
}

func (a *App) notFound(w http.ResponseWriter, r *http.Request) {
	p := a.newPage(w, r)
	p.NoIndex = true
	a.render(w, "notfound", http.StatusNotFound, p)
}

type buyData struct {
	Selected    string
	ReturnOrder string
}

func (a *App) buyPage(w http.ResponseWriter, r *http.Request) {
	p := a.newPage(w, r)
	sel := r.URL.Query().Get("product")
	if _, ok := a.cfg.OnSale(sel); !ok {
		sel = a.cfg.Products[0].ID
	}
	// ?order= is where Alipay's cashier sends the buyer back. It only tells
	// the page to resume polling; the status always comes from the API.
	ret := r.URL.Query().Get("order")
	if len(ret) > 32 {
		ret = ""
	}
	p.Data = buyData{Selected: sel, ReturnOrder: ret}
	a.render(w, "buy", http.StatusOK, p)
}
