package config

import (
	"strings"
	"testing"
)

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestDefaults(t *testing.T) {
	c, err := Load(envMap(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":8080" || c.DataDir != "/data" || !c.TrustProxy || c.SiteName != "卷云 Cirrus" {
		t.Fatalf("defaults: %+v", c)
	}
	if c.PublicURL != "https://cirrus.routeforge.zone" || c.PublicHost() != "cirrus.routeforge.zone" {
		t.Fatalf("public url %q", c.PublicURL)
	}
	if len(c.Products) != 4 {
		t.Fatalf("products: %+v", c.Products)
	}
	want := map[string][2]any{
		"cirrus-windows": {"windows", 1},
		"cirrus-macos":   {"macos", 1},
		"cirrus-linux":   {"linux", 1},
		"cirrus-android": {"android", 1},
	}
	for id, w := range want {
		p, ok := c.Product(id)
		if !ok || p.Platform != w[0] || p.MaxDevices != w[1] || p.PriceCents != 19800 || p.PriceUSD != "39.99" {
			t.Errorf("product %s = %+v", id, p)
		}
	}
	if strings.Join(c.PayMethods, ",") != "alipay,wechat" {
		t.Errorf("pay methods %v", c.PayMethods)
	}
	if c.Alipay.Enabled() || c.SMTP.Enabled() {
		t.Error("alipay/smtp should be off by default")
	}
	if c.SMTP.Port != 465 || c.Alipay.Gateway != "https://openapi.alipay.com/gateway.do" || c.Alipay.Mode != "precreate" {
		t.Error("smtp port / alipay gateway / alipay mode defaults")
	}
	if c, err := Load(envMap(map[string]string{"ALIPAY_MODE": "Page"})); err != nil || c.Alipay.Mode != "page" {
		t.Errorf("ALIPAY_MODE=Page: %v", err)
	}
	if c.WeChat.Enabled() || c.WeChat.Gateway != "https://api.mch.weixin.qq.com" {
		t.Errorf("wechat defaults: %+v", c.WeChat)
	}
	o := c.OAuth
	if o.ClientID != "9c147a5155baf903357222bd4d31ad50" || len(o.Scopes) != 0 || o.SyncEnabled() ||
		o.APIBase != "https://api.cloudflare.com/client/v4" {
		t.Errorf("oauth defaults: %+v", o)
	}
}

func TestWeChatAndOAuth(t *testing.T) {
	wc := map[string]string{
		"WECHAT_MCHID": "1900000001", "WECHAT_APPID": "wx0000000000000001", "WECHAT_API_V3_KEY": strings.Repeat("k", 32),
		"WECHAT_CERT_SERIAL": "5157F09EFDC096DE15EBE81A47057A7232F1B8E1", "WECHAT_PRIVATE_KEY": "x", "WECHAT_PUBLIC_KEY": "y",
		"WECHAT_PUBLIC_KEY_ID": "PUB_KEY_ID_0000000000000024101100397200000006", "WECHAT_GATEWAY": "http://127.0.0.1:9/",
		"OAUTH_SCOPES": "account:read, zone:read  dns:edit", "OAUTH_OPTIONAL_SCOPES": "workers:write",
		"CF_ACCOUNT_ID": "acc", "CF_API_EMAIL": "me@example.com", "CF_API_KEY": "gk",
	}
	c, err := Load(envMap(wc))
	if err != nil {
		t.Fatal(err)
	}
	if !c.WeChat.Enabled() || c.WeChat.Gateway != "http://127.0.0.1:9" {
		t.Errorf("wechat: %+v", c.WeChat)
	}
	if strings.Join(c.OAuth.Scopes, "|") != "account:read|zone:read|dns:edit" || strings.Join(c.OAuth.OptionalScopes, "|") != "workers:write" {
		t.Errorf("scopes: %q %q", c.OAuth.Scopes, c.OAuth.OptionalScopes)
	}
	if !c.OAuth.SyncEnabled() {
		t.Error("CF_ACCOUNT_ID + CF_API_EMAIL + CF_API_KEY should enable sync")
	}
	if c, err := Load(envMap(map[string]string{"CF_ACCOUNT_ID": "acc", "CF_API_TOKEN": "tok"})); err != nil || !c.OAuth.SyncEnabled() {
		t.Errorf("CF_API_TOKEN: %v", err)
	}
}

func TestInvalidWeChatAndOAuth(t *testing.T) {
	full := map[string]string{
		"WECHAT_MCHID": "1900000001", "WECHAT_APPID": "wx1", "WECHAT_API_V3_KEY": strings.Repeat("k", 32),
		"WECHAT_CERT_SERIAL": "S", "WECHAT_PRIVATE_KEY": "x", "WECHAT_PUBLIC_KEY": "y", "WECHAT_PUBLIC_KEY_ID": "PUB_KEY_ID_1",
	}
	with := func(k, v string) map[string]string {
		m := map[string]string{}
		for a, b := range full {
			m[a] = b
		}
		m[k] = v
		return m
	}
	for _, m := range []map[string]string{
		with("WECHAT_PUBLIC_KEY_ID", ""),
		with("WECHAT_API_V3_KEY", "short"),
		with("WECHAT_GATEWAY", "api.mch.weixin.qq.com"),
		{"CF_ACCOUNT_ID": "acc"},
		{"CF_API_TOKEN": "tok"},
		{"CF_ACCOUNT_ID": "acc", "CF_API_EMAIL": "me@example.com"},
		{"OAUTH_CLIENT_ID": "a/b"},
	} {
		if _, err := Load(envMap(m)); err == nil {
			t.Errorf("Load(%v) succeeded", m)
		}
	}
}

func TestOverrides(t *testing.T) {
	c, err := Load(envMap(map[string]string{
		"PRICE_CNY":           "99.5",
		"PRICE_CNY_ANDROID":   "68",
		"PRICE_USD_ANDROID":   "9.99",
		"MAX_DEVICES_ANDROID": "5",
		"MAX_DEVICES_LINUX":   "2",
		"PAY_METHODS":         " WeChat ",
		"TRUST_PROXY":         "off",
		"PUBLIC_URL":          "http://localhost:8080/",
		"SMTP_HOST":           "smtp.example.com",
		"SMTP_USER":           "bot@example.com",
	}))
	if err != nil {
		t.Fatal(err)
	}
	w, _ := c.Product("cirrus-windows")
	a, _ := c.Product("cirrus-android")
	l, _ := c.Product("cirrus-linux")
	if w.PriceCents != 9950 || a.PriceCents != 6800 || a.PriceUSD != "9.99" || a.MaxDevices != 5 || l.MaxDevices != 2 {
		t.Fatalf("overrides: %+v %+v %+v", w, a, l)
	}
	if c.TrustProxy || c.PublicURL != "http://localhost:8080" {
		t.Error("TRUST_PROXY / PUBLIC_URL")
	}
	if len(c.PayMethods) != 1 || c.PayMethods[0] != "wechat" {
		t.Errorf("pay methods %v", c.PayMethods)
	}
	if !c.SMTP.Enabled() || c.SMTP.From != "bot@example.com" {
		t.Error("SMTP_FROM should default to SMTP_USER")
	}
}

func TestInvalid(t *testing.T) {
	bad := []map[string]string{
		{"PRICE_CNY": "abc"},
		{"PRICE_CNY": "0"},
		{"MAX_DEVICES_WINDOWS": "0"},
		{"PAY_METHODS": "paypal"},
		{"TRUST_PROXY": "maybe"},
		{"ALIPAY_APP_ID": "2021000000000000"},
		{"PUBLIC_URL": "cirrus.routeforge.zone"},
		{"SMTP_HOST": "smtp.example.com"},
		{"SMTP_PORT": "smtp"},
		{"ALIPAY_MODE": "wap"},
	}
	for _, m := range bad {
		if _, err := Load(envMap(m)); err == nil {
			t.Errorf("Load(%v) succeeded", m)
		}
	}
}
