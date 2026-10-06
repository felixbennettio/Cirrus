// Package config reads the server configuration from environment variables.
// Every variable is documented in server/.env.example and server/README.md.
package config

import (
	"fmt"
	"net/mail"
	"net/url"
	"strconv"
	"strings"

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

	AdminPassword string

	SiteName      string
	OperatorName  string
	ContactEmail  string
	ICPNumber     string
	PolicyDate    string
	DownloadURL   string
	AppStoreURL   string
	PriceCNYCents int64
	PriceUSD      string

	Products   []Product
	PayMethods []string

	Alipay Alipay
	SMTP   SMTP
}

// Product returns the product with the given id.
func (c *Config) Product(id string) (Product, bool) {
	for _, p := range c.Products {
		if p.ID == id {
			return p, true
		}
	}
	return Product{}, false
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

var baseProducts = []Product{
	{ID: "cirrus-windows", Platform: "windows", Suffix: "WINDOWS", NameZH: "Windows 版", NameEN: "Windows", MaxDevices: 1},
	{ID: "cirrus-linux", Platform: "linux", Suffix: "LINUX", NameZH: "Linux 版", NameEN: "Linux", MaxDevices: 1},
	{ID: "cirrus-android", Platform: "android", Suffix: "ANDROID", NameZH: "Android 版", NameEN: "Android", MaxDevices: 3},
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
		Alipay: Alipay{
			AppID:      env("ALIPAY_APP_ID", ""),
			PrivateKey: env("ALIPAY_PRIVATE_KEY", ""),
			PublicKey:  env("ALIPAY_PUBLIC_KEY", ""),
			Gateway:    env("ALIPAY_GATEWAY", "https://openapi.alipay.com/gateway.do"),
			Mode:       strings.ToLower(env("ALIPAY_MODE", "precreate")),
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
		c.Products = append(c.Products, p)
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
