package store

import (
	"context"
	"time"
)

// Event is one audit log entry.
type Event struct {
	ID        int64
	At        time.Time
	Kind      string
	LicenseID string
	OrderNo   string
	IP        string
	Detail    string
}

// Log appends an audit event.
func (s *Store) Log(ctx context.Context, e Event) error {
	if e.At.IsZero() {
		e.At = time.Now()
	}
	_, err := s.db.ExecContext(ctx, "INSERT INTO events (at, kind, license_id, order_no, ip, detail) VALUES (?, ?, ?, ?, ?, ?)",
		e.At.Unix(), e.Kind, e.LicenseID, e.OrderNo, e.IP, e.Detail)
	return err
}

// Events lists events, newest first, for a licence and/or order (both empty:
// all events).
func (s *Store) Events(ctx context.Context, licenseID, orderNo string, limit int) ([]Event, error) {
	q := "SELECT id, at, kind, license_id, order_no, ip, detail FROM events"
	var args []any
	switch {
	case licenseID != "" && orderNo != "":
		q += " WHERE license_id = ? OR order_no = ?"
		args = append(args, licenseID, orderNo)
	case licenseID != "":
		q += " WHERE license_id = ?"
		args = append(args, licenseID)
	case orderNo != "":
		q += " WHERE order_no = ?"
		args = append(args, orderNo)
	}
	q += " ORDER BY at DESC, id DESC LIMIT ?"
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Event
	for rows.Next() {
		var e Event
		var at int64
		if err := rows.Scan(&e.ID, &at, &e.Kind, &e.LicenseID, &e.OrderNo, &e.IP, &e.Detail); err != nil {
			return nil, err
		}
		e.At = fromUnix(at)
		out = append(out, e)
	}
	return out, rows.Err()
}

// ScrubIPs blanks the IP address of events older than the cutoff.
func (s *Store) ScrubIPs(ctx context.Context, before time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, "UPDATE events SET ip = '' WHERE ip != '' AND at < ?", before.Unix())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
