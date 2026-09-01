package gobackend

import (
	"sync"
	"time"
)

type RateLimiter struct {
	mu          sync.Mutex
	maxRequests int
	window      time.Duration
	timestamps  []time.Time
}

func NewRateLimiter(maxRequests int, window time.Duration) *RateLimiter {
	return &RateLimiter{
		maxRequests: maxRequests,
		window:      window,
		timestamps:  make([]time.Time, 0, maxRequests),
	}
}

// WaitForSlot blocks until a request slot is available. It is safe for
// concurrent callers: when multiple waiters wake at the same moment the
// capacity is re-checked under the lock, so a thundering herd cannot admit
// more than maxRequests in a window (the previous implementation released
// the lock around the sleep and then appended unconditionally after
// re-locking, letting N sleepers all admit at once).
func (r *RateLimiter) WaitForSlot() {
	r.mu.Lock()
	defer r.mu.Unlock()

	for {
		now := time.Now()
		r.cleanOldTimestamps(now)

		if len(r.timestamps) < r.maxRequests {
			r.timestamps = append(r.timestamps, now)
			return
		}

		oldestTimestamp := r.timestamps[0]
		waitUntil := oldestTimestamp.Add(r.window)
		waitDuration := waitUntil.Sub(now)
		if waitDuration <= 0 {
			// Slot already expired relative to the clock; re-evaluate.
			continue
		}

		// Release the lock while sleeping so other goroutines can acquire
		// slots, then re-lock and re-check capacity on wake.
		timer := time.NewTimer(waitDuration)
		r.mu.Unlock()
		<-timer.C
		r.mu.Lock()
	}
}

func (r *RateLimiter) cleanOldTimestamps(now time.Time) {
	cutoff := now.Add(-r.window)
	validStart := 0

	for i, ts := range r.timestamps {
		if ts.After(cutoff) {
			validStart = i
			break
		}
		validStart = i + 1
	}

	if validStart > 0 {
		r.timestamps = r.timestamps[validStart:]
	}
}

func (r *RateLimiter) TryAcquire() bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	r.cleanOldTimestamps(now)

	if len(r.timestamps) < r.maxRequests {
		r.timestamps = append(r.timestamps, now)
		return true
	}

	return false
}

func (r *RateLimiter) Available() int {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.cleanOldTimestamps(time.Now())
	return r.maxRequests - len(r.timestamps)
}

// Global SongLink rate limiter - 9 requests per minute (to be safe, limit is 10)
var songLinkRateLimiter = NewRateLimiter(9, time.Minute)
