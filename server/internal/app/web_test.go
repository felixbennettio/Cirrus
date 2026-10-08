package app

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestPagesRender(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	pages := []string{"/", "/buy", "/buy?product=cirrus-android", "/buy?order=C261006000001", "/license", "/privacy", "/terms", "/support",
		"/oauth/callback?code=abc&state=xyz"}
	for _, p := range pages {
		for _, lang := range []string{"zh", "en"} {
			path := p
			if strings.Contains(p, "?") {
				path += "&lang=" + lang
			} else {
				path += "?lang=" + lang
			}
			rec := h.get(path)
			body := rec.Body.String()
			if rec.Code != 200 {
				t.Fatalf("%s: %d\n%s", path, rec.Code, body)
			}
			if !strings.Contains(body, testICP) || !strings.Contains(body, `href="https://beian.miit.gov.cn/"`) {
				t.Errorf("%s: footer lacks the ICP link", path)
			}
			if !strings.Contains(body, "测试个体户") || !strings.Contains(body, `href="/privacy"`) || !strings.Contains(body, `href="/terms"`) {
				t.Errorf("%s: footer lacks operator or links", path)
			}
			if lang == "en" && !strings.Contains(body, `lang="en"`) {
				t.Errorf("%s: not English", path)
			}
			if lang == "zh" && !strings.Contains(body, `lang="zh-Hans"`) {
				t.Errorf("%s: not Chinese", path)
			}
			for _, ext := range []string{"https://cdn", "googleapis", "jsdelivr", "unpkg"} {
				if strings.Contains(body, ext) {
					t.Errorf("%s: loads %s", path, ext)
				}
			}
		}
	}

	// The language choice is remembered in a cookie.
	req := httptest.NewRequest("GET", "/support", nil)
	req.AddCookie(&http.Cookie{Name: "lang", Value: "en"})
	rec := httptest.NewRecorder()
	h.app.Handler().ServeHTTP(rec, req)
	if !strings.Contains(rec.Body.String(), "Frequently asked questions") {
		t.Error("lang cookie ignored")
	}

	buy := h.get("/buy?product=cirrus-android").Body.String()
	if !strings.Contains(buy, `value="cirrus-android" checked`) && !strings.Contains(buy, `required value="cirrus-android" checked`) {
		t.Error("buy page does not preselect the product")
	}
	if !strings.Contains(buy, `id="i18n">{"`) {
		t.Error("buy page lacks its strings")
	}
	priv := h.get("/privacy?lang=zh-Hans").Body.String()
	for _, s := range []string{"support@cirrus.test", "2026-10-06", "14 周岁", "SHA-256"} {
		if !strings.Contains(priv, s) {
			t.Errorf("privacy page lacks %q", s)
		}
	}
	terms := h.get("/terms?lang=zh-Hans").Body.String()
	for _, s := range []string{"14 天", "中华人民共和国", "Licensed Application", "Cloudflare, Inc."} {
		if !strings.Contains(terms, s) {
			t.Errorf("terms page lacks %q", s)
		}
	}

	for path, ctype := range map[string]string{"/static/site.css": "text/css", "/static/buy.js": "javascript", "/static/favicon.svg": "image/svg+xml"} {
		rec := h.get(path)
		if rec.Code != 200 || !strings.Contains(rec.Header().Get("Content-Type"), ctype) {
			t.Errorf("%s: %d %s", path, rec.Code, rec.Header().Get("Content-Type"))
		}
	}
	if rec := h.get("/static/"); rec.Code != 404 {
		t.Errorf("static directory listing: %d", rec.Code)
	}
	if rec := h.get("/no-such-page"); rec.Code != 404 || !strings.Contains(rec.Body.String(), testICP) {
		t.Errorf("404 page: %d", rec.Code)
	}
	if rec := h.get("/static/pay/other.png"); rec.Code != 404 {
		t.Errorf("arbitrary pay image: %d", rec.Code)
	}
	if rec := h.get("/robots.txt"); rec.Code != 200 {
		t.Errorf("robots: %d", rec.Code)
	}
	if rec := h.get("/"); !strings.Contains(rec.Header().Get("Content-Security-Policy"), "default-src 'self'") {
		t.Error("no CSP header")
	}
}

