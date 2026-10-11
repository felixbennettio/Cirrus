package app

import (
	"crypto/sha256"
	"encoding/hex"
	"html"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"cirrus/server/internal/i18n"
)

// Every message id used by the templates, the Go code and the scripts
// exists (TestCatalogsComplete then checks all six languages have it).
func TestTranslationKeysExist(t *testing.T) {
	used := map[string]string{} // id → where
	tmplRe := regexp.MustCompile(`\.(?:T|H|N) "([a-z0-9_.]+)"`)
	fs.WalkDir(templateFS, "templates", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.Contains(path, "admin_") {
			return err
		}
		b, _ := templateFS.ReadFile(path)
		for _, m := range tmplRe.FindAllStringSubmatch(string(b), -1) {
			used[m[1]] = path
		}
		return nil
	})
	// Whole literals only: ids built at run time ("shots."+id) are checked
	// by TestGalleryImagesListed.
	goRe := regexp.MustCompile(`(?:\btrN?\(r,\s*|i18n\.(?:T|N|HTML)\([A-Za-z.]+,\s*|\bp\.(?:T|N|H)\()"([a-z0-9_.-]+)"\s*[,)]`)
	files, _ := filepath.Glob("*.go")
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, _ := os.ReadFile(f)
		for _, m := range goRe.FindAllStringSubmatch(string(b), -1) {
			used[m[1]] = f
		}
	}
	jsRe := regexp.MustCompile(`\bt\('([a-z0-9_]+)'`)
	fs.WalkDir(staticFS, "static", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".js") {
			return err
		}
		b, _ := staticFS.ReadFile(path)
		for _, m := range jsRe.FindAllStringSubmatch(string(b), -1) {
			if m[1] != "err_" {
				used["js."+m[1]] = path
			}
		}
		return nil
	})
	// Ids the scripts build at run time: payment methods and order states.
	// (API errors arrive translated: the scripts send the page language.)
	for _, k := range []string{"alipay", "wechat", "pending", "paid", "expired"} {
		used["js."+k] = "static/*.js (dynamic)"
	}
	if len(used) < 150 {
		t.Fatalf("found only %d message ids; is the scan broken?", len(used))
	}
	for id, where := range used {
		if !i18n.Has(i18n.EN, id) {
			t.Errorf("%s uses %q, which is not in the catalogs", where, id)
		}
	}
}

var placeholderLeak = regexp.MustCompile(`\{[a-z_]+\}|\[\[[a-z0-9_.]+\]\]`)

// withoutScripts drops the JSON strings for the scripts, which keep their
// {placeholders} on purpose.
func withoutScripts(body string) string {
	if i := strings.Index(body, `<script type="application/json" id="i18n">`); i >= 0 {
		if j := strings.Index(body[i:], "</script>"); j >= 0 {
			return body[:i] + body[i+j:]
		}
	}
	return body
}

