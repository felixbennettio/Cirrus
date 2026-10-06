package store

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func openTest(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func dev(i int) string { return fmt.Sprintf("%064x", i) }

func TestReopenKeepsData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	l, err := s.CreateLicense(ctx, NewLicense{Product: "cirrus-linux", Platform: "linux", MaxDevices: 1, Email: " A@Example.com "}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if l.Email != "a@example.com" {
		t.Fatalf("email not normalised: %q", l.Email)
	}
	s.Close()
	s, err = Open(path) // migrations must be idempotent
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	got, err := s.LicenseByKey(ctx, l.Key)
	if err != nil || got.ID != l.ID {
		t.Fatalf("reopen: %v %+v", err, got)
	}
	var mode string
	if err := s.db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("journal_mode = %q, %v", mode, err)
	}

	backup := filepath.Join(t.TempDir(), "backup.db")
	if err := s.Backup(ctx, backup); err != nil {
		t.Fatalf("backup: %v", err)
	}
	if err := s.Backup(ctx, backup); err == nil {
		t.Fatal("backup overwrote an existing file")
	}
	b, err := Open(backup)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if got, err := b.LicenseByKey(ctx, l.Key); err != nil || got.ID != l.ID {
		t.Fatalf("backup content: %v", err)
	}
}

// Concurrent activations must never exceed the device limit.
func TestConcurrentActivationsRespectLimit(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	l, err := s.CreateLicense(ctx, NewLicense{Product: "cirrus-android", Platform: "android", MaxDevices: 3, Email: "a@example.com"}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	okCount, limitCount := 0, 0
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := s.Activate(ctx, l.Key, ActivateInput{DeviceID: dev(i), DeviceName: "d", Platform: "android", AppVersion: "1"}, time.Now())
			mu.Lock()
			defer mu.Unlock()
			var le *LimitError
			switch {
			case err == nil:
				okCount++
			case errors.As(err, &le):
				limitCount++
			default:
				t.Errorf("activate %d: %v", i, err)
			}
		}(i)
	}
	wg.Wait()
	if okCount != 3 || limitCount != 9 {
		t.Fatalf("ok=%d limit=%d, want 3 and 9", okCount, limitCount)
	}
	got, _ := s.LicenseByID(ctx, l.ID)
	if got.DevicesUsed != 3 {
		t.Fatalf("devices used %d", got.DevicesUsed)
	}
}

func TestPayOrderIdempotent(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	now := time.Now()
	products := func(string) (string, int, bool) { return "windows", 1, true }
	if err := s.InsertOrder(ctx, Order{No: "C1", TokenHash: "h", Product: "cirrus-windows", Email: "b@example.com",
		Method: "alipay", Provider: "manual", AmountCents: 19800, CreatedAt: now, ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := s.InsertOrder(ctx, Order{No: "C1", TokenHash: "h", Product: "x", Email: "x", Method: "alipay",
		Provider: "manual", CreatedAt: now, ExpiresAt: now}); !errors.Is(err, ErrConflict) {
		t.Fatalf("duplicate order: %v", err)
	}
	o, l, issued, err := s.PayOrder(ctx, "C1", "ref1", now, products)
	if err != nil || !issued || o.Status != StatusPaid || l.OrderNo != "C1" || l.Email != "b@example.com" {
		t.Fatalf("pay: %v issued=%v %+v %+v", err, issued, o, l)
	}
	o2, l2, issued, err := s.PayOrder(ctx, "C1", "ref2", now, products)
	if err != nil || issued || l2.ID != l.ID || o2.LicenseKey != l.Key {
		t.Fatalf("second pay: %v issued=%v", err, issued)
	}
	if err := s.CancelOrder(ctx, "C1"); !errors.Is(err, ErrNotPending) {
		t.Fatalf("cancel paid order: %v", err)
	}
	if err := s.CancelOrder(ctx, "nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cancel missing order: %v", err)
	}
}

func TestSearchAndEvents(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	l, _ := s.CreateLicense(ctx, NewLicense{Product: "cirrus-linux", Platform: "linux", MaxDevices: 1, Email: "find.me@example.com"}, time.Now())
	s.CreateLicense(ctx, NewLicense{Product: "cirrus-linux", Platform: "linux", MaxDevices: 1, Email: "other@example.com"}, time.Now())
	for _, q := range []string{"find.me", "FIND.ME@EXAMPLE.COM", l.Key, l.Key[7:18], l.ID} {
		got, err := s.SearchLicenses(ctx, q, 10)
		if err != nil || len(got) != 1 || got[0].ID != l.ID {
			t.Errorf("search %q: %v %d results", q, err, len(got))
		}
	}
	if got, _ := s.SearchLicenses(ctx, "%", 10); len(got) != 0 {
		t.Error("LIKE wildcard not escaped")
	}
	if got, _ := s.SearchLicenses(ctx, "", 10); len(got) != 2 {
		t.Error("empty search should list all")
	}

	old := time.Now().Add(-200 * 24 * time.Hour)
	s.Log(ctx, Event{At: old, Kind: "activate", LicenseID: l.ID, IP: "1.2.3.4"})
	s.Log(ctx, Event{Kind: "validate", LicenseID: l.ID, IP: "5.6.7.8"})
	n, err := s.ScrubIPs(ctx, time.Now().Add(-180*24*time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("scrub: %d %v", n, err)
	}
	evs, _ := s.Events(ctx, l.ID, "", 10)
	if len(evs) != 2 || evs[0].IP != "5.6.7.8" || evs[1].IP != "" {
		t.Fatalf("events: %+v", evs)
	}
}
