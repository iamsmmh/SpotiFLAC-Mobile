package gobackend

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestBackgroundWorkersRecoverPanics extends the bridge_safety.go contract to
// goroutines: a panic inside a `go func` escapes the exported entry point's
// deferred recover and aborts the whole process with SIGABRT. Every
// background worker in a non-test file must therefore contain its own recover
// (directly via recoverWorkerPanic, or a raw recover as in the JS timeout
// watchdog). This test fails when a new worker is added without one.
func TestBackgroundWorkersRecoverPanics(t *testing.T) {
	paths, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob *.go: %v", err)
	}
	sort.Strings(paths)

	var unguarded []string
	checked := 0

	for _, path := range paths {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, path, src, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}

		ast.Inspect(file, func(n ast.Node) bool {
			goStmt, ok := n.(*ast.GoStmt)
			if !ok {
				return true
			}
			checked++
			// Slice the statement's source span and require a recover call
			// inside it. String matching is deliberate: both
			// `recoverWorkerPanic(.., recover())` and a raw `recover()`
			// satisfy the contract.
			start := fset.Position(goStmt.Pos()).Offset
			end := fset.Position(goStmt.End()).Offset
			if start < 0 || end > len(src) || start >= end {
				unguarded = append(unguarded, path+":unpositioned go stmt")
				return true
			}
			if !strings.Contains(string(src[start:end]), "recover(") {
				line := fset.Position(goStmt.Pos()).Line
				unguarded = append(unguarded, sprintfGoStmt(path, line))
			}
			return true
		})
	}

	if checked == 0 {
		t.Fatal("no `go` statements found - has the package layout changed?")
	}
	if len(unguarded) > 0 {
		t.Errorf(
			"%d background worker(s) without panic containment:\n  %s\nAdd a deferred recoverWorkerPanic (see bridge_safety.go).",
			len(unguarded),
			strings.Join(unguarded, "\n  "),
		)
	}
}

func sprintfGoStmt(path string, line int) string {
	return path + ":" + itoa(line)
}

// itoa avoids importing strconv for a single test helper.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
