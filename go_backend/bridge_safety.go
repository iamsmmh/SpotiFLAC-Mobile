package gobackend

import (
	"fmt"
	"runtime/debug"
)

// recoverBridgePanic converts an unrecovered panic in a gomobile-exported
// entry point into a regular error. gomobile does NOT install a recover on
// the JNI/Objective-C boundary: an escaping Go panic (nil-map write, slice
// out-of-range, type assertion from a malformed payload, a third-party
// parser choking on a provider response, etc.) takes down the whole
// application with SIGABRT. Every exported (capitalized) function that the
// mobile shells call directly MUST either return an error through
// bridgeError/bridgeJSONError or, for the JSON-string entry points that the
// MethodChannel layer already treats as error payloads, call
// recoverBridgePanicJSON in a deferred closure.
//
// The deferred call must be the first statement of the exported function so
// the panic cannot unwind past it:
//
//	func DownloadByStrategy(requestJSON string) (resp string, err error) {
//	    defer func() { if r := recoverBridgePanic(recover()); r != nil { err = r } }()
//	    ...
//	}
func recoverBridgePanic(r any) error {
	if r == nil {
		return nil
	}
	stack := string(debug.Stack())
	GoLog("[Bridge] recovered panic at gomobile boundary: %v\n%s\n", r, stack)
	return fmt.Errorf("internal backend error: %v", r)
}

// recoverBridgePanicJSON is the variant for entry points that communicate
// failures as a JSON DownloadResponse-style payload rather than as a Go
// error (the mobile MethodChannel layer parses the returned string). On
// panic it overwrites *out with an error response carrying the "unknown"
// error type so the queue manager records the item as failed and continues
// with the next track instead of the process dying.
//
// Usage:
//
//	func GetAllDownloadProgress() (resp string) {
//	    defer func() {
//	        if r := recoverBridgePanic(recover()); r != nil {
//	            resp = bridgePanicJSON(r)
//	        }
//	    }()
//	    ...
//	}
func bridgePanicJSON(r any) string {
	err := recoverBridgePanic(r)
	if err == nil {
		return ""
	}
	s, _ := marshalJSONString(map[string]any{
		"success":    false,
		"error":      err.Error(),
		"error_type": "unknown",
	})
	return s
}

// recoverWorkerPanic contains a panic inside a background worker goroutine
// (library-scan workers, ISRC parse workers, lyrics provider fan-out, HTTP/2
// connection retirement). A deferred recover in the exported entry point does
// NOT cover these: a defer only catches panics unwinding through its own
// goroutine, so an escaping panic in a worker aborts the whole process with
// SIGABRT even though the failing work unit is a single corrupt file or one
// malformed provider response out of thousands. Workers must convert the
// panic into a per-unit failure and keep going:
//
//	func runOneUnit(...) (result T, err error) {
//	    defer func() {
//	        if r := recoverWorkerPanic("library scan", recover()); r != nil {
//	            result, err = *new(T), r
//	        }
//	    }()
//	    ...
//	}
func recoverWorkerPanic(worker string, r any) error {
	if r == nil {
		return nil
	}
	stack := string(debug.Stack())
	GoLog("[Bridge] recovered panic in %s worker: %v\n%s\n", worker, r, stack)
	return fmt.Errorf("internal error in %s worker: %v", worker, r)
}
