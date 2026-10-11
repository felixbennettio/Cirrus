package app

import (
	"encoding/json"
	"fmt"

	"cirrus/server/internal/i18n"
)

// The screenshot gallery on the home page. static/shots/<lang>/<id>.webp
// (with an <id>-t.webp thumbnail) is a screen of the app in that language;
// static/shots/index.json lists their sizes ("<lang>/<id>": [w, h, tw, th]);
// scripts/gallery_images.py makes them from screenshots. A language
// without its own picture of a screen uses the next one in shotLangs;
// screens nobody has are left out.

type shotGroup struct {
	ID    string   // title: i18n "shots.g.<id>"
	Shots []string // captions: i18n "shots.<id>"
}

var shotGroups = []shotGroup{
	{"overview", []string{"home", "home-dark", "domains", "zone", "analytics", "phone"}},
	{"zone", []string{"dns", "dns-dark", "ssl", "security", "rules", "cache", "zone-settings", "email", "zone-more"}},
	{"compute", []string{"workers", "worker", "worker-bindings", "pages", "pages-project", "ai"}},
	{"storage", []string{"kv", "kv-keys", "r2", "r2-bucket", "d1", "d1-db"}},
	{"zerotrust", []string{"tunnels", "tunnel", "zt-networks", "access", "gateway", "devices"}},
	{"account", []string{"members", "tokens", "tokens-dark", "audit", "lists", "account-more"}},
	{"developer", []string{"console", "console-dark", "graphql", "requests", "palette", "palette-dark"}},
	{"mobile", []string{"m-home", "m-home-dark", "m-dns", "m-zone", "m-drawer", "m-drawer-dark"}},
	{"iphone", []string{"i-home", "i-zone", "i-ai"}},
	{"setup", []string{"welcome", "profile", "settings"}},
}

// shotLangs is where a language looks for a screen's picture. Visitors
// never see the app in Chinese unless they read Chinese.
func shotLangs(lang string) []string {
	switch lang {
	case i18n.ZhHans:
		return []string{i18n.ZhHans, i18n.ZhHant, i18n.EN}
	case i18n.ZhHant:
		return []string{i18n.ZhHant, i18n.ZhHans, i18n.EN}
	case i18n.EN:
		return []string{i18n.EN}
	}
	return []string{lang, i18n.EN}
}

// shotSizes are the pictures there are, from static/shots/index.json.
var shotSizes = func() map[string][4]int {
	m := map[string][4]int{}
	b, err := staticFS.ReadFile("static/shots/index.json")
	if err != nil {
		return m
	}
	if err := json.Unmarshal(b, &m); err != nil {
		panic(fmt.Sprintf("static/shots/index.json: %v", err))
	}
	return m
}()

type shotView struct {
	ID, Caption string
	Lang        string // the language the picture shows
	Full, Thumb string // asset URLs
	W, H        int    // full size
	TW, TH      int    // thumbnail size
	Phone       bool   // a portrait phone screen
}

type shotGroupView struct {
	ID, Title string
	Shots     []shotView
	Phones    bool // every shot is a phone screen
}

// shot finds the picture of a screen for a language.
func (a *App) shot(lang, id string) (shotView, bool) {
	for _, l := range shotLangs(lang) {
		sz, ok := shotSizes[l+"/"+id]
		if !ok {
			continue
		}
		return shotView{
			ID: id, Caption: i18n.T(lang, "shots."+id), Lang: l,
			Full: a.asset("shots/" + l + "/" + id + ".webp"), Thumb: a.asset("shots/" + l + "/" + id + "-t.webp"),
			W: sz[0], H: sz[1], TW: sz[2], TH: sz[3], Phone: sz[1] > sz[0],
		}, true
	}
	return shotView{}, false
}

// gallery is the home page's screenshot gallery in a language.
func (a *App) gallery(lang string) []shotGroupView {
	var out []shotGroupView
	for _, g := range shotGroups {
		v := shotGroupView{ID: g.ID, Title: i18n.T(lang, "shots.g."+g.ID)}
		for _, id := range g.Shots {
			if s, ok := a.shot(lang, id); ok {
				v.Shots = append(v.Shots, s)
			}
		}
		if len(v.Shots) > 0 {
			v.Phones = true
			for _, s := range v.Shots {
				v.Phones = v.Phones && s.Phone
			}
			out = append(out, v)
		}
	}
	return out
}

// heroShots are the large picture under the home page's title: the
// desktop app, and the phone app on narrow screens, each in light and (when
// there is one in the same language) dark mode.
type heroShots struct {
	Light, Dark           shotView // Dark.Full is "" when there is none
	PhoneLight, PhoneDark shotView // PhoneLight.Full is "" when there is none
}

func (a *App) hero(lang string) *heroShots {
	light, ok := a.shot(lang, "home")
	if !ok {
		return nil
	}
	h := &heroShots{Light: light}
	if dark, ok := a.shot(lang, "home-dark"); ok && dark.Lang == light.Lang {
		h.Dark = dark
	}
	if phone, ok := a.shot(lang, "m-home"); ok {
		h.PhoneLight = phone
		if dark, ok := a.shot(lang, "m-home-dark"); ok && dark.Lang == phone.Lang {
			h.PhoneDark = dark
		}
	}
	return h
}