func TestUnavailableMethodShown(t *testing.T) {
	h := newHarness(t, harnessOpt{noQR: []string{"wechat"}})
	body := h.get("/buy?lang=zh-Hans").Body.String()
	if !strings.Contains(body, `value="wechat" disabled`) || !strings.Contains(body, "暂不可用") {
		t.Error("missing QR image should mark WeChat unavailable")
	}
}

func TestAdminAuth(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	rec := h.get("/admin")
	if rec.Code != 401 || !strings.HasPrefix(rec.Header().Get("WWW-Authenticate"), "Basic") {
		t.Fatalf("no credentials: %d %v", rec.Code, rec.Header())
	}
	bad := func(user, pass string) int {
		req := httptest.NewRequest("GET", "/admin", nil)
		req.SetBasicAuth(user, pass)
		rec := httptest.NewRecorder()
		h.app.Handler().ServeHTTP(rec, req)
		return rec.Code
	}
	if bad("admin", "wrong") != 401 || bad("root", adminPass) != 401 {
		t.Fatal("wrong credentials accepted")
	}
	for _, p := range []string{"/admin", "/admin?status=pending", "/admin/licenses", "/admin/licenses?q=abc"} {
		if rec := h.admin("GET", p, nil); rec.Code != 200 {
			t.Fatalf("%s: %d %s", p, rec.Code, rec.Body.String())
		}
	}
	// Repeated failures lock the IP out for a while.
	for i := 0; i < 10; i++ {
		bad("admin", "guess")
	}
	if code := bad("admin", adminPass); code != http.StatusTooManyRequests {
		t.Fatalf("after 10 failures: %d", code)
	}

	// Without ADMIN_PASSWORD the admin pages do not exist.
	h2 := newHarness(t, harnessOpt{env: map[string]string{"ADMIN_PASSWORD": ""}})
	h2.cfg.AdminPassword = ""
	if rec := h2.admin("GET", "/admin", nil); rec.Code != 404 {
		t.Fatalf("admin disabled: %d", rec.Code)
	}
}

func TestAdminCSRF(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	l := h.issue("cirrus-linux", "c@example.com")
	path := "/admin/licenses/" + l.ID + "/revoke"
	send := func(origin, cookie, field string) int {
		form := url.Values{"csrf": {field}}
		req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.SetBasicAuth("admin", adminPass)
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		if cookie != "" {
			req.AddCookie(&http.Cookie{Name: csrfCookie, Value: cookie})
		}
		rec := httptest.NewRecorder()
		h.app.Handler().ServeHTTP(rec, req)
		return rec.Code
	}
	tok := strings.Repeat("cd", 16)
	if c := send("", tok, tok); c != 403 {
		t.Errorf("no Origin: %d", c)
	}
	if c := send("https://evil.example", tok, tok); c != 403 {
		t.Errorf("cross-origin: %d", c)
	}
	if c := send("http://example.com", tok, strings.Repeat("ef", 16)); c != 403 {
		t.Errorf("token mismatch: %d", c)
	}
	if c := send("http://example.com", "", tok); c != 403 {
		t.Errorf("no cookie: %d", c)
	}
	got, _ := h.st.LicenseByID(t.Context(), l.ID)
	if got.Revoked {
		t.Fatal("a rejected request revoked the licence")
	}
	if c := send("https://cirrus.test", tok, tok); c != http.StatusSeeOther {
		t.Errorf("PUBLIC_URL origin: %d", c)
	}

	// The admin page sets the CSRF cookie and embeds the token.
	rec := h.admin("GET", "/admin/licenses", nil)
	var cookie string
	for _, c := range rec.Result().Cookies() {
		if c.Name == csrfCookie {
			cookie = c.Value
			if !c.HttpOnly || c.SameSite != http.SameSiteStrictMode {
				t.Error("CSRF cookie flags")
			}
		}
	}
	if len(cookie) != 32 || !strings.Contains(rec.Body.String(), `value="`+cookie+`"`) {
		t.Fatal("admin page lacks the CSRF token")
	}
}

