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

// WaitForSlot blocks until the caller may proceed without exceeding
// maxRequests per window. Capacity is re-checked after every wait: several
// goroutines can be parked on the same expiring timestamp, and only as many
// as there are freed slots may be admitted when it expires. An unconditional
// append after the sleep would over-admit under concurrency and burst past
// the provider's rate limit.
func (r *RateLimiter) WaitForSlot() {
	r.mu.Lock()
	for {
		now := time.Now()
		r.cleanOldTimestamps(now)

		if len(r.timestamps) < r.maxRequests {
			r.timestamps = append(r.timestamps, now)
			r.mu.Unlock()
			return
		}

		waitUntil := r.timestamps[0].Add(r.window)
		r.mu.Unlock()
		time.Sleep(time.Until(waitUntil))
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
