package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"cirrus/server/internal/license"
)

// License is one issued licence key.
type License struct {
	ID          string
	Key         string
	Product     string
	Platform    string
	MaxDevices  int
	Email       string
	OrderNo     string
	Note        string
	Revoked     bool
	CreatedAt   time.Time
	RevokedAt   time.Time
	LastResetAt time.Time
	DevicesUsed int
}

// Activation is one device using a licence.
type Activation struct {
	LicenseID   string
	DeviceID    string
	DeviceName  string
	Platform    string
	AppVersion  string
	ActivatedAt time.Time
	LastSeenAt  time.Time
}

// NewLicense describes a licence to issue.
type NewLicense struct {
	Product    string
	Platform   string
	MaxDevices int
	Email      string
	OrderNo    string
	Note       string
}

const licCols = `id, license_key, product, platform, max_devices, email, order_no, note, revoked,
	created_at, revoked_at, last_reset_at,
	(SELECT COUNT(*) FROM activations a WHERE a.license_id = licenses.id)`

type scanner interface{ Scan(dest ...any) error }

func scanLicense(r scanner) (License, error) {
	var l License
	var revoked int
	var created, revokedAt, reset int64
	err := r.Scan(&l.ID, &l.Key, &l.Product, &l.Platform, &l.MaxDevices, &l.Email, &l.OrderNo, &l.Note,
		&revoked, &created, &revokedAt, &reset, &l.DevicesUsed)
	if errors.Is(err, sql.ErrNoRows) {
		return l, ErrNotFound
	}
	l.Revoked = revoked != 0
	l.CreatedAt, l.RevokedAt, l.LastResetAt = fromUnix(created), fromUnix(revokedAt), fromUnix(reset)
	return l, err
}

