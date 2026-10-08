package i18n

import (
	"html/template"
	"slices"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	for in, want := range map[string]string{
		"en": EN, "EN-us": EN, "fr": FR, "fr-CA": FR, "ja": JA, "ja-JP": JA, "ru-RU": RU,
		"zh": ZhHans, "zh-CN": ZhHans, "zh_SG": ZhHans, "zh-Hans": ZhHans, "zh-Hans-HK": ZhHans,
		"zh-TW": ZhHant, "zh-HK": ZhHant, "zh-MO": ZhHant, "zh-Hant": ZhHant, "zh-hant-cn": ZhHant,
	} {
		if got, ok := Parse(in); !ok || got != want {
			t.Errorf("Parse(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "de", "x", "-"} {
		if got, ok := Parse(in); ok {
			t.Errorf("Parse(%q) = %q, want no match", in, got)
		}
	}
}

func TestNegotiate(t *testing.T) {
	for in, want := range map[string]string{
		"fr-CH, fr;q=0.9, en;q=0.8":       FR,
		"de-DE,de;q=0.9,en;q=0.5":         EN,
		"zh-TW,zh;q=0.9,en;q=0.8":         ZhHant,
		"zh-CN,zh;q=0.9":                  ZhHans,
		"en;q=0.5, ja;q=0.8":              JA,
		"ja;q=0, ru":                      RU,
		"ru;q=abc, en":                    EN,
		"*, zh-Hant-TW;q=0.7, en;q=0.6":   ZhHant,
		"  fr  ;  q=0.4 , de ;q=0.9  ":    FR,
		strings.Repeat("de,", 100) + "fr": "", // only the first 32 items count
	} {
		got, ok := Negotiate(in)
		if want == "" {
			if ok {
				t.Errorf("Negotiate(%.20q…) = %q, want no match", in, got)
			}
			continue
		}
		if !ok || got != want {
			t.Errorf("Negotiate(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "de", "*", "de;q=1, x-klingon"} {
		if got, ok := Negotiate(in); ok {
			t.Errorf("Negotiate(%q) = %q, want no match", in, got)
		}
	}
}

// Every language has exactly the English ids, with the same placeholders,
// and plural messages have as many forms as the language needs.
func TestCatalogsComplete(t *testing.T) {
	if len(en) < 100 {
		t.Fatalf("English catalog has only %d messages", len(en))
	}
	for _, l := range Languages {
		c := Catalog(l.Code)
		if c == nil {
			t.Fatalf("%s: no catalog", l.Code)
		}
		for key, enMsg := range en {
			msg, ok := c[key]
			if !ok {
				t.Errorf("%s: missing %q", l.Code, key)
				continue
			}
			if strings.TrimSpace(msg) == "" {
				t.Errorf("%s: %q is empty", l.Code, key)
			}
			plural := strings.Contains(enMsg, "|")
			if plural {
				if n := len(strings.Split(msg, "|")); n != Forms(l.Code) {
					t.Errorf("%s: %q has %d plural forms, want %d", l.Code, key, n, Forms(l.Code))
				}
			}
			if want, got := placeholderSet(enMsg, plural), placeholderSet(msg, plural); !slices.Equal(want, got) {
				t.Errorf("%s: %q has placeholders %v, want %v", l.Code, key, got, want)
			}
		}
		for key := range c {
			if _, ok := en[key]; !ok {
				t.Errorf("%s: %q is not in the English catalog", l.Code, key)
			}
		}
	}
}

// placeholderSet lists a message's placeholders once each. In plural
// messages {n} is optional (e.g. "one device"), so it is left out.
func placeholderSet(msg string, plural bool) []string {
	var out []string
	for _, p := range Placeholders(msg) {
		if (plural && p == "n") || slices.Contains(out, p) {
			continue
		}
		out = append(out, p)
	}
	slices.Sort(out)
	return out
}

func TestMessages(t *testing.T) {
	if got := T(EN, "devices"); !strings.Contains(got, "device") {
		t.Errorf("T without args = %q", got)
	}
	if got := N(EN, "devices", 1); got != "1 device" {
		t.Errorf("N(en, 1) = %q", got)
	}
	if got := N(EN, "devices", 3); got != "3 devices" {
		t.Errorf("N(en, 3) = %q", got)
	}
	for n, want := range map[int]int{1: 0, 2: 1, 4: 1, 5: 2, 11: 2, 12: 2, 21: 0, 22: 1, 25: 2, 111: 2} {
		if got := russianPlural(n); got != want {
			t.Errorf("russianPlural(%d) = %d, want %d", n, got, want)
		}
	}
	if got := T(FR, "no.such.id"); got != "[[no.such.id]]" {
		t.Errorf("missing id = %q", got)
	}
	if got := Number(FR, "39.99"); got != "39,99" {
		t.Errorf("Number(fr) = %q", got)
	}
	if got := Number(ZhHans, "39.99"); got != "39.99" {
		t.Errorf("Number(zh-Hans) = %q", got)
	}
	// HTML escapes the message and plain arguments but not template.HTML.
	h := string(expandHTML("a <b> {x} {y}", "x", "<i>", "y", template.HTML("<em>ok</em>")))
	if h != "a &lt;b&gt; &lt;i&gt; <em>ok</em>" {
		t.Errorf("HTML = %q", h)
	}
	js := JS(JA)
	if js["creating"] == "" || js["creating"] == JS(EN)["creating"] {
		t.Errorf("JS(ja) creating = %q", js["creating"])
	}
	for k := range js {
		if strings.HasPrefix(k, "js.") {
			t.Errorf("JS key keeps its prefix: %q", k)
		}
	}
}

// expandHTML runs HTML's escaping on an arbitrary message.
func expandHTML(msg string, args ...any) template.HTML {
	en["test.html"] = msg
	defer delete(en, "test.html")
	return HTML(EN, "test.html", args...)
}
