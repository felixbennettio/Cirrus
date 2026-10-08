// Package config reads the server configuration from environment variables.
// Every variable is documented in server/.env.example and server/README.md.
package config

import (
	"fmt"
	"net/mail"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"cirrus/server/internal/money"
)

// Product is one licence product. The ids, platforms and default device
// limits come from docs/licensing.md.
type Product struct {
	ID         string // cirrus-windows
	Platform   string // windows
	Suffix     string // WINDOWS, used for per-product env overrides
	NameZH     string
	NameEN     string
	MaxDevices int
	PriceCents int64  // CNY
	PriceUSD   string // display only, e.g. "39.99"
}

// Download is a published build of the app for one platform, from the
// DOWNLOAD_*_<PLATFORM> variables.
type Download struct {
	Platform string // windows, macos, linux, android
	URL      string
	Version  string // optional
	SHA256   string // optional, lowercase hex
}

// Alipay holds the Alipay API settings. It is enabled only when AppID,
// PrivateKey (应用私钥) and PublicKey (支付宝公钥) are all set. Mode is
// "precreate" (当面付, default) or "page" (电脑网站支付).
type Alipay struct {
	AppID      string
	PrivateKey string
	PublicKey  string
	Gateway    string
	Mode       string
}

// Enabled reports whether Face-to-Face payment is configured.
func (a Alipay) Enabled() bool {
	return a.AppID != "" && a.PrivateKey != "" && a.PublicKey != ""
}

// WeChat holds the WeChat Pay APIv3 settings (Native 支付). It is enabled
// only when everything but Gateway is set.
type WeChat struct {
	MchID       string // 商户号
	AppID       string // AppID bound to the merchant
	APIv3Key    string // 32 bytes
	CertSerial  string // serial number of the merchant API certificate
	PrivateKey  string // apiclient_key.pem
	PublicKey   string // 微信支付公钥
	PublicKeyID string // PUB_KEY_ID_…
	Gateway     string
}

// Enabled reports whether WeChat Pay Native is configured.
func (w WeChat) Enabled() bool { return w.setCount() == 7 }

func (w WeChat) setCount() int {
	n := 0
	for _, v := range []string{w.MchID, w.AppID, w.APIv3Key, w.CertSerial, w.PrivateKey, w.PublicKey, w.PublicKeyID} {
		n += btoi(v != "")
	}
	return n
}

// OAuth is the Cloudflare OAuth client the apps sign in with, served by
// GET /api/v1/oauth/config. Scopes come from the Cloudflare API when
// AccountID and API credentials are set, else from OAUTH_SCOPES.
type OAuth struct {
	ClientID       string
	Scopes         []string
	OptionalScopes []string

	AccountID string
	APIToken  string // Bearer token, preferred
	APIEmail  string // with APIKey: Global API Key
	APIKey    string
	APIBase   string // Cloudflare API base URL; not from the environment
}

// SyncEnabled reports whether the scopes are synced from Cloudflare.
func (o OAuth) SyncEnabled() bool {
	return o.AccountID != "" && (o.APIToken != "" || (o.APIEmail != "" && o.APIKey != ""))
}

// SMTP holds the optional mail settings for sending licence keys.
type SMTP struct {
	Host string
	Port int
	User string
	Pass string
	From string
}

// Enabled reports whether licence emails can be sent.
func (s SMTP) Enabled() bool { return s.Host != "" && s.From != "" }

// Config is the whole server configuration.
type Config struct {
	Listen     string
	DataDir    string
	PublicURL  string
	TrustProxy bool
	// ClientIPHeader names the header a CDN in front of the reverse proxy
	// puts the client's address in (e.g. EO-Connecting-IP for EdgeOne).
	ClientIPHeader string

	AdminPassword string

	SiteName      string
	OperatorName  string
	ContactEmail  string
	ICPNumber     string
	PolicyDate    string
	PriceCNYCents int64
	PriceUSD      string

	// DownloadURL is the general download link (e.g. GitHub Releases);
	// Downloads are the per-platform builds that are configured, in display
	// order; AppStoreURL is the App Store page (iPhone, iPad and Mac).
	DownloadURL string
	Downloads   []Download
	AppStoreURL string
	// GooglePlayURL is the Google Play page of the Android app.
	GooglePlayURL string

	// Products are the products on sale (PRODUCTS); every known product,
	// sold or not, stays valid for existing orders and licences.
	Products   []Product
	known      []Product
	PayMethods []string

	Alipay Alipay
	WeChat WeChat
	OAuth  OAuth
	SMTP   SMTP
}

