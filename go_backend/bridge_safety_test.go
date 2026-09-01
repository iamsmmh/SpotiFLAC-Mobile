package gobackend

import (
	"strings"
	"testing"
)

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
