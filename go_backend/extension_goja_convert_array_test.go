package gobackend

import (
	"strings"
	"testing"

	"github.com/dop251/goja"
)

func TestGojaArrayLengthAcceptsRealArray(t *testing.T) {
	vm := goja.New()
	value, err := vm.RunString(`[{id: "one"}, {id: "two"}]`)
	if err != nil {
		t.Fatalf("RunString failed: %v", err)
	}

	length, err := gojaArrayLength(value, vm)
	if err != nil {
		t.Fatalf("gojaArrayLength returned error: %v", err)
	}
	if length != 2 {
		t.Fatalf("length = %d, want 2", length)
	}
}

func TestGojaArrayLengthRejectsArrayLikeObject(t *testing.T) {
	vm := goja.New()
	value, err := vm.RunString(`({0: {id: "one"}, length: 2147483647})`)
	if err != nil {
		t.Fatalf("RunString failed: %v", err)
	}

	if _, err := gojaArrayLength(value, vm); err == nil || !strings.Contains(err.Error(), "not an array") {
		t.Fatalf("gojaArrayLength error = %v, want not-an-array error", err)
	}
}

func TestGojaArrayLengthRejectsOversizedSparseArray(t *testing.T) {
	vm := goja.New()
	value, err := vm.RunString(`(() => { const items = []; items.length = 10001; return items; })()`)
	if err != nil {
		t.Fatalf("RunString failed: %v", err)
	}

	if _, err := gojaArrayLength(value, vm); err == nil || !strings.Contains(err.Error(), "exceeds limit") {
		t.Fatalf("gojaArrayLength error = %v, want size-limit error", err)
	}
}