func TestPagesInAllLanguages(t *testing.T) {
	h := newHarness(t, harnessOpt{env: map[string]string{
		"DOWNLOAD_URL_WINDOWS": "https://dl.example.com/Cirrus-1.0.0-windows-setup.exe",
		"DOWNLOAD_VERSION":     "1.0.0",
		"APP_STORE_URL":        "https://apps.apple.com/app/id1",
	}})
	pages := map[string]int{
		"/": 200, "/buy": 200, "/buy?product=cirrus-macos": 200, "/license": 200, "/privacy": 200, "/terms": 200,
		"/support": 200, "/download": 200, "/no-such-page": 404, "/oauth/callback?code=abc&state=xyz": 200,
	}
	for path, status := range pages {
		for _, l := range i18n.Languages {
			sep := "?"
			if strings.Contains(path, "?") {
				sep = "&"
			}
			rec := h.get(path + sep + "lang=" + url.QueryEscape(l.Code))
			body := rec.Body.String()
			where := path + " [" + l.Code + "]"
			if rec.Code != status {
				t.Fatalf("%s: %d\n%s", where, rec.Code, body)
			}
			if !strings.Contains(body, `<html lang="`+l.Code+`"`) || rec.Header().Get("Content-Language") != l.Code {
				t.Errorf("%s: wrong language", where)
			}
			if m := placeholderLeak.FindString(withoutScripts(body)); m != "" {
				t.Errorf("%s: leaks %q", where, m)
			}
			for _, other := range i18n.Languages {
				if !strings.Contains(body, ">"+other.Name+"<") {
					t.Errorf("%s: language menu lacks %s", where, other.Name)
				}
			}
			// One alternate per language plus x-default.
			alternates := strings.Count(body, `rel="alternate" hreflang=`)
			indexable := status == 200 && !strings.HasPrefix(path, "/oauth")
			if (indexable && alternates != len(i18n.Languages)+1) || (!indexable && alternates != 0) {
				t.Errorf("%s: %d hreflang links", where, alternates)
			}
			if !strings.Contains(body, testICP) {
				t.Errorf("%s: footer lacks the ICP number", where)
			}
		}
	}
	// The translations differ by language and the legal pages carry the
	// note that the Simplified Chinese text prevails.
	notes := map[string]string{
		i18n.EN: "Simplified Chinese version prevails", i18n.FR: "chinois simplifié", i18n.JA: "簡体字中国語版が優先",
		i18n.RU: "упрощённом китайском", i18n.ZhHant: "以簡體中文版本為準",
	}
	for lang, note := range notes {
		for _, doc := range []string{"/privacy", "/terms"} {
			if body := h.get(doc + "?lang=" + lang).Body.String(); !strings.Contains(body, note) {
				t.Errorf("%s [%s] lacks %q", doc, lang, note)
			}
		}
	}
}

func TestLanguageSelection(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	lang := func(rec *httptest.ResponseRecorder) string { return rec.Header().Get("Content-Language") }

	rec := h.get("/support?lang=fr")
	if lang(rec) != i18n.FR || !strings.Contains(rec.Header().Get("Set-Cookie"), "lang=fr") {
		t.Fatalf("?lang=fr: %s %q", lang(rec), rec.Header().Get("Set-Cookie"))
	}
	if v := rec.Header().Get("Vary"); !strings.Contains(v, "Cookie") || !strings.Contains(v, "Accept-Language") {
		t.Errorf("Vary = %q", v)
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "private") {
		t.Errorf("Cache-Control = %q: the CDN must not share pages across languages", cc)
	}
	// The old values keep working.
	if rec := h.get("/?lang=zh"); lang(rec) != i18n.ZhHans || !strings.Contains(rec.Header().Get("Set-Cookie"), "lang=zh-Hans") {
		t.Errorf("?lang=zh: %s", lang(rec))
	}
	if rec := h.get("/?lang=en"); lang(rec) != i18n.EN {
		t.Errorf("?lang=en: %s", lang(rec))
	}
	cases := []struct {
		cookie, accept, want string
	}{
		{"ja", "fr", i18n.JA},      // the cookie wins over the browser
		{"zh", "", i18n.ZhHans},    // old cookie value
		{"klingon", "ru", i18n.RU}, // a bad cookie is ignored
		{"", "zh-TW,zh;q=0.9", i18n.ZhHant},
		{"", "zh-CN,zh;q=0.9", i18n.ZhHans},
		{"", "de-DE,de;q=0.9", i18n.EN},
		{"", "", i18n.EN},
	}
	for _, c := range cases {
		hdr := map[string]string{}
		if c.accept != "" {
			hdr["Accept-Language"] = c.accept
		}
		if c.cookie != "" {
			hdr["Cookie"] = "lang=" + c.cookie
		}
		if got := lang(h.do(http.MethodGet, "/", nil, hdr)); got != c.want {
			t.Errorf("cookie %q accept %q: %s, want %s", c.cookie, c.accept, got, c.want)
		}
	}
	// A bad ?lang= falls through to the browser and sets no cookie.
	rec = h.do(http.MethodGet, "/?lang=xx", nil, map[string]string{"Accept-Language": "ja"})
	if lang(rec) != i18n.JA || rec.Header().Get("Set-Cookie") != "" {
		t.Errorf("?lang=xx: %s %q", lang(rec), rec.Header().Get("Set-Cookie"))
	}
	// API errors follow Accept-Language, else Simplified Chinese.
	m := expect(t, h.do(http.MethodPost, "/api/v1/orders", map[string]string{"product": "x", "email": "a@b.c", "method": "alipay"},
		map[string]string{"Accept-Language": "ja"}), 400, "invalid_product")
	if m["message"] != i18n.T(i18n.JA, "api.invalid_product") {
		t.Errorf("Japanese API message = %v", m["message"])
	}
	m = expect(t, h.post("/api/v1/orders", map[string]string{"product": "x", "email": "a@b.c", "method": "alipay"}), 400, "invalid_product")
	if m["message"] != i18n.T(i18n.ZhHans, "api.invalid_product") {
		t.Errorf("default API message = %v", m["message"])
	}
}

