package ratelimit

import (
	"fmt"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func TestBurstAndRefill(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0)}
	l := New(10*time.Second, 3, 100)
	l.SetClock(c.now)

	for i := 0; i < 3; i++ {
		if ok, _ := l.Allow("a"); !ok {
			t.Fatalf("request %d denied within burst", i)
		}
	}
	ok, wait := l.Allow("a")
	if ok {
		t.Fatal("request beyond burst allowed")
	}
	if wait <= 0 || wait > 10*time.Second {
		t.Fatalf("retry after %v", wait)
	}
	if !l.Blocked("a") || l.Blocked("b") {
		t.Fatal("Blocked")
	}
	// Other keys are independent.
	if ok, _ := l.Allow("b"); !ok {
		t.Fatal("independent key denied")
	}

	c.advance(9 * time.Second)
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("allowed before a token refilled")
	}
	c.advance(2 * time.Second)
	if ok, _ := l.Allow("a"); !ok {
		t.Fatal("denied after refill")
	}
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("only one token should have refilled")
	}
}

func TestSweepEvictsIdle(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0)}
	l := New(time.Second, 5, 100)
	l.SetClock(c.now)
	l.Allow("a")
	l.Allow("b")
	if l.Len() != 2 {
		t.Fatalf("len %d", l.Len())
	}
	l.Sweep()
	if l.Len() != 2 {
		t.Fatal("swept buckets that still carry state")
	}
	c.advance(10 * time.Second)
	l.Sweep()
	if l.Len() != 0 {
		t.Fatalf("idle buckets kept: %d", l.Len())
	}
}

func TestBoundedMemory(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0)}
	l := New(time.Hour, 1, 50)
	l.SetClock(c.now)
	for i := 0; i < 1000; i++ {
		l.Allow(fmt.Sprintf("ip-%d", i))
		if l.Len() > 50 {
			t.Fatalf("tracked %d keys, cap is 50", l.Len())
		}
	}
}
