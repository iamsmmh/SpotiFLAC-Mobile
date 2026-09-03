//go:build !ios

package gobackend

import (
	"context"
	"net/http"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

// panickingShutdownConn simulates an http2 connection whose Shutdown
// implementation panics (a misbehaving or future stdlib/utls code path).
type panickingShutdownConn struct {
	closed chan struct{}
}

func (c *panickingShutdownConn) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, nil
}

func (c *panickingShutdownConn) ReserveNewRequest() bool { return false }

func (c *panickingShutdownConn) State() http2.ClientConnState {
	return http2.ClientConnState{Closing: true}
}

func (c *panickingShutdownConn) Close() error {
	select {
	case <-c.closed:
	default:
		close(c.closed)
	}
	return nil
}

func (c *panickingShutdownConn) Shutdown(context.Context) error {
	panic("shutdown exploded")
}

// TestUTLSPoolRetirementSurvivesPanickingShutdown pins the crash-safety
// contract of the detached retirement goroutine: without its recover guard,
// the panic below would abort the test process (and, in production, the
// whole app). With the guard, the connection is force-closed instead.
func TestUTLSPoolRetirementSurvivesPanickingShutdown(t *testing.T) {
	conn := &panickingShutdownConn{closed: make(chan struct{})}

	retirePooledHTTP2ConnWithTimeout(conn, 20*time.Millisecond)

	select {
	case <-conn.closed:
	case <-time.After(2 * time.Second):
		t.Fatal("panicking shutdown did not fall back to a force close")
	}
}