// Product returns the product with the given id, whether or not it is on
// sale, so that orders and licences of a product taken off sale keep working.
func (c *Config) Product(id string) (Product, bool) {
	for _, p := range c.known {
		if p.ID == id {
			return p, true
		}
	}
	return Product{}, false
}

// OnSale returns the product with the given id when it is listed in PRODUCTS.
func (c *Config) OnSale(id string) (Product, bool) {
	for _, p := range c.Products {
		if p.ID == id {
			return p, true
		}
	}
	return Product{}, false
}

// Download returns the configured build for a platform.
func (c *Config) Download(platform string) (Download, bool) {
	for _, d := range c.Downloads {
		if d.Platform == platform {
			return d, true
		}
	}
	return Download{}, false
}

// MethodEnabled reports whether the payment method is listed in PAY_METHODS.
func (c *Config) MethodEnabled(m string) bool {
	for _, x := range c.PayMethods {
		if x == m {
			return true
		}
	}
	return false
}

// PublicHost is the host part of PUBLIC_URL.
func (c *Config) PublicHost() string {
	u, err := url.Parse(c.PublicURL)
	if err != nil {
		return ""
	}
	return u.Host
}

// baseProducts are all known products, in display order. cirrus-macos is
// the Developer ID build sold outside the Mac App Store.
var baseProducts = []Product{
	{ID: "cirrus-windows", Platform: "windows", Suffix: "WINDOWS", NameZH: "Windows 版", NameEN: "Windows", MaxDevices: 1},
	{ID: "cirrus-macos", Platform: "macos", Suffix: "MACOS", NameZH: "macOS 版", NameEN: "macOS", MaxDevices: 1},
	{ID: "cirrus-linux", Platform: "linux", Suffix: "LINUX", NameZH: "Linux 版", NameEN: "Linux", MaxDevices: 1},
	{ID: "cirrus-android", Platform: "android", Suffix: "ANDROID", NameZH: "Android 版", NameEN: "Android", MaxDevices: 1},
}

// Platforms are the platforms with licences and direct downloads, in
// display order.
func Platforms() []string {
	out := make([]string, len(baseProducts))
	for i, p := range baseProducts {
		out[i] = p.Platform
	}
	return out
}

