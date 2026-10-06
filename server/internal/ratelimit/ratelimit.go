// Package ratelimit is a small per-key token bucket limiter with bounded
// memory: buckets that have refilled completely carry no state and are
// evicted, and the number of tracked keys is capped.
package ratelimit

import (
	"math"
	"sync"
	"time"
)

// Limiter allows Burst requests at once per key, refilling at Rate tokens per
// second.
type Limiter struct {
	rate    float64
	burst   float64
	maxKeys int
	now     func() time.Time

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

// New returns a limiter that refills one token every `every` and holds at
// most burst tokens, tracking at most maxKeys keys.
func New(every time.Duration, burst, maxKeys int) *Limiter {
	if burst < 1 {
		burst = 1
	}
	if maxKeys < 1 {
		maxKeys = 1
	}
	return &Limiter{
		rate:    1 / every.Seconds(),
		burst:   float64(burst),
		maxKeys: maxKeys,
		now:     time.Now,
		buckets: make(map[string]*bucket),
	}
}

// SetClock replaces the time source (for tests).
func (l *Limiter) SetClock(now func() time.Time) {
	l.mu.Lock()
	l.now = now
	l.mu.Unlock()
}

func (l *Limiter) level(b *bucket, now time.Time) float64 {
	el := now.Sub(b.last).Seconds()
	if el < 0 {
		el = 0
	}
	return math.Min(l.burst, b.tokens+el*l.rate)
}

// Allow takes one token for key. When none is left it returns false and how
// long until the next token.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		if len(l.buckets) >= l.maxKeys {
			l.sweepLocked(now)
			for k := range l.buckets {
				if len(l.buckets) < l.maxKeys {
					break
				}
				delete(l.buckets, k) // map order is random: evicts an arbitrary key
			}
		}
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	b.tokens = l.level(b, now)
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) / l.rate * float64(time.Second))
	return false, wait
}

// Blocked reports whether key has no token left, without taking one.
func (l *Limiter) Blocked(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	return ok && l.level(b, l.now()) < 1
}

// Sweep drops buckets that have refilled completely.
func (l *Limiter) Sweep() {
	l.mu.Lock()
	l.sweepLocked(l.now())
	l.mu.Unlock()
}

func (l *Limiter) sweepLocked(now time.Time) {
	for k, b := range l.buckets {
		if l.level(b, now) >= l.burst {
			delete(l.buckets, k)
		}
	}
}

// Len is the number of tracked keys.
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
