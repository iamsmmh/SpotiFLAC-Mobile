package gobackend

import (
	"context"
	"errors"
	"sync"
	"time"
)

// ErrDownloadCancelled is returned when a download is cancelled by the user.
var ErrDownloadCancelled = errors.New("download cancelled")

// ErrExtensionRequestCancelled is returned when a UI-driven extension request
// is superseded by a newer home/search request.
var ErrExtensionRequestCancelled = errors.New("extension request cancelled")

type cancelEntry struct {
	ctx      context.Context
	cancel   context.CancelFunc
	canceled bool
	refs     int

	// tombstonedAt is set when the entry only exists to remember a cancel
	// that arrived while no work was attached (refs == 0). Such an entry is
	// pure garbage once the window in which the work could still start has
	// passed, so it is swept by pruneLocked.
	tombstonedAt time.Time
}

// A cancel that arrives before the work starts must still be honoured, but a
// cancel that arrives *after* the work already finished leaves an entry behind
// that nothing will ever claim. Extension request IDs are freshly generated for
// every call (see PlatformBridge._nextExtensionRequestId), and the UI cancels
// superseded home-feed/search requests optimistically, so those late cancels
// used to append a permanent map entry per request - an unbounded leak for the
// lifetime of the process.
const (
	cancelTombstoneTTL       = 2 * time.Minute
	cancelRegistryMaxEntries = 1024
)

type cancelRegistry struct {
	mu      sync.Mutex
	entries map[string]*cancelEntry
}

// pruneLocked drops tombstones that can no longer be claimed. Entries with
// live work attached (refs > 0) are never touched. The caller must hold r.mu.
func (r *cancelRegistry) pruneLocked(now time.Time) {
	var oldest string
	var oldestAt time.Time

	for id, entry := range r.entries {
		if entry.refs > 0 || entry.tombstonedAt.IsZero() {
			continue
		}
		if now.Sub(entry.tombstonedAt) >= cancelTombstoneTTL {
			if entry.cancel != nil {
				entry.cancel()
			}
			delete(r.entries, id)
			continue
		}
		if oldestAt.IsZero() || entry.tombstonedAt.Before(oldestAt) {
			oldest, oldestAt = id, entry.tombstonedAt
		}
	}

	// Hard cap: a pathological caller must not be able to grow the map without
	// bound between TTL sweeps. Evict the oldest claimable tombstone.
	for len(r.entries) > cancelRegistryMaxEntries && oldest != "" {
		if entry, ok := r.entries[oldest]; ok && entry.cancel != nil {
			entry.cancel()
		}
		delete(r.entries, oldest)

		oldest, oldestAt = "", time.Time{}
		for id, entry := range r.entries {
			if entry.refs > 0 || entry.tombstonedAt.IsZero() {
				continue
			}
			if oldestAt.IsZero() || entry.tombstonedAt.Before(oldestAt) {
				oldest, oldestAt = id, entry.tombstonedAt
			}
		}
	}
}

var (
	downloadCancels         = &cancelRegistry{entries: make(map[string]*cancelEntry)}
	extensionRequestCancels = &cancelRegistry{entries: make(map[string]*cancelEntry)}
)

func (r *cancelRegistry) init(id string) context.Context {
	if id == "" {
		return context.Background()
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	r.pruneLocked(time.Now())

	if entry, ok := r.entries[id]; ok {
		if entry.ctx == nil {
			ctx, cancel := context.WithCancel(context.Background())
			entry.ctx = ctx
			entry.cancel = cancel
			if entry.canceled && entry.cancel != nil {
				entry.cancel()
			}
		}
		entry.refs++
		// Work is attached again: the entry is live, not collectable garbage.
		entry.tombstonedAt = time.Time{}
		return entry.ctx
	}

	ctx, cancel := context.WithCancel(context.Background())
	r.entries[id] = &cancelEntry{
		ctx:      ctx,
		cancel:   cancel,
		canceled: false,
		refs:     1,
	}
	return ctx
}

func (r *cancelRegistry) context(id string) context.Context {
	if id == "" {
		return context.Background()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if entry, ok := r.entries[id]; ok && entry.ctx != nil {
		return entry.ctx
	}
	return context.Background()
}

func (r *cancelRegistry) requestCancel(id string) {
	if id == "" {
		return
	}

	r.mu.Lock()
	if entry, ok := r.entries[id]; ok {
		entry.canceled = true
		if entry.cancel != nil {
			entry.cancel()
		}
		if entry.refs <= 0 && entry.tombstonedAt.IsZero() {
			// Cancel landed after the work released the entry (or before it
			// ever attached): make it sweepable.
			entry.tombstonedAt = time.Now()
		}
	} else {
		r.entries[id] = &cancelEntry{canceled: true, tombstonedAt: time.Now()}
	}
	r.pruneLocked(time.Now())
	r.mu.Unlock()
}

func (r *cancelRegistry) isCancelled(id string) bool {
	if id == "" {
		return false
	}

	r.mu.Lock()
	entry, ok := r.entries[id]
	canceled := ok && entry.canceled
	r.mu.Unlock()
	return canceled
}

// resetIfIdle removes a cancellation entry that has no active work attached
// (refs <= 0). Such entries exist to catch an item that is just about to
// start, but if the item never starts the flag lingers and the next explicit
// retry would consume it and abort immediately.
func (r *cancelRegistry) resetIfIdle(id string) {
	if id == "" {
		return
	}

	r.mu.Lock()
	if entry, ok := r.entries[id]; ok && entry.refs <= 0 {
		delete(r.entries, id)
	}
	r.mu.Unlock()
}

func (r *cancelRegistry) release(id string) {
	if id == "" {
		return
	}

	r.mu.Lock()
	if entry, ok := r.entries[id]; ok {
		entry.refs--
		if entry.refs <= 0 {
			delete(r.entries, id)
		}
	}
	r.mu.Unlock()
}

func initDownloadCancel(itemID string) context.Context {
	return downloadCancels.init(itemID)
}

func downloadCancelContext(itemID string) context.Context {
	return downloadCancels.context(itemID)
}

func cancelDownload(itemID string) {
	if itemID == "" {
		return
	}
	downloadCancels.requestCancel(itemID)
	RemoveItemProgress(itemID)
}

func isDownloadCancelled(itemID string) bool {
	return downloadCancels.isCancelled(itemID)
}

func resetDownloadCancel(itemID string) {
	downloadCancels.resetIfIdle(itemID)
}

func clearDownloadCancel(itemID string) {
	downloadCancels.release(itemID)
}

func initExtensionRequestCancel(requestID string) context.Context {
	return extensionRequestCancels.init(requestID)
}

func extensionRequestCancelContext(requestID string) context.Context {
	return extensionRequestCancels.context(requestID)
}

func cancelExtensionRequest(requestID string) {
	extensionRequestCancels.requestCancel(requestID)
}

func isExtensionRequestCancelled(requestID string) bool {
	return extensionRequestCancels.isCancelled(requestID)
}

func clearExtensionRequestCancel(requestID string) {
	extensionRequestCancels.release(requestID)
}

// resetForTest drops every entry. Tests share one process, and a cancel that
// is recorded by one test must not leak into the next one.
func (r *cancelRegistry) resetForTest() {
	r.mu.Lock()
	for id, entry := range r.entries {
		if entry.cancel != nil {
			entry.cancel()
		}
		delete(r.entries, id)
	}
	r.mu.Unlock()
}

// resetCancelRegistriesForTest clears both process-global cancel registries.
func resetCancelRegistriesForTest() {
	downloadCancels.resetForTest()
	extensionRequestCancels.resetForTest()
}
