package store

import (
	"context"
	"time"
)

// Price is a product price set in the admin pages. It overrides the
// PRICE_CNY / PRICE_USD settings for that product.
type Price struct {
	Product   string
	CNYCents  int64
	USD       string // display only, e.g. "39.99"
	UpdatedAt time.Time
}

// Prices returns every price set in the admin pages, by product id.
func (s *Store) Prices(ctx context.Context) (map[string]Price, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT product, cny, usd, updated_at FROM prices")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := map[string]Price{}
	for rows.Next() {
		var p Price
		var at int64
		if err := rows.Scan(&p.Product, &p.CNYCents, &p.USD, &at); err != nil {
			return nil, err
		}
		p.UpdatedAt = fromUnix(at)
		m[p.Product] = p
	}
	return m, rows.Err()
}

// SetPrice stores the price of a product.
func (s *Store) SetPrice(ctx context.Context, p Price, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO prices (product, cny, usd, updated_at) VALUES (?, ?, ?, ?)
		ON CONFLICT (product) DO UPDATE SET cny = excluded.cny, usd = excluded.usd, updated_at = excluded.updated_at`,
		p.Product, p.CNYCents, p.USD, unix(now))
	return err
}

// ClearPrice removes the admin price of a product, so the PRICE_* settings
// apply again.
func (s *Store) ClearPrice(ctx context.Context, product string) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM prices WHERE product = ?", product)
	return err
}
