package gobackend

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestExportedEntryPointsRecoverPanics enforces the contract documented in
// bridge_safety.go.
//
// gomobile binds every exported function of this package as a JNI / Swift
// entry point and installs no recover on that boundary, so an escaping Go
// panic (nil-map write, slice bounds, type assertion on a malformed provider
// payload, a third-party tag parser choking on a corrupt file, ...) does not
// surface as an exception in Kotlin/Swift - it aborts the whole process with
// SIGABRT. That is how a single misbehaving extension or one bad audio file
// used to be able to take the app down.
//
// The rule: every exported function declared in an exports*.go file must start
// with a deferred recoverBridgePanic. This test fails when a new entry point is
// added without one.
func TestExportedEntryPointsRecoverPanics(t *testing.T) {
	paths, err := filepath.Glob("exports*.go")
	if err != nil {
		t.Fatalf("glob exports*.go: %v", err)
	}
	if len(paths) == 0 {
		t.Fatal("no exports*.go files found - has the package layout changed?")
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
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Recv != nil || !fn.Name.IsExported() || fn.Body == nil {
				continue
			}
			checked++
			if len(fn.Body.List) == 0 {
				continue
			}
			first := fn.Body.List[0]
			text := string(src[fset.Position(first.Pos()).Offset:fset.Position(first.End()).Offset])
			if _, isDefer := first.(*ast.DeferStmt); !isDefer ||
				!strings.Contains(text, "recoverBridgePanic") {
				unguarded = append(unguarded, path+":"+fn.Name.Name)
			}
		}
	}

	if checked == 0 {
		t.Fatal("no exported entry points inspected - the AST walk is broken")
	}
	if len(unguarded) > 0 {
		t.Errorf(
			"%d exported gomobile entry point(s) do not begin with a deferred "+
				"recoverBridgePanic; a panic there aborts the host app "+
				"(see bridge_safety.go):\n\t%s",
			len(unguarded), strings.Join(unguarded, "\n\t"),
		)
	}
}
