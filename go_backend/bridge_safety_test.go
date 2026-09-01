package gobackend

import (
	"strings"
	"sync"
	"testing"
	"time"
)

// TestRateLimiterWaitForSlotNoThunderingHerd: the fixed WaitForSlot must
// never admit more than maxRequests callers within one window even when many
// goroutines are released simultaneously. The previous implementation
// released the lock during the sleep and appended unconditionally after
// re-locking, so N sleepers all admitted at once and burst past the cap.
func TestRateLimiterWaitForSlotNoThunderingHerd(t *testing.T) {
	const max = 5
	rl := NewRateLimiter(max, 250*time.Millisecond)

	// Fill the window.
	for i := 0; i < max; i++ {
		rl.WaitForSlot()
	}
	if got := rl.Available(); got != 0 {
		t.Fatalf("expected 0 available slots after filling, got %d", got)
	}

	var inside, maxObserved int
	var mu sync.Mutex
	entered := make(chan struct{}, max*4)
	release := make(chan struct{})

	var wg sync.WaitGroup
	for i := 0; i < max*3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rl.WaitForSlot()
			mu.Lock()
			inside++
			if inside > maxObserved {
				maxObserved = inside
			}
			mu.Unlock()
			entered <- struct{}{}
			<-release
			mu.Lock()
			inside--
			mu.Unlock()
		}()
	}

	// Wait until exactly `max` waiters have entered the critical section;
	// any additional admission before the window rolls over is the burst bug.
	for i := 0; i < max; i++ {
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d of %d expected waiters admitted", i, max)
		}
	}
	select {
	case <-entered:
		t.Fatalf("more than %d waiters admitted within one window (burst)", max)
	case <-time.After(100 * time.Millisecond):
		// Expected: the (max+1)th waiter is held back until the window rolls.
	}

	close(release)
	wg.Wait()

	if maxObserved > max {
		t.Fatalf("thundering herd: observed %d concurrent admissions, cap is %d", maxObserved, max)
	}
}

// TestBridgePanicRecoveryJSON ensures a panic at an exported entry point is
// converted into a structured error payload rather than propagating across
// the JNI/Swift boundary.
func TestBridgePanicRecoveryJSON(t *testing.T) {
	resp := func() (out string) {
		defer func() {
			if r := recoverBridgePanic(recover()); r != nil {
				out = bridgePanicJSON(r)
			}
		}()
		panic("simulated nil-map write")
	}()
	if !strings.Contains(resp, `"success":false`) {
		t.Fatalf("expected JSON error payload with success:false, got %q", resp)
	}
	if !strings.Contains(resp, "simulated nil-map write") {
		t.Fatalf("expected payload to carry the panic message, got %q", resp)
	}
}

// TestBridgeRecoverNilIsNoop verifies the helper is safe to call when no
// panic occurred (deferred on every invocation).
func TestBridgeRecoverNilIsNoop(t *testing.T) {
	if err := recoverBridgePanic(nil); err != nil {
		t.Fatalf("recoverBridgePanic(nil) = %v, want nil", err)
	}
}
