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
	if len(c.Products) != 3 {
		t.Fatalf("products: %+v", c.Products)
	}
	want := map[string][2]any{
		"cirrus-windows": {"windows", 1},
		"cirrus-linux":   {"linux", 1},
		"cirrus-android": {"android", 3},
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