func TestMacOSProduct(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	if body := h.get("/buy?lang=en&product=cirrus-macos").Body.String(); !strings.Contains(body, `value="cirrus-macos" checked`) {
		t.Fatal("buy page does not offer and preselect the macOS product")
	}
	m := h.createOrder("cirrus-macos", "mac@example.com", "alipay", nil)
	no, tok := m["order_no"].(string), m["token"].(string)
	if rec := h.admin(http.MethodPost, "/admin/orders/"+no+"/confirm", url.Values{}); rec.Code != http.StatusSeeOther {
		t.Fatalf("confirm: %d", rec.Code)
	}
	key, _ := h.order(no, tok)["license_key"].(string)
	if key == "" {
		t.Fatal("no licence key")
	}
	a := expect(t, h.post("/api/v1/activate", activateBody(key, dev(1), "macos")), 200, "")
	lic := a["license"].(map[string]any)
	if lic["product"] != "cirrus-macos" || lic["platform"] != "macos" || lic["max_devices"] != 1.0 {
		t.Fatalf("license = %v", lic)
	}
	expect(t, h.post("/api/v1/activate", activateBody(key, dev(2), "macos")), 409, "activation_limit")
	w := expect(t, h.post("/api/v1/activate", activateBody(key, dev(3), "windows")), 403, "wrong_platform")
	if w["platform"] != "macos" {
		t.Errorf("wrong_platform names %v", w["platform"])
	}
	// A Windows licence cannot be used on a Mac either.
	win := h.issue("cirrus-windows", "")
	if w := expect(t, h.post("/api/v1/activate", activateBody(win.Key, dev(4), "macos")), 403, "wrong_platform"); w["platform"] != "windows" {
		t.Errorf("wrong_platform names %v", w["platform"])
	}
}

// Products can be taken off sale; their licences keep working.
func TestProductsOffSale(t *testing.T) {
	h := newHarness(t, harnessOpt{env: map[string]string{"PRODUCTS": "windows,linux"}})
	if body := h.get("/buy?lang=en").Body.String(); strings.Contains(body, "cirrus-macos") || strings.Contains(body, "cirrus-android") {
		t.Error("products off sale are offered")
	}
	expect(t, h.post("/api/v1/orders", map[string]string{"product": "cirrus-macos", "email": "a@example.com", "method": "alipay"}), 400, "invalid_product")
	l := h.issue("cirrus-macos", "")
	expect(t, h.post("/api/v1/activate", activateBody(l.Key, dev(1), "macos")), 200, "")
}