func scanLicenses(rows *sql.Rows, err error) ([]License, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []License
	for rows.Next() {
		l, err := scanLicense(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// CreateLicense issues a new licence with a fresh random key.
func (s *Store) CreateLicense(ctx context.Context, in NewLicense, now time.Time) (License, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return License{}, err
	}
	defer tx.Rollback()
	l, err := createLicense(ctx, tx, in, now)
	if err != nil {
		return License{}, err
	}
	return l, tx.Commit()
}

func createLicense(ctx context.Context, q querier, in NewLicense, now time.Time) (License, error) {
	for attempt := 0; ; attempt++ {
		key, err := license.NewKey()
		if err != nil {
			return License{}, err
		}
		id := "lic_" + randHex(8)
		_, err = q.ExecContext(ctx, `INSERT INTO licenses
			(id, license_key, product, platform, max_devices, email, order_no, note, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			id, key, in.Product, in.Platform, in.MaxDevices, NormEmail(in.Email), in.OrderNo, in.Note, now.Unix())
		if isUnique(err) && attempt < 5 {
			continue // 100-bit keys: practically never happens
		}
		if err != nil {
			return License{}, err
		}
		return licenseBy(ctx, q, "id", id)
	}
}

func licenseBy(ctx context.Context, q querier, col, v string) (License, error) {
	// col is always a constant from this package.
	return scanLicense(q.QueryRowContext(ctx, "SELECT "+licCols+" FROM licenses WHERE "+col+" = ?", v))
}

// LicenseByKey looks a licence up by its canonical key.
func (s *Store) LicenseByKey(ctx context.Context, key string) (License, error) {
	return licenseBy(ctx, s.db, "license_key", key)
}

// LicenseByID looks a licence up by id.
func (s *Store) LicenseByID(ctx context.Context, id string) (License, error) {
	return licenseBy(ctx, s.db, "id", id)
}

// LicensesByEmail lists the licences bought with an email address.
func (s *Store) LicensesByEmail(ctx context.Context, email string) ([]License, error) {
	return scanLicenses(s.db.QueryContext(ctx,
		"SELECT "+licCols+" FROM licenses WHERE email = ? ORDER BY created_at", NormEmail(email)))
}

// SearchLicenses finds licences by key (full or partial), email, id or order
// number. An empty query lists the newest.
func (s *Store) SearchLicenses(ctx context.Context, q string, limit int) ([]License, error) {
	q = strings.TrimSpace(q)
	if q == "" {
		return scanLicenses(s.db.QueryContext(ctx,
			"SELECT "+licCols+" FROM licenses ORDER BY created_at DESC LIMIT ?", limit))
	}
	if k, err := license.NormalizeKey(q); err == nil {
		q = k
	}
	// SQLite's LIKE is case-insensitive for ASCII.
	like := "%" + strings.NewReplacer(`\`, `\\`, "%", `\%`, "_", `\_`).Replace(q) + "%"
	return scanLicenses(s.db.QueryContext(ctx, "SELECT "+licCols+` FROM licenses
		WHERE license_key LIKE ?1 ESCAPE '\' OR email LIKE ?1 ESCAPE '\' OR id = ?2 OR order_no = ?2
		ORDER BY created_at DESC LIMIT ?3`, like, q, limit))
}

// ActivateInput is what the app reports when activating.
type ActivateInput struct {
	DeviceID   string
	DeviceName string
	Platform   string
	AppVersion string
}

// Activate binds a device to the licence with the given canonical key.
// Re-activating a device that already holds a slot refreshes it without
// using another slot. The returned licence has DevicesUsed set.
func (s *Store) Activate(ctx context.Context, key string, in ActivateInput, now time.Time) (License, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return License{}, err
	}
	defer tx.Rollback()

	l, err := licenseBy(ctx, tx, "license_key", key)
	if err != nil {
		return l, err
	}
	if l.Revoked {
		return l, ErrRevoked
	}
	if l.Platform != in.Platform {
		return l, ErrWrongPlatform
	}
	res, err := tx.ExecContext(ctx, `UPDATE activations SET device_name = ?, platform = ?, app_version = ?, last_seen_at = ?
		WHERE license_id = ? AND device_id = ?`, in.DeviceName, in.Platform, in.AppVersion, now.Unix(), l.ID, in.DeviceID)
	if err != nil {
		return l, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if l.DevicesUsed >= l.MaxDevices {
			devs, err := activations(ctx, tx, l.ID)
			if err != nil {
				return l, err
			}
			return l, &LimitError{Devices: devs}
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO activations
			(license_id, device_id, device_name, platform, app_version, activated_at, last_seen_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`, l.ID, in.DeviceID, in.DeviceName, in.Platform, in.AppVersion, now.Unix(), now.Unix()); err != nil {
			return l, err
		}
		l.DevicesUsed++
	}
	return l, tx.Commit()
}

// Deactivate frees the device's slot. It succeeds when the device was not
// activated; removed says whether a slot was freed.
func (s *Store) Deactivate(ctx context.Context, key, deviceID string) (l License, removed bool, err error) {
	l, err = s.LicenseByKey(ctx, key)
	if err != nil {
		return l, false, err
	}
	res, err := s.db.ExecContext(ctx, "DELETE FROM activations WHERE license_id = ? AND device_id = ?", l.ID, deviceID)
	if err != nil {
		return l, false, err
	}
	n, _ := res.RowsAffected()
	return l, n > 0, nil
}

// Validate reports "active", "not_activated" or "revoked" for the device.
func (s *Store) Validate(ctx context.Context, key, deviceID string, now time.Time) (License, string, error) {
	l, err := s.LicenseByKey(ctx, key)
	if err != nil {
		return l, "", err
	}
	if l.Revoked {
		return l, "revoked", nil
	}
	res, err := s.db.ExecContext(ctx, "UPDATE activations SET last_seen_at = ? WHERE license_id = ? AND device_id = ?",
		now.Unix(), l.ID, deviceID)
	if err != nil {
		return l, "", err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return l, "not_activated", nil
	}
	return l, "active", nil
}

// SelfReset releases every device of the licence when email matches, at most
// once per cooldown. A reset that frees nothing does not start the cooldown.
func (s *Store) SelfReset(ctx context.Context, key, email string, now time.Time, cooldown time.Duration) (License, int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return License{}, 0, err
	}
	defer tx.Rollback()
	l, err := licenseBy(ctx, tx, "license_key", key)
	if err != nil {
		return l, 0, err
	}
	if l.Email == "" || l.Email != NormEmail(email) {
		return l, 0, ErrEmailMismatch
	}
	if l.Revoked {
		return l, 0, ErrRevoked
	}
	if !l.LastResetAt.IsZero() {
		if next := l.LastResetAt.Add(cooldown); now.Before(next) {
			return l, 0, &TooSoonError{Wait: next.Sub(now)}
		}
	}
	if l.DevicesUsed == 0 {
		return l, 0, nil
	}
	res, err := tx.ExecContext(ctx, "DELETE FROM activations WHERE license_id = ?", l.ID)
	if err != nil {
		return l, 0, err
	}
	n, _ := res.RowsAffected()
	if _, err := tx.ExecContext(ctx, "UPDATE licenses SET last_reset_at = ? WHERE id = ?", now.Unix(), l.ID); err != nil {
		return l, 0, err
	}
	return l, int(n), tx.Commit()
}

// AdminReset releases every device without touching the self-service
// cooldown.
func (s *Store) AdminReset(ctx context.Context, id string) (int, error) {
	res, err := s.db.ExecContext(ctx, "DELETE FROM activations WHERE license_id = ?", id)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// RemoveDevice releases one device.
func (s *Store) RemoveDevice(ctx context.Context, id, deviceID string) error {
	res, err := s.db.ExecContext(ctx, "DELETE FROM activations WHERE license_id = ? AND device_id = ?", id, deviceID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetRevoked revokes or reinstates a licence.
func (s *Store) SetRevoked(ctx context.Context, id string, revoked bool, now time.Time) error {
	at, flag := int64(0), 0
	if revoked {
		at, flag = now.Unix(), 1
	}
	res, err := s.db.ExecContext(ctx, "UPDATE licenses SET revoked = ?, revoked_at = ? WHERE id = ?", flag, at, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// UpdateNote replaces the admin note on a licence.
func (s *Store) UpdateNote(ctx context.Context, id, note string) error {
	_, err := s.db.ExecContext(ctx, "UPDATE licenses SET note = ? WHERE id = ?", note, id)
	return err
}

// Activations lists the devices of a licence, oldest first.
func (s *Store) Activations(ctx context.Context, id string) ([]Activation, error) {
	return activations(ctx, s.db, id)
}

func activations(ctx context.Context, q querier, id string) ([]Activation, error) {
	rows, err := q.QueryContext(ctx, `SELECT license_id, device_id, device_name, platform, app_version, activated_at, last_seen_at
		FROM activations WHERE license_id = ? ORDER BY activated_at, device_id`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Activation
	for rows.Next() {
		var a Activation
		var at, seen int64
		if err := rows.Scan(&a.LicenseID, &a.DeviceID, &a.DeviceName, &a.Platform, &a.AppVersion, &at, &seen); err != nil {
			return nil, err
		}
		a.ActivatedAt, a.LastSeenAt = fromUnix(at), fromUnix(seen)
		out = append(out, a)
	}
	return out, rows.Err()
}
