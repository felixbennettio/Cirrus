// Package store keeps licences, activations, orders and the audit log in
// SQLite (modernc.org/sqlite, pure Go, WAL mode).
package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite" // database/sql driver "sqlite"
)

// Errors returned by store operations. The HTTP layer maps them to the API
// error codes in docs/licensing.md.
var (
	ErrNotFound      = errors.New("not found")
	ErrRevoked       = errors.New("licence revoked")
	ErrWrongPlatform = errors.New("licence is for another platform")
	ErrEmailMismatch = errors.New("email does not match the licence")
	ErrConflict      = errors.New("already exists")
	ErrNotPending    = errors.New("order is already paid")
)

// LimitError is returned by Activate when every device slot is in use.
type LimitError struct{ Devices []Activation }

func (e *LimitError) Error() string {
	return fmt.Sprintf("activation limit reached (%d devices)", len(e.Devices))
}

// TooSoonError is returned by SelfReset during the cooldown.
type TooSoonError struct{ Wait time.Duration }

func (e *TooSoonError) Error() string { return "reset too soon, wait " + e.Wait.String() }

// Store wraps the database handle.
type Store struct {
	db *sql.DB
}

// Open opens (creating if needed) the database at path and migrates it.
func Open(path string) (*Store, error) {
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)" +
		"&_pragma=foreign_keys(1)&_pragma=cache_size(-2000)&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// Writes are serialised by SQLite (BEGIN IMMEDIATE + busy timeout);
	// WAL lets readers proceed meanwhile. A few connections are plenty.
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	db.SetConnMaxIdleTime(5 * time.Minute)
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

// Backup writes a consistent copy of the database to path, which must not
// exist yet. It is safe while the server is running.
func (s *Store) Backup(ctx context.Context, path string) error {
	_, err := s.db.ExecContext(ctx, "VACUUM INTO ?", path)
	return err
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// Ping checks the database is reachable.
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

var migrations = []string{
	`
CREATE TABLE licenses (
	id            TEXT PRIMARY KEY,
	license_key   TEXT NOT NULL UNIQUE,
	product       TEXT NOT NULL,
	platform      TEXT NOT NULL,
	max_devices   INTEGER NOT NULL,
	email         TEXT NOT NULL DEFAULT '',
	order_no      TEXT NOT NULL DEFAULT '',
	note          TEXT NOT NULL DEFAULT '',
	revoked       INTEGER NOT NULL DEFAULT 0,
	created_at    INTEGER NOT NULL,
	revoked_at    INTEGER NOT NULL DEFAULT 0,
	last_reset_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX licenses_email ON licenses(email);
CREATE INDEX licenses_created ON licenses(created_at);

CREATE TABLE activations (
	license_id   TEXT NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
	device_id    TEXT NOT NULL,
	device_name  TEXT NOT NULL DEFAULT '',
	platform     TEXT NOT NULL DEFAULT '',
	app_version  TEXT NOT NULL DEFAULT '',
	activated_at INTEGER NOT NULL,
	last_seen_at INTEGER NOT NULL,
	PRIMARY KEY (license_id, device_id)
) WITHOUT ROWID;

CREATE TABLE orders (
	order_no   TEXT PRIMARY KEY,
	token_hash TEXT NOT NULL,
	product    TEXT NOT NULL,
	email      TEXT NOT NULL,
	method     TEXT NOT NULL,
	provider   TEXT NOT NULL,
	amount     INTEGER NOT NULL,
	currency   TEXT NOT NULL DEFAULT 'CNY',
	status     TEXT NOT NULL DEFAULT 'pending',
	pay_data   TEXT NOT NULL DEFAULT '',
	pay_ref    TEXT NOT NULL DEFAULT '',
	license_id TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	expires_at INTEGER NOT NULL,
	paid_at    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX orders_status ON orders(status, created_at);
CREATE INDEX orders_email ON orders(email);

CREATE TABLE events (
	id         INTEGER PRIMARY KEY,
	at         INTEGER NOT NULL,
	kind       TEXT NOT NULL,
	license_id TEXT NOT NULL DEFAULT '',
	order_no   TEXT NOT NULL DEFAULT '',
	ip         TEXT NOT NULL DEFAULT '',
	detail     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX events_license ON events(license_id, at);
CREATE INDEX events_order ON events(order_no, at);
CREATE INDEX events_at ON events(at);
`,
}

func (s *Store) migrate(ctx context.Context) error {
	var v int
	if err := s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&v); err != nil {
		return err
	}
	for i := v; i < len(migrations); i++ {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, migrations[i]); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d: %w", i+1, err)
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", i+1)); err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand does not fail on supported platforms
	}
	return hex.EncodeToString(b)
}

func isUnique(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

func unix(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

func fromUnix(v int64) time.Time {
	if v == 0 {
		return time.Time{}
	}
	return time.Unix(v, 0)
}

// NormEmail is how emails are stored and compared: trimmed and lower-cased.
func NormEmail(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

type querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// Stats is a summary for the admin dashboard.
type Stats struct {
	PendingOrders int
	PaidOrders    int
	RevenueCents  int64
	Licenses      int
	Activations   int
}

// Stats counts orders, revenue, licences and activations.
func (s *Store) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	err := s.db.QueryRowContext(ctx, `SELECT
		(SELECT COUNT(*) FROM orders WHERE status = 'pending'),
		(SELECT COUNT(*) FROM orders WHERE status = 'paid'),
		(SELECT COALESCE(SUM(amount), 0) FROM orders WHERE status = 'paid'),
		(SELECT COUNT(*) FROM licenses),
		(SELECT COUNT(*) FROM activations)`).Scan(&st.PendingOrders, &st.PaidOrders, &st.RevenueCents, &st.Licenses, &st.Activations)
	return st, err
}
