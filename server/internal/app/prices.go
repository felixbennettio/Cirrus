package app

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"cirrus/server/internal/config"
	"cirrus/server/internal/money"
	"cirrus/server/internal/store"
)

// Prices: PRICE_CNY / PRICE_USD (and the per-product overrides) in .env are
// the defaults; a price saved on the admin Prices page replaces them for
// that product until it is reset. Orders keep the amount they were created
// with.

// maxPriceCents caps admin input at CNY 100,000.
const maxPriceCents = 100_000_00

func (a *App) reloadPrices(ctx context.Context) error {
	m, err := a.st.Prices(ctx)
	if err != nil {
		return err
	}
	a.priceMu.Lock()
	a.prices = m
	a.priceMu.Unlock()
	return nil
}

// priced applies the admin price, if any, to a configured product.
func (a *App) priced(p config.Product) config.Product {
	a.priceMu.RLock()
	o, ok := a.prices[p.ID]
	a.priceMu.RUnlock()
	if ok {
		p.PriceCents = o.CNYCents
		if o.USD != "" {
			p.PriceUSD = o.USD
		}
	}
	return p
}

// product is a known product (on sale or not) with its current price.
func (a *App) product(id string) (config.Product, bool) {
	p, ok := a.cfg.Product(id)
	if !ok {
		return p, false
	}
	return a.priced(p), true
}

// onSale is a product on sale with its current price.
func (a *App) onSale(id string) (config.Product, bool) {
	p, ok := a.cfg.OnSale(id)
	if !ok {
		return p, false
	}
	return a.priced(p), true
}

// products lists the products on sale with their current prices.
func (a *App) products() []config.Product {
	ps := make([]config.Product, len(a.cfg.Products))
	for i, p := range a.cfg.Products {
		ps[i] = a.priced(p)
	}
	return ps
}

type priceRow struct {
	ID, Name   string
	CNY, USD   string // current, e.g. "260" and "39.99"
	DefaultCNY string // from .env
	DefaultUSD string
	Custom     bool // set on this page
	UpdatedAt  time.Time
}

func (a *App) adminPrices(w http.ResponseWriter, r *http.Request) {
	a.priceMu.RLock()
	saved := a.prices
	a.priceMu.RUnlock()
	var rows []priceRow
	for _, def := range a.cfg.Products {
		cur := a.priced(def)
		o, custom := saved[def.ID]
		rows = append(rows, priceRow{
			ID: def.ID, Name: def.NameZH,
			CNY: money.Short(cur.PriceCents), USD: cur.PriceUSD,
			DefaultCNY: money.Short(def.PriceCents), DefaultUSD: def.PriceUSD,
			Custom: custom, UpdatedAt: o.UpdatedAt,
		})
	}
	a.adminPage(w, r, "admin_prices", rows)
}

func (a *App) adminSetPrice(w http.ResponseWriter, r *http.Request) {
	p, ok := a.cfg.Product(r.PathValue("product"))
	if !ok {
		a.notFound(w, r)
		return
	}
	ctx := r.Context()
	msg := "price_saved"
	if r.PostFormValue("action") == "reset" {
		msg = "price_reset"
		if err := a.st.ClearPrice(ctx, p.ID); err != nil {
			a.internalError(w, r, err)
			return
		}
		a.event(ctx, "price_reset", "", "", ipFrom(r), p.ID)
	} else {
		cny, err := money.Parse(strings.TrimSpace(r.PostFormValue("cny")))
		if err != nil || cny <= 0 || cny > maxPriceCents {
			seeOther(w, r, "/admin/prices", "bad_price")
			return
		}
		usd := strings.TrimSpace(r.PostFormValue("usd"))
		if usd != "" {
			c, err := money.Parse(usd)
			if err != nil || c <= 0 || c > maxPriceCents {
				seeOther(w, r, "/admin/prices", "bad_price")
				return
			}
			usd = money.Short(c)
		}
		if err := a.st.SetPrice(ctx, store.Price{Product: p.ID, CNYCents: cny, USD: usd}, a.now()); err != nil {
			a.internalError(w, r, err)
			return
		}
		a.event(ctx, "price_set", "", "", ipFrom(r), fmt.Sprintf("%s CNY %s USD %s", p.ID, money.Format(cny), usd))
	}
	if err := a.reloadPrices(ctx); err != nil {
		a.internalError(w, r, err)
		return
	}
	seeOther(w, r, "/admin/prices", msg)
}