// Load builds the configuration from getenv (normally os.Getenv).
func Load(getenv func(string) string) (*Config, error) {
	env := func(k, def string) string {
		if v := strings.TrimSpace(getenv(k)); v != "" {
			return v
		}
		return def
	}
	var errs []string
	fail := func(format string, a ...any) { errs = append(errs, fmt.Sprintf(format, a...)) }

	c := &Config{
		Listen:        env("LISTEN", ":8080"),
		DataDir:       env("DATA_DIR", "/data"),
		PublicURL:     strings.TrimRight(env("PUBLIC_URL", "https://cirrus.routeforge.zone"), "/"),
		AdminPassword: getenv("ADMIN_PASSWORD"),
		SiteName:      env("SITE_NAME", "卷云 Cirrus"),
		OperatorName:  env("OPERATOR_NAME", ""),
		ContactEmail:  env("CONTACT_EMAIL", ""),
		ICPNumber:     env("ICP_NUMBER", ""),
		PolicyDate:    env("POLICY_EFFECTIVE_DATE", "2026-10-06"),
		DownloadURL:   env("DOWNLOAD_URL", ""),
		AppStoreURL:   env("APP_STORE_URL", ""),
		GooglePlayURL: env("GOOGLE_PLAY_URL", ""),
		Alipay: Alipay{
			AppID:      env("ALIPAY_APP_ID", ""),
			PrivateKey: env("ALIPAY_PRIVATE_KEY", ""),
			PublicKey:  env("ALIPAY_PUBLIC_KEY", ""),
			Gateway:    env("ALIPAY_GATEWAY", "https://openapi.alipay.com/gateway.do"),
			Mode:       strings.ToLower(env("ALIPAY_MODE", "precreate")),
		},
		WeChat: WeChat{
			MchID:       env("WECHAT_MCHID", ""),
			AppID:       env("WECHAT_APPID", ""),
			APIv3Key:    env("WECHAT_API_V3_KEY", ""),
			CertSerial:  env("WECHAT_CERT_SERIAL", ""),
			PrivateKey:  env("WECHAT_PRIVATE_KEY", ""),
			PublicKey:   env("WECHAT_PUBLIC_KEY", ""),
			PublicKeyID: env("WECHAT_PUBLIC_KEY_ID", ""),
			Gateway:     strings.TrimRight(env("WECHAT_GATEWAY", "https://api.mch.weixin.qq.com"), "/"),
		},
		OAuth: OAuth{
			ClientID:       env("OAUTH_CLIENT_ID", "9c147a5155baf903357222bd4d31ad50"),
			Scopes:         scopeList(env("OAUTH_SCOPES", "")),
			OptionalScopes: scopeList(env("OAUTH_OPTIONAL_SCOPES", "")),
			AccountID:      env("CF_ACCOUNT_ID", ""),
			APIToken:       env("CF_API_TOKEN", ""),
			APIEmail:       env("CF_API_EMAIL", ""),
			APIKey:         env("CF_API_KEY", ""),
			APIBase:        "https://api.cloudflare.com/client/v4",
		},
		SMTP: SMTP{
			Host: env("SMTP_HOST", ""),
			User: env("SMTP_USER", ""),
			Pass: getenv("SMTP_PASS"),
			From: env("SMTP_FROM", ""),
		},
	}

	if u, err := url.Parse(c.PublicURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		fail("PUBLIC_URL must be an absolute http(s) URL, got %q", c.PublicURL)
	}

	tp, err := parseBool(env("TRUST_PROXY", "true"))
	if err != nil {
		fail("TRUST_PROXY: %v", err)
	}
	c.TrustProxy = tp
	c.ClientIPHeader = strings.TrimSpace(env("CLIENT_IP_HEADER", ""))
	if strings.IndexFunc(c.ClientIPHeader, func(r rune) bool {
		return r != '-' && (r > unicode.MaxASCII || !unicode.IsLetter(r) && !unicode.IsDigit(r))
	}) >= 0 {
		fail("CLIENT_IP_HEADER is not a header name: %q", c.ClientIPHeader)
	}

	if c.ContactEmail != "" {
		if _, err := mail.ParseAddress(c.ContactEmail); err != nil {
			fail("CONTACT_EMAIL is not an email address: %q", c.ContactEmail)
		}
	}

	c.PriceCNYCents, err = money.Parse(env("PRICE_CNY", "198"))
	if err != nil || c.PriceCNYCents <= 0 {
		fail("PRICE_CNY must be a positive amount like 198 or 198.00")
	}
	c.PriceUSD = env("PRICE_USD", "39.99")
	if _, err := money.Parse(c.PriceUSD); err != nil {
		fail("PRICE_USD must be an amount like 39.99")
	}

	onSale := map[string]bool{}
	for _, v := range strings.Split(env("PRODUCTS", "windows,macos,linux,android"), ",") {
		v = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(v), "cirrus-"))
		if v == "" {
			continue
		}
		if !slices.Contains(Platforms(), v) {
			fail("PRODUCTS: unknown product %q (use windows, macos, linux, android)", v)
		}
		onSale[v] = true
	}
	if len(onSale) == 0 {
		fail("PRODUCTS must list at least one of windows, macos, linux, android")
	}

	for _, p := range baseProducts {
		p.PriceCents = c.PriceCNYCents
		p.PriceUSD = c.PriceUSD
		if v := env("PRICE_CNY_"+p.Suffix, ""); v != "" {
			cents, err := money.Parse(v)
			if err != nil || cents <= 0 {
				fail("PRICE_CNY_%s must be a positive amount", p.Suffix)
			}
			p.PriceCents = cents
		}
		if v := env("PRICE_USD_"+p.Suffix, ""); v != "" {
			if _, err := money.Parse(v); err != nil {
				fail("PRICE_USD_%s must be an amount like 39.99", p.Suffix)
			}
			p.PriceUSD = v
		}
		if v := env("MAX_DEVICES_"+p.Suffix, ""); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > 1000 {
				fail("MAX_DEVICES_%s must be a whole number from 1 to 1000", p.Suffix)
			}
			p.MaxDevices = n
		}
		c.known = append(c.known, p)
		if onSale[p.Platform] {
			c.Products = append(c.Products, p)
		}
	}

	version := env("DOWNLOAD_VERSION", "")
	for _, p := range baseProducts {
		d := Download{
			Platform: p.Platform,
			URL:      env("DOWNLOAD_URL_"+p.Suffix, ""),
			Version:  env("DOWNLOAD_VERSION_"+p.Suffix, version),
			SHA256:   strings.ToLower(env("DOWNLOAD_SHA256_"+p.Suffix, "")),
		}
		if d.URL == "" {
			continue // version and checksum alone are ignored
		}
		if u, err := url.Parse(d.URL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			fail("DOWNLOAD_URL_%s must be an absolute http(s) URL", p.Suffix)
		}
		if d.SHA256 != "" && !isHex(d.SHA256, 64) {
			fail("DOWNLOAD_SHA256_%s must be 64 hexadecimal characters", p.Suffix)
		}
		if strings.ContainsAny(d.Version, "<>\"\n") || len(d.Version) > 40 {
			fail("DOWNLOAD_VERSION_%s (or DOWNLOAD_VERSION) is not a version", p.Suffix)
		}
		c.Downloads = append(c.Downloads, d)
	}

	for _, m := range strings.Split(env("PAY_METHODS", "alipay,wechat"), ",") {
		m = strings.ToLower(strings.TrimSpace(m))
		switch m {
		case "":
		case "alipay", "wechat":
			if !c.MethodEnabled(m) {
				c.PayMethods = append(c.PayMethods, m)
			}
		default:
			fail("PAY_METHODS: unknown method %q (use alipay, wechat)", m)
		}
	}

	a := c.Alipay
	if set := btoi(a.AppID != "") + btoi(a.PrivateKey != "") + btoi(a.PublicKey != ""); set > 0 && set < 3 {
		fail("the Alipay API needs all of ALIPAY_APP_ID, ALIPAY_PRIVATE_KEY and ALIPAY_PUBLIC_KEY")
	}
	if a.Mode != "precreate" && a.Mode != "page" {
		fail("ALIPAY_MODE must be precreate or page, got %q", a.Mode)
	}
	if u, err := url.Parse(a.Gateway); err != nil || u.Scheme == "" || u.Host == "" {
		fail("ALIPAY_GATEWAY must be an absolute URL")
	}

	wc := c.WeChat
	if n := wc.setCount(); n > 0 && n < 7 {
		fail("the WeChat Pay API needs all of WECHAT_MCHID, WECHAT_APPID, WECHAT_API_V3_KEY, WECHAT_CERT_SERIAL, " +
			"WECHAT_PRIVATE_KEY, WECHAT_PUBLIC_KEY and WECHAT_PUBLIC_KEY_ID")
	}
	if wc.APIv3Key != "" && len(wc.APIv3Key) != 32 {
		fail("WECHAT_API_V3_KEY must be 32 characters, got %d", len(wc.APIv3Key))
	}
	if u, err := url.Parse(wc.Gateway); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		fail("WECHAT_GATEWAY must be an absolute URL")
	}

	oa := c.OAuth
	if oa.ClientID == "" || strings.ContainsAny(oa.ClientID, "/?#% ") {
		fail("OAUTH_CLIENT_ID is not a valid client id")
	}
	if (oa.AccountID != "" || oa.APIToken != "" || oa.APIEmail != "" || oa.APIKey != "") && !oa.SyncEnabled() {
		fail("OAuth scope sync needs CF_ACCOUNT_ID plus CF_API_TOKEN, or CF_ACCOUNT_ID plus CF_API_EMAIL and CF_API_KEY")
	}

	port, err := strconv.Atoi(env("SMTP_PORT", "465"))
	if err != nil || port < 1 || port > 65535 {
		fail("SMTP_PORT must be a port number")
	}
	c.SMTP.Port = port
	if c.SMTP.From == "" {
		c.SMTP.From = c.SMTP.User
	}
	if c.SMTP.Host != "" {
		if c.SMTP.From == "" {
			fail("SMTP_FROM (or SMTP_USER) is required when SMTP_HOST is set")
		} else if _, err := mail.ParseAddress(c.SMTP.From); err != nil {
			fail("SMTP_FROM is not an email address: %q", c.SMTP.From)
		}
	}

	if len(errs) > 0 {
		return nil, fmt.Errorf("configuration: %s", strings.Join(errs, "; "))
	}
	return c, nil
}

// scopeList splits a space- or comma-separated list.
func scopeList(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ',' || unicode.IsSpace(r) })
}

func isHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

func parseBool(s string) (bool, error) {
	switch strings.ToLower(s) {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	}
	return false, fmt.Errorf("expected true or false, got %q", s)
}
