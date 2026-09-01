package gobackend

import (
	"sync"
	"testing"
	"time"
)

// TestRateLimiterWaitForSlotConcurrency verifies that concurrent WaitForSlot
// callers never exceed maxRequests per window. The old implementation
// unconditionally appended after sleeping out the oldest timestamp, so N
// goroutines parked on the same expiry were all admitted at once, bursting
// past the limit (e.g. SongLink's 10/min) and triggering upstream 429s.
func TestRateLimiterWaitForSlotConcurrency(t *testing.T) {
	const (
		maxRequests = 3
		window      = 120 * time.Millisecond
		callers     = 10
	)
	limiter := NewRateLimiter(maxRequests, window)

	var (
		mu         sync.Mutex
		admissions []time.Time
		wg         sync.WaitGroup
	)
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			limiter.WaitForSlot()
			mu.Lock()
			admissions = append(admissions, time.Now())
			mu.Unlock()
		}()
	}
	wg.Wait()

	if len(admissions) != callers {
		t.Fatalf("admitted %d callers, want %d", len(admissions), callers)
	}

	// Sliding-window check: no admission may see maxRequests earlier
	// admissions within the preceding window. A small tolerance absorbs the
	// gap between slot acquisition and timestamp capture under scheduling
	// jitter.
	const tolerance = 15 * time.Millisecond
	for i, ts := range admissions {
		inWindow := 0
		for j, other := range admissions {
			if j == i {
				continue
			}
			if other.Before(ts) && ts.Sub(other) < window-tolerance {
				inWindow++
			}
		}
		if inWindow >= maxRequests {
			t.Fatalf(
				"admission %d had %d earlier admissions within the window (limit %d)",
				i, inWindow, maxRequests,
			)
		}
	}
}

// TestRateLimiterWaitForSlotSequential guards the fast path: when capacity is
// free, WaitForSlot must not sleep.
func TestRateLimiterWaitForSlotSequential(t *testing.T) {
	limiter := NewRateLimiter(2, time.Hour)
	start := time.Now()
	limiter.WaitForSlot()
	limiter.WaitForSlot()
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Fatalf("free-capacity WaitForSlot took %v, expected no sleep", elapsed)
	}
	if limiter.Available() != 0 {
		t.Fatalf("Available = %d after consuming both slots, want 0", limiter.Available())
	}
}