func TestAdminLicenseActions(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	rec := h.admin("POST", "/admin/issue", url.Values{"product": {"cirrus-android"}, "email": {"Gift@Example.com"}, "note": {"赠送"}, "send": {"1"}})
	loc := rec.Header().Get("Location")
	if rec.Code != http.StatusSeeOther || !strings.HasPrefix(loc, "/admin/licenses/lic_") {
		t.Fatalf("issue: %d %s", rec.Code, loc)
	}
	id := strings.TrimPrefix(strings.Split(loc, "?")[0], "/admin/licenses/")
	l, err := h.st.LicenseByID(t.Context(), id)
	if err != nil || l.Email != "gift@example.com" || l.MaxDevices != 1 || l.Note != "赠送" {
		t.Fatalf("issued: %+v %v", l, err)
	}
	h.app.Wait()
	if mails := h.mail.all(); len(mails) != 1 || !strings.Contains(mails[0].Body, l.Key) {
		t.Fatalf("issue mail: %+v", mails)
	}

	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(1), "android")), 200, "")
	page := h.admin("GET", "/admin/licenses/"+id, nil)
	if page.Code != 200 || !strings.Contains(page.Body.String(), l.Key) || !strings.Contains(page.Body.String(), "host-"+dev(1)[:6]) {
		t.Fatalf("licence page: %d", page.Code)
	}
	if s := h.admin("GET", "/admin/licenses?q="+url.QueryEscape("gift@"), nil).Body.String(); !strings.Contains(s, l.Key) {
		t.Fatal("search by email")
	}

	act := func(action string) {
		t.Helper()
		if rec := h.admin("POST", "/admin/licenses/"+id+"/"+action, url.Values{"note": {"n"}}); rec.Code != http.StatusSeeOther {
			t.Fatalf("%s: %d", action, rec.Code)
		}
	}
	act("revoke")
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(1), "android")), 410, "revoked")
	act("unrevoke")
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(1), "android")), 200, "")
	act("reset")
	if got, _ := h.st.LicenseByID(t.Context(), id); got.DevicesUsed != 0 || !got.LastResetAt.IsZero() {
		t.Fatalf("admin reset: %+v", got)
	}
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(2), "android")), 200, "")
	if rec := h.admin("POST", "/admin/licenses/"+id+"/devices/"+dev(2)+"/remove", url.Values{}); rec.Code != http.StatusSeeOther {
		t.Fatalf("remove device: %d", rec.Code)
	}
	act("note")
	act("resend")
	if rec := h.admin("POST", "/admin/licenses/"+id+"/explode", url.Values{}); rec.Code != 404 {
		t.Fatalf("unknown action: %d", rec.Code)
	}
	if rec := h.admin("GET", "/admin/licenses/lic_missing", nil); rec.Code != 404 {
		t.Fatalf("missing licence: %d", rec.Code)
	}
	h.app.Wait()
}

func TestOAuthCallbackPage(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	rec := h.get("/oauth/callback?code=abc&state=xyz")
	if rec.Code != 200 {
		t.Fatalf("status %d", rec.Code)
	}
	hdr := rec.Header()
	if hdr.Get("Cache-Control") != "no-store" || hdr.Get("Referrer-Policy") != "no-referrer" {
		t.Errorf("headers: Cache-Control %q, Referrer-Policy %q", hdr.Get("Cache-Control"), hdr.Get("Referrer-Policy"))
	}
	body := rec.Body.String()
	// The code only reaches the app through oauth.js; the page never echoes it.
	if strings.Contains(body, "abc") || !strings.Contains(body, "/static/oauth.js") || !strings.Contains(body, `id="oauth-open"`) {
		t.Errorf("unexpected page:\n%s", body)
	}
	if js := h.get("/static/oauth.js"); js.Code != 200 || !strings.Contains(js.Body.String(), "io.felixbennett.cirrus:/oauth/callback") {
		t.Errorf("oauth.js: %d", js.Code)
	}
}

// /static/logo.png is the logo URL of the Cloudflare OAuth client.
func TestLogoServed(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	rec := h.get("/static/logo.png")
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("logo: %d %q", rec.Code, rec.Header().Get("Content-Type"))
	}
}