// The App Store and Google Play cards sit next to the products: a link once
// the store page is configured, a placeholder until then.
func TestStoreCards(t *testing.T) {
	soon := `<span class="btn disabled" aria-disabled="true">` + i18n.T(i18n.EN, "home.store_soon") + `</span>`
	h := newHarness(t, harnessOpt{})
	body := h.get("/?lang=en").Body.String()
	if n := strings.Count(body, `class="card price`); n != 6 {
		t.Errorf("%d price cards, want 4 products and 2 stores", n)
	}
	if strings.Count(body, soon) != 2 || !strings.Contains(body, "<h3>Android</h3>\n   <p class=\"tag\">Google Play</p>") {
		t.Error("store placeholders")
	}
	// Every product on the buy page has its tag, so the cards line up.
	if body := h.get("/buy?lang=en").Body.String(); strings.Count(body, `<span class="tag">`) != 4 {
		t.Errorf("buy page has %d product tags, want 4", strings.Count(body, `<span class="tag">`))
	}
	if body := h.get("/download?lang=en").Body.String(); strings.Contains(body, `id="google-play"`) || strings.Contains(body, `id="app-store"`) {
		t.Error("download page lists stores without a link")
	}

	h = newHarness(t, harnessOpt{env: map[string]string{
		"APP_STORE_URL":   "https://apps.apple.com/app/id1",
		"GOOGLE_PLAY_URL": "https://play.google.com/store/apps/details?id=zone.routeforge.cirrus",
	}})
	body = h.get("/?lang=ja").Body.String()
	for _, want := range []string{
		`<a class="btn" href="https://apps.apple.com/app/id1" rel="noopener">App Store</a>`,
		`<a class="btn" href="https://play.google.com/store/apps/details?id=zone.routeforge.cirrus" rel="noopener">Google Play</a>`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("home page lacks %s", want)
		}
	}
	if strings.Contains(body, "btn disabled") {
		t.Error("placeholder shown although the store is configured")
	}
	body = h.get("/download?lang=ja").Body.String()
	if !strings.Contains(body, `id="google-play"`) || !strings.Contains(body, i18n.T(i18n.JA, "download.gplay_btn")) {
		t.Error("download page lacks Google Play")
	}
}

func TestAdminPrices(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	if rec := h.admin(http.MethodGet, "/admin/prices", nil); rec.Code != 200 || !strings.Contains(rec.Body.String(), "cirrus-macos") {
		t.Fatalf("prices page: %d", rec.Code)
	}
	before := h.createOrder("cirrus-macos", "a@example.com", "alipay", nil)

	set := func(product string, form url.Values) string {
		t.Helper()
		rec := h.admin(http.MethodPost, "/admin/prices/"+product, form)
		if rec.Code != http.StatusSeeOther {
			t.Fatalf("set price: %d %s", rec.Code, rec.Body.String())
		}
		u, _ := url.Parse(rec.Header().Get("Location"))
		return u.Query().Get("msg")
	}
	if msg := set("cirrus-macos", url.Values{"cny": {"260"}, "usd": {"39.99"}}); msg != "price_saved" {
		t.Fatalf("msg = %q", msg)
	}
	if m := h.createOrder("cirrus-macos", "a@example.com", "alipay", nil); m["amount"] != "260.00" {
		t.Errorf("new macOS order amount = %v", m["amount"])
	}
	if m := h.createOrder("cirrus-linux", "a@example.com", "alipay", nil); m["amount"] != "198.00" {
		t.Errorf("Linux order amount = %v", m["amount"])
	}
	if o := h.order(before["order_no"].(string), before["token"].(string)); o["amount"] != "198.00" {
		t.Errorf("an existing order changed its amount: %v", o["amount"])
	}
	if body := h.get("/?lang=zh-Hans").Body.String(); !strings.Contains(body, "260") {
		t.Error("home page does not show the new price")
	}
	for _, bad := range []url.Values{{"cny": {"abc"}}, {"cny": {"0"}}, {"cny": {"-5"}}, {"cny": {"1.234"}}, {"cny": {"260"}, "usd": {"x"}}, {"cny": {"1000000"}}} {
		if msg := set("cirrus-macos", bad); msg != "bad_price" {
			t.Errorf("%v: msg = %q", bad, msg)
		}
	}
	if m := h.createOrder("cirrus-macos", "a@example.com", "alipay", nil); m["amount"] != "260.00" {
		t.Errorf("a rejected price changed the amount: %v", m["amount"])
	}
	if msg := set("cirrus-macos", url.Values{"action": {"reset"}}); msg != "price_reset" {
		t.Fatalf("reset msg = %q", msg)
	}
	if m := h.createOrder("cirrus-macos", "a@example.com", "alipay", nil); m["amount"] != "198.00" {
		t.Errorf("after reset amount = %v", m["amount"])
	}
	if rec := h.admin(http.MethodPost, "/admin/prices/cirrus-ios", url.Values{"cny": {"1"}}); rec.Code != 404 {
		t.Errorf("unknown product: %d", rec.Code)
	}
	// The price survives a restart: it lives in the database.
	set("cirrus-windows", url.Values{"cny": {"88.8"}})
	if err := h.app.reloadPrices(t.Context()); err != nil {
		t.Fatal(err)
	}
	if p, _ := h.app.onSale("cirrus-windows"); p.PriceCents != 8880 {
		t.Errorf("reloaded price = %d", p.PriceCents)
	}
}

