// Package i18n holds the website's message catalogs, one file per language,
// and picks the language for a request.
//
// Messages are looked up by id ("nav.buy"). They may contain named
// placeholders such as {amount}, filled from name/value argument pairs.
// Plural messages list their forms separated by "|", in the order of the
// language's plural categories (English: one|other; Russian:
// one|few|many; Japanese and Chinese have a single form); {n} is the count.
// Ids starting with "js." are the strings of the website's scripts.
package i18n

import (
	"fmt"
	"html"
	"html/template"
	"sort"
	"strconv"
	"strings"
)

// Language codes, as used in ?lang=, the lang cookie, <html lang> and
// hreflang.
const (
	EN     = "en"
	FR     = "fr"
	JA     = "ja"
	RU     = "ru"
	ZhHans = "zh-Hans"
	ZhHant = "zh-Hant"
)

// Language describes one supported language.
type Language struct {
	Code string // BCP 47 tag
	Name string // the language's name in itself, for the language menu

	decimalComma bool          // 39,99 instead of 39.99
	plural       func(int) int // index of the plural form for a count
	forms        int           // number of plural forms
}

// Languages lists the supported languages in menu order.
var Languages = []Language{
	{Code: EN, Name: "English", plural: oneOther, forms: 2},
	{Code: FR, Name: "Français", decimalComma: true, plural: frenchPlural, forms: 2},
	{Code: JA, Name: "日本語", plural: single, forms: 1},
	{Code: RU, Name: "Русский", decimalComma: true, plural: russianPlural, forms: 3},
	{Code: ZhHans, Name: "简体中文", plural: single, forms: 1},
	{Code: ZhHant, Name: "繁體中文", plural: single, forms: 1},
}

func oneOther(n int) int {
	if n == 1 {
		return 0
	}
	return 1
}

func frenchPlural(n int) int {
	if n == 0 || n == 1 {
		return 0
	}
	return 1
}

func russianPlural(n int) int {
	if n < 0 {
		n = -n
	}
	switch m10, m100 := n%10, n%100; {
	case m10 == 1 && m100 != 11:
		return 0
	case m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14):
		return 1
	}
	return 2
}

func single(int) int { return 0 }

var catalogs = map[string]map[string]string{
	EN: en, FR: fr, JA: ja, RU: ru, ZhHans: zhHans, ZhHant: zhHant,
}

// Get returns the language with the given canonical code.
func Get(code string) (Language, bool) {
	for _, l := range Languages {
		if l.Code == code {
			return l, true
		}
	}
	return Language{}, false
}

// Forms is the number of plural forms the language's messages need.
func Forms(code string) int {
	l, _ := Get(code)
	return l.forms
}

// Catalog returns the messages of a language (for tests).
func Catalog(code string) map[string]string { return catalogs[code] }

// Parse maps a language tag onto a supported language: "fr-CA" → fr,
// "zh", "zh-CN", "zh-SG" and "zh-Hans-*" → zh-Hans, "zh-TW", "zh-HK",
// "zh-MO" and "zh-Hant-*" → zh-Hant. Case and "_" separators are ignored.
func Parse(tag string) (string, bool) {
	t := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(tag), "_", "-"))
	parts := strings.Split(t, "-")
	switch parts[0] {
	case "en":
		return EN, true
	case "fr":
		return FR, true
	case "ja":
		return JA, true
	case "ru":
		return RU, true
	case "zh":
		for _, p := range parts[1:] {
			switch p {
			case "hant":
				return ZhHant, true
			case "hans":
				return ZhHans, true
			}
		}
		for _, p := range parts[1:] {
			switch p {
			case "tw", "hk", "mo":
				return ZhHant, true
			}
		}
		return ZhHans, true
	}
	return "", false
}

