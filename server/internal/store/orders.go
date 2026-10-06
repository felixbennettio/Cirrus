package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Order statuses.
const (
	StatusPending   = "pending"
	StatusPaid      = "paid"
	StatusExpired   = "expired"
	StatusCancelled = "cancelled"
)

// Order is a purchase attempt.
type Order struct {
	No          string
	TokenHash   string
	Product     string
	Email       string
	Method      string // alipay | wechat
	Provider    string // manual | alipay_f2f
	AmountCents int64
	Currency    string
	Status      string
	PayData     string // provider data: the QR text for alipay_f2f
	PayRef      string
	LicenseID   string
	CreatedAt   time.Time
	ExpiresAt   time.Time
	PaidAt      time.Time

	LicenseKey string // joined from licenses when paid
}

// EffectiveStatus treats a pending order past its expiry as expired, even
// before the sweeper has updated the row.
func (o Order) EffectiveStatus(now time.Time) string {
	if o.Status == StatusPending && !now.Before(o.ExpiresAt) {
		return StatusExpired
	}
	return o.Status
}

const orderCols = `o.order_no, o.token_hash, o.product, o.email, o.method, o.provider, o.amount, o.currency, o.status,
	o.pay_data, o.pay_ref, o.license_id, o.created_at, o.expires_at, o.paid_at, COALESCE(l.license_key, '')`

const orderFrom = ` FROM orders o LEFT JOIN licenses l ON l.id = o.license_id `

func scanOrder(r scanner) (Order, error) {
	var o Order
	var created, expires, paid int64
	err := r.Scan(&o.No, &o.TokenHash, &o.Product, &o.Email, &o.Method, &o.Provider, &o.AmountCents, &o.Currency, &o.Status,
		&o.PayData, &o.PayRef, &o.LicenseID, &created, &expires, &paid, &o.LicenseKey)
	if errors.Is(err, sql.ErrNoRows) {
		return o, ErrNotFound
	}
	o.CreatedAt, o.ExpiresAt, o.PaidAt = fromUnix(created), fromUnix(expires), fromUnix(paid)
	return o, err
}

// InsertOrder stores a new order. ErrConflict means the order number is taken.
func (s *Store) InsertOrder(ctx context.Context, o Order) error {
	if o.Currency == "" {
		o.Currency = "CNY"
	}
	if o.Status == "" {
		o.Status = StatusPending
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO orders
		(order_no, token_hash, product, email, method, provider, amount, currency, status, pay_data, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		o.No, o.TokenHash, o.Product, NormEmail(o.Email), o.Method, o.Provider, o.AmountCents, o.Currency, o.Status,
		o.PayData, unix(o.CreatedAt), unix(o.ExpiresAt))
	if isUnique(err) {
		return ErrConflict
	}
	return err
}

// Order looks an order up by number.
func (s *Store) Order(ctx context.Context, no string) (Order, error) {
	return scanOrder(s.db.QueryRowContext(ctx, "SELECT "+orderCols+orderFrom+"WHERE o.order_no = ?", no))
}

// ListOrders lists orders, pending first, then newest first. status filters
// when not empty.
func (s *Store) ListOrders(ctx context.Context, status string, limit int) ([]Order, error) {
	q := "SELECT " + orderCols + orderFrom
	args := []any{}
	if status != "" {
		q += "WHERE o.status = ? "
		args = append(args, status)
	}
	q += "ORDER BY (o.status = 'pending') DESC, o.created_at DESC LIMIT ?"
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Order
	for rows.Next() {
		o, err := scanOrder(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// ProductInfo resolves a product id to its platform and device limit.
type ProductInfo func(product string) (platform string, maxDevices int, ok bool)

// PayOrder marks an order paid and issues its licence, in one transaction.
// Paying an order that is already paid returns its licence with issued ==
// false, so payment notifications are idempotent. Expired and cancelled
// orders can still be paid: the money has been received.
func (s *Store) PayOrder(ctx context.Context, no, payRef string, now time.Time, products ProductInfo) (o Order, l License, issued bool, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return o, l, false, err
	}
	defer tx.Rollback()

	o, err = scanOrder(tx.QueryRowContext(ctx, "SELECT "+orderCols+orderFrom+"WHERE o.order_no = ?", no))
	if err != nil {
		return o, l, false, err
	}
	if o.Status == StatusPaid {
		l, err = licenseBy(ctx, tx, "id", o.LicenseID)
		return o, l, false, err
	}
	platform, maxDevices, ok := products(o.Product)
	if !ok {
		return o, l, false, fmt.Errorf("order %s: unknown product %q", no, o.Product)
	}
	l, err = createLicense(ctx, tx, NewLicense{
		Product: o.Product, Platform: platform, MaxDevices: maxDevices, Email: o.Email, OrderNo: o.No,
	}, now)
	if err != nil {
		return o, l, false, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE orders SET status = 'paid', paid_at = ?, pay_ref = ?, license_id = ?
		WHERE order_no = ?`, now.Unix(), payRef, l.ID, no); err != nil {
		return o, l, false, err
	}
	if err = tx.Commit(); err != nil {
		return o, l, false, err
	}
	o.Status, o.PaidAt, o.PayRef, o.LicenseID, o.LicenseKey = StatusPaid, now, payRef, l.ID, l.Key
	return o, l, true, nil
}

// CancelOrder cancels an unpaid order.
func (s *Store) CancelOrder(ctx context.Context, no string) error {
	res, err := s.db.ExecContext(ctx, "UPDATE orders SET status = 'cancelled' WHERE order_no = ? AND status IN ('pending', 'expired')", no)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if _, err := s.Order(ctx, no); err != nil {
			return err
		}
		return ErrNotPending
	}
	return nil
}

// ExpireOrders marks pending orders past their expiry as expired.
func (s *Store) ExpireOrders(ctx context.Context, now time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, "UPDATE orders SET status = 'expired' WHERE status = 'pending' AND expires_at <= ?", now.Unix())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// PurgeUnpaidOrders deletes expired and cancelled orders created before the
// cutoff; they hold an email address and nothing else of value.
func (s *Store) PurgeUnpaidOrders(ctx context.Context, before time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, "DELETE FROM orders WHERE status IN ('expired', 'cancelled') AND created_at < ?", before.Unix())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
