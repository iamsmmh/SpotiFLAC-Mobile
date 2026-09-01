package gobackend

import (
	"testing"
	"time"
)

// A cancel that arrives while work is attached must be honoured immediately.
func TestCancelRegistryCancelsLiveWork(t *testing.T) {
	r := &cancelRegistry{entries: make(map[string]*cancelEntry)}

	ctx := r.init("item-1")
	if ctx.Err() != nil {
		t.Fatalf("fresh context already done: %v", ctx.Err())
	}

	r.requestCancel("item-1")
	if ctx.Err() == nil {
		t.Fatal("context not cancelled after requestCancel")
	}
	if !r.isCancelled("item-1") {
		t.Fatal("isCancelled = false after requestCancel")
	}

	r.release("item-1")
	if len(r.entries) != 0 {
		t.Fatalf("entry survived release: %+v", r.entries)
	}
}

// A cancel that arrives just before the work starts must still abort it.
func TestCancelRegistryTombstoneIsHonouredWithinTTL(t *testing.T) {
	r := &cancelRegistry{entries: make(map[string]*cancelEntry)}

	r.requestCancel("item-1")
	ctx := r.init("item-1")
	if ctx.Err() == nil {
		t.Fatal("work started with a pending cancel but its context is live")
	}
}

// The same cancel must not be retained forever: extension request ids are
// unique per call and the UI cancels superseded requests optimistically, so a
// late cancel would otherwise append one permanent map entry per request.
func TestCancelRegistrySweepsExpiredTombstones(t *testing.T) {
	r := &cancelRegistry{entries: make(map[string]*cancelEntry)}

	for _, id := range []string{"req-1", "req-2", "req-3"} {
		r.requestCancel(id)
	}
	if len(r.entries) != 3 {
		t.Fatalf("entries = %d, want 3", len(r.entries))
	}

	// Age the tombstones past the TTL.
	r.mu.Lock()
	for _, entry := range r.entries {
		entry.tombstonedAt = time.Now().Add(-cancelTombstoneTTL - time.Second)
	}
	r.mu.Unlock()

	r.requestCancel("req-4")

	r.mu.Lock()
	remaining := len(r.entries)
	_, keptFresh := r.entries["req-4"]
	r.mu.Unlock()

	if remaining != 1 {
		t.Fatalf("expired tombstones were not swept: %d entries remain", remaining)
	}
	if !keptFresh {
		t.Fatal("the fresh tombstone was swept")
	}
}

// Live work must never be swept, however old the registry gets.
func TestCancelRegistryNeverSweepsAttachedWork(t *testing.T) {
	r := &cancelRegistry{entries: make(map[string]*cancelEntry)}

	ctx := r.init("live")
	for i := 0; i < cancelRegistryMaxEntries+50; i++ {
		r.requestCancel(string(rune('a'+i%26)) + "-" + time.Now().Format("150405.000000000") + "-" + string(rune(i)))
	}

	r.mu.Lock()
	_, ok := r.entries["live"]
	total := len(r.entries)
	r.mu.Unlock()

	if !ok {
		t.Fatal("entry with attached work was evicted")
	}
	if total > cancelRegistryMaxEntries+1 {
		t.Fatalf("registry grew past the cap: %d entries", total)
	}
	if ctx.Err() != nil {
		t.Fatalf("live context was cancelled by the sweeper: %v", ctx.Err())
	}
}

// resetIfIdle keeps its documented behaviour: a lingering flag must not make a
// user-triggered retry abort instantly.
func TestCancelRegistryResetIfIdleClearsPendingFlag(t *testing.T) {
	r := &cancelRegistry{entries: make(map[string]*cancelEntry)}

	r.requestCancel("item-1")
	r.resetIfIdle("item-1")

	if r.isCancelled("item-1") {
		t.Fatal("cancel flag survived resetIfIdle")
	}
	if ctx := r.init("item-1"); ctx.Err() != nil {
		t.Fatalf("retry context is already cancelled: %v", ctx.Err())
	}
}