func writeDownload(t *testing.T, dir, name, content string) string {
	t.Helper()
	os.MkdirAll(dir, 0o755)
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

func TestDownloads(t *testing.T) {
	h := newHarness(t, harnessOpt{env: map[string]string{
		"DOWNLOAD_URL_WINDOWS": "https://dl.example.com/Cirrus-1.0.0-windows-setup.exe",
		"DOWNLOAD_URL_MACOS":   "https://dl.example.com/elsewhere.dmg", // the manifest wins
		"DOWNLOAD_VERSION":     "1.0.0",
	}})
	dir := filepath.Join(h.dir, "downloads")

	// Nothing published yet: only the configured link.
	body := h.get("/download?lang=en").Body.String()
	if !strings.Contains(body, "https://dl.example.com/Cirrus-1.0.0-windows-setup.exe") || strings.Contains(body, `id="linux"`) {
		t.Fatal("download page before publishing")
	}

	dmg := "fake disk image contents"
	sum := writeDownload(t, dir, "Cirrus-1.1.0-macos.dmg", dmg)
	writeDownload(t, dir, ".Cirrus-1.2.0-macos.dmg.part", "upload in progress")
	writeDownload(t, dir, "manifest.json", `{"version":"1.1.0","files":{
		"macos":{"file":"Cirrus-1.1.0-macos.dmg","sha256":"`+sum+`"},
		"linux":[{"file":"Cirrus-1.1.0-linux.AppImage","sha256":"`+sum+`"}]}}`)
	os.Symlink(filepath.Join(h.dir, "cirrus.db"), filepath.Join(dir, "Cirrus-1.1.0-linux.deb"))

	body = h.get("/download?lang=en").Body.String()
	for _, want := range []string{`href="/downloads/Cirrus-1.1.0-macos.dmg"`, sum, "1.1.0", "Cirrus-1.0.0-windows-setup.exe"} {
		if !strings.Contains(body, want) {
			t.Errorf("download page lacks %q", want)
		}
	}
	// The manifest's Linux file is missing on disk, and the macOS link from
	// the environment is replaced by the published file.
	for _, unwanted := range []string{`id="linux"`, `id="android"`, "elsewhere.dmg"} {
		if strings.Contains(body, unwanted) {
			t.Errorf("download page shows %q", unwanted)
		}
	}

	rec := h.get("/downloads/Cirrus-1.1.0-macos.dmg")
	hd := rec.Header()
	if rec.Code != 200 || rec.Body.String() != dmg {
		t.Fatalf("download: %d %q", rec.Code, rec.Body.String())
	}
	if hd.Get("Content-Disposition") != `attachment; filename="Cirrus-1.1.0-macos.dmg"` ||
		hd.Get("Cache-Control") != "public, max-age=31536000, immutable" ||
		hd.Get("Content-Type") != "application/x-apple-diskimage" || hd.Get("Accept-Ranges") != "bytes" {
		t.Errorf("download headers: %v", hd)
	}
	rec = h.do(http.MethodGet, "/downloads/Cirrus-1.1.0-macos.dmg", nil, map[string]string{"Range": "bytes=5-8"})
	if rec.Code != http.StatusPartialContent || rec.Body.String() != dmg[5:9] {
		t.Errorf("range: %d %q", rec.Code, rec.Body.String())
	}
	rec = h.do(http.MethodHead, "/downloads/Cirrus-1.1.0-macos.dmg", nil, nil)
	if rec.Code != 200 || rec.Body.Len() != 0 || rec.Header().Get("Content-Length") != itoa(len(dmg)) {
		t.Errorf("HEAD: %d %d %q", rec.Code, rec.Body.Len(), rec.Header().Get("Content-Length"))
	}
	for _, bad := range []string{
		"/downloads/manifest.json", "/downloads/.Cirrus-1.2.0-macos.dmg.part", "/downloads/Cirrus-1.1.0-linux.deb",
		"/downloads/..%2fcirrus.db", "/downloads/missing.dmg", "/downloads/a%20b.dmg",
	} {
		if rec := h.get(bad); rec.Code != 404 {
			t.Errorf("%s: %d", bad, rec.Code)
		}
	}
	if rec := h.get("/downloads/"); rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "/download" {
		t.Errorf("/downloads/: %d %s", rec.Code, rec.Header().Get("Location"))
	}

	// The licence email links the purchased platform's download.
	m := h.createOrder("cirrus-macos", "mac@example.com", "alipay", map[string]string{"Accept-Language": "fr"})
	h.admin(http.MethodPost, "/admin/orders/"+m["order_no"].(string)+"/confirm", url.Values{})
	h.app.Wait()
	mails := h.mail.all()
	if len(mails) != 1 {
		t.Fatalf("mails = %d", len(mails))
	}
	if !strings.Contains(mails[0].Body, "https://cirrus.test/downloads/Cirrus-1.1.0-macos.dmg") ||
		strings.Contains(mails[0].Body, "windows-setup.exe") {
		t.Errorf("licence email download link:\n%s", mails[0].Body)
	}
	// French first, then the English text for the other languages.
	if !strings.HasPrefix(mails[0].Subject, i18n.T(i18n.FR, "mail.subject", "site", h.cfg.SiteName)+" / ") {
		t.Errorf("email subject %q is not French", mails[0].Subject)
	}
}

// A manifest that cannot be parsed is ignored rather than breaking pages.
func TestDownloadsBadManifest(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	writeDownload(t, filepath.Join(h.dir, "downloads"), "manifest.json", "{not json")
	if rec := h.get("/download?lang=en"); rec.Code != 200 || !strings.Contains(rec.Body.String(), i18n.T(i18n.EN, "download.none")) {
		t.Fatalf("download page with a broken manifest: %d", rec.Code)
	}
}

func TestGallery(t *testing.T) {
	h := newHarness(t, harnessOpt{})
	en := h.get("/?lang=en").Body.String()
	if !strings.Contains(en, `id="screenshots"`) || !strings.Contains(en, "/static/shots/en/home.webp") {
		t.Fatal("English home page lacks the gallery or the hero shot")
	}
	if strings.Contains(en, "/static/shots/zh-") {
		t.Error("English visitors see Chinese screenshots")
	}
	if !strings.Contains(en, `media="(prefers-color-scheme: dark)" srcset="/static/shots/en/home-dark.webp`) ||
		!strings.Contains(en, `media="(max-width: 640px)" srcset="/static/shots/en/m-home.webp`) ||
		!strings.Contains(en, `media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="/static/shots/en/m-home-dark.webp`) {
		t.Error("English hero lacks its dark or phone pictures")
	}
	// French has no pictures of its own yet: English ones, French captions.
	fr := h.get("/?lang=fr").Body.String()
	if !strings.Contains(fr, "/static/shots/en/") || !strings.Contains(fr, html.EscapeString(i18n.T(i18n.FR, "shots.title"))) {
		t.Error("French gallery")
	}
	// Traditional Chinese has no pictures of its own: Simplified Chinese ones.
	zh := h.get("/?lang=zh-Hant").Body.String()
	for _, want := range []string{"/static/shots/zh-Hans/dns.webp", "/static/shots/zh-Hans/m-home-dark-t.webp", i18n.T(i18n.ZhHant, "shots.dns")} {
		if !strings.Contains(zh, want) {
			t.Errorf("Traditional Chinese gallery lacks %q", want)
		}
	}
	hero, _, _ := strings.Cut(zh[strings.Index(zh, `<figure class="hero-shot"`):], "</figure>")
	if strings.Contains(hero, "/static/shots/en/") ||
		!strings.Contains(zh, `media="(prefers-color-scheme: dark)" srcset="/static/shots/zh-Hans/home-dark.webp`) ||
		!strings.Contains(zh, `srcset="/static/shots/zh-Hans/m-home.webp`) {
		t.Error("Traditional Chinese hero")
	}
	for _, g := range h.app.gallery(i18n.ZhHans) {
		for _, s := range g.Shots {
			if s.W == 0 || s.TW == 0 || s.Caption == "" || strings.HasPrefix(s.Caption, "[[") {
				t.Errorf("shot %s: %+v", s.ID, s)
			}
		}
	}
	rec := h.get("/static/shots/en/home-t.webp")
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "image/webp" || rec.Body.Len() < 1000 {
		t.Errorf("thumbnail: %d %s %d bytes", rec.Code, rec.Header().Get("Content-Type"), rec.Body.Len())
	}
	if rec := h.get("/static/gallery.js"); rec.Code != 200 {
		t.Errorf("gallery.js: %d", rec.Code)
	}
}

// Every screen in a group has a caption, and every picture belongs to a
// screen listed in a group.
func TestGalleryImagesListed(t *testing.T) {
	listed := map[string]bool{}
	for _, g := range shotGroups {
		listed[g.ID] = true
		if !i18n.Has(i18n.EN, "shots.g."+g.ID) {
			t.Errorf("group %s has no title", g.ID)
		}
		for _, id := range g.Shots {
			listed[id] = true
			if !i18n.Has(i18n.EN, "shots."+id) {
				t.Errorf("screen %s has no caption", id)
			}
		}
	}
	// Thumbnails are laid out three (phones: six) to a row: full rows only.
	for _, lang := range []string{i18n.EN, i18n.ZhHans, i18n.FR} {
		for _, g := range (&App{}).gallery(lang) {
			if len(g.Shots)%3 != 0 {
				t.Errorf("%s: group %s shows %d pictures, not a multiple of 3", lang, g.ID, len(g.Shots))
			}
		}
	}
	for key := range shotSizes {
		lang, id, _ := strings.Cut(key, "/")
		if _, ok := i18n.Get(lang); !ok || !listed[id] {
			t.Errorf("static/shots/index.json: %s is not a known language and screen", key)
		}
		for _, f := range []string{id + ".webp", id + "-t.webp"} {
			if _, err := fs.Stat(staticFS, "static/shots/"+lang+"/"+f); err != nil {
				t.Errorf("%s: %v", key, err)
			}
		}
	}
}

// scripts/publish_download.sh, pointed at a local directory, publishes
// files the site then offers and serves.
func TestPublishDownloadScript(t *testing.T) {
	for _, tool := range []string{"bash", "python3"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not installed", tool)
		}
	}
	h := newHarness(t, harnessOpt{})
	script := filepath.Join("..", "..", "scripts", "publish_download.sh")
	publish := func(args ...string) ([]byte, error) {
		cmd := exec.Command("bash", append([]string{script}, args...)...)
		cmd.Env = append(os.Environ(), "CIRRUS_DOWNLOADS="+filepath.Join(h.dir, "downloads"))
		return cmd.CombinedOutput()
	}
	src := t.TempDir()
	dmg := filepath.Join(src, "Cirrus-1.3.0-macos.dmg")
	sum := writeDownload(t, src, "Cirrus-1.3.0-macos.dmg", "a disk image")
	if out, err := publish("macos", dmg); err != nil {
		t.Fatalf("publish: %v\n%s", err, out)
	}
	body := h.get("/download?lang=en").Body.String()
	for _, want := range []string{`href="/downloads/Cirrus-1.3.0-macos.dmg"`, sum, "1.3.0"} {
		if !strings.Contains(body, want) {
			t.Errorf("download page lacks %q", want)
		}
	}
	if rec := h.get("/downloads/Cirrus-1.3.0-macos.dmg"); rec.Code != 200 || rec.Body.String() != "a disk image" {
		t.Errorf("published file: %d", rec.Code)
	}
	if out, err := publish("ios", dmg); err == nil {
		t.Errorf("an unknown platform was accepted:\n%s", out)
	}
	if out, err := publish("linux", filepath.Join(src, "missing.AppImage")); err == nil {
		t.Errorf("a missing file was accepted:\n%s", out)
	}
}