// Negotiate picks the supported language a browser prefers from its
// Accept-Language header, honouring q-values. ok is false when none fits.
func Negotiate(header string) (string, bool) {
	if len(header) > 1024 {
		header = header[:1024]
	}
	type choice struct {
		lang string
		q    float64
	}
	var cs []choice
	for i, item := range strings.Split(header, ",") {
		if i >= 32 {
			break
		}
		tag, params, _ := strings.Cut(item, ";")
		q := 1.0
		for _, p := range strings.Split(params, ";") {
			if v, ok := strings.CutPrefix(strings.TrimSpace(p), "q="); ok {
				f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
				if err != nil {
					f = 0
				}
				q = f
			}
		}
		if q <= 0 {
			continue
		}
		if l, ok := Parse(tag); ok {
			cs = append(cs, choice{l, q})
		}
	}
	if len(cs) == 0 {
		return "", false
	}
	sort.SliceStable(cs, func(i, j int) bool { return cs[i].q > cs[j].q })
	return cs[0].lang, true
}

// message returns the raw message, falling back to English, then to a
// visible marker so a missing id stands out.
func message(lang, key string) string {
	if m, ok := catalogs[lang][key]; ok {
		return m
	}
	if m, ok := en[key]; ok {
		return m
	}
	return "[[" + key + "]]"
}

// Has reports whether every language has the message (for tests).
func Has(lang, key string) bool {
	_, ok := catalogs[lang][key]
	return ok
}

// T returns the message with its placeholders filled from args, which are
// name/value pairs: T(lang, "download.version", "version", "1.2.0").
func T(lang, key string, args ...any) string {
	return expand(message(lang, key), args, identity, sprint)
}

// N returns the plural form of the message for count n; {n} is filled in
// automatically.
func N(lang, key string, n int, args ...any) string {
	return expand(pluralForm(lang, message(lang, key), n), append(args, "n", n), identity, sprint)
}

// HTML returns the message as HTML: its text is escaped, and template.HTML
// arguments (links, code elements) are inserted as they are.
func HTML(lang, key string, args ...any) template.HTML {
	return template.HTML(expand(message(lang, key), args, html.EscapeString, func(v any) string {
		if h, ok := v.(template.HTML); ok {
			return string(h)
		}
		return html.EscapeString(fmt.Sprint(v))
	}))
}

func pluralForm(lang, msg string, n int) string {
	forms := strings.Split(msg, "|")
	l, ok := Get(lang)
	if !ok {
		l = Languages[0]
	}
	i := l.plural(n)
	if i >= len(forms) {
		i = len(forms) - 1
	}
	return forms[i]
}

// Number writes a decimal amount ("39.99") the way the language does.
func Number(lang, s string) string {
	if l, ok := Get(lang); ok && l.decimalComma {
		return strings.Replace(s, ".", ",", 1)
	}
	return s
}

// JS returns the strings of the website's scripts ("js." ids, without the
// prefix).
func JS(lang string) map[string]string {
	out := map[string]string{}
	for k := range en {
		if name, ok := strings.CutPrefix(k, "js."); ok {
			out[name] = message(lang, k)
		}
	}
	return out
}

func identity(s string) string { return s }

func sprint(v any) string { return fmt.Sprint(v) }

// Placeholders lists the {name} placeholders in a message (for tests).
func Placeholders(msg string) []string {
	var out []string
	for i := 0; i < len(msg); i++ {
		if msg[i] != '{' {
			continue
		}
		if j := placeholderEnd(msg, i); j > 0 {
			out = append(out, msg[i+1:j])
			i = j
		}
	}
	return out
}

// placeholderEnd returns the index of the "}" closing a placeholder that
// starts at i, or -1.
func placeholderEnd(msg string, i int) int {
	for j := i + 1; j < len(msg); j++ {
		c := msg[j]
		switch {
		case c == '}':
			if j > i+1 {
				return j
			}
			return -1
		case c >= 'a' && c <= 'z', c == '_':
		default:
			return -1
		}
	}
	return -1
}

func expand(msg string, args []any, text func(string) string, val func(any) string) string {
	var b strings.Builder
	start := 0
	for i := 0; i < len(msg); i++ {
		if msg[i] != '{' {
			continue
		}
		j := placeholderEnd(msg, i)
		if j < 0 {
			continue
		}
		name := msg[i+1 : j]
		for k := 0; k+1 < len(args); k += 2 {
			if args[k] == name {
				b.WriteString(text(msg[start:i]))
				b.WriteString(val(args[k+1]))
				start = j + 1
				break
			}
		}
		i = j
	}
	b.WriteString(text(msg[start:]))
	return b.String()
}
