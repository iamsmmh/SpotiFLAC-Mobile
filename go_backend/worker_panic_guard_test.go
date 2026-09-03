package gobackend

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// These tests pin the crash-safety contract for background worker
// goroutines: a panic raised while processing ONE work unit (a corrupt file,
// a malformed provider response) must be converted into a failure of that
// unit only. Without the guards a panic in a worker goroutine aborts the
// whole process — the deferred recoverBridgePanic on exported entry points
// does not cover it, because a defer only catches panics unwinding through
// its own goroutine. Removing any guard makes the corresponding test here
// crash the test binary, which is the regression signal.

func TestRecoverWorkerPanicSemantics(t *testing.T) {
	if err := recoverWorkerPanic("library scan", nil); err != nil {
		t.Fatalf("recoverWorkerPanic(nil) = %v, want nil", err)
	}
	err := recoverWorkerPanic("library scan", "boom")
	if err == nil {
		t.Fatal("recoverWorkerPanic returned nil for a non-nil panic value")
	}
	msg := err.Error()
	if !strings.Contains(msg, "library scan") || !strings.Contains(msg, "boom") {
		t.Fatalf("error %q does not identify the worker and the panic value", msg)
	}
}

func withLibraryScanOneFile(t *testing.T, replacement func(filePath, displayNameHint, coverCacheKey, scanTime string, knownModTime int64) (*LibraryScanResult, error)) {
	t.Helper()
	original := libraryScanOneFile
	libraryScanOneFile = replacement
	t.Cleanup(func() { libraryScanOneFile = original })
}

func panickingLibraryScanFixture(panicPath string) func(filePath, displayNameHint, coverCacheKey, scanTime string, knownModTime int64) (*LibraryScanResult, error) {
	return func(filePath, displayNameHint, coverCacheKey, scanTime string, knownModTime int64) (*LibraryScanResult, error) {
		if filePath == panicPath {
			panic("malformed file exploded the parser")
		}
		return &LibraryScanResult{FilePath: filePath, TrackName: "ok"}, nil
	}
}

func TestLibraryScanWorkersSurvivePanickingFile(t *testing.T) {
	const panicPath = "/nonexistent/panic-track.flac"
	withLibraryScanOneFile(t, panickingLibraryScanFixture(panicPath))

	// 20 tasks forces the parallel path (libraryScanWorkerCount returns 1
	// below 16 tasks), so this exercises the worker goroutines.
	const taskCount = 20
	tasks := make([]libraryScanTask, 0, taskCount)
	for i := 0; i < taskCount; i++ {
		path := fmt.Sprintf("/tmp/track-%02d.flac", i)
		if i == 7 {
			path = panicPath
		}
		tasks = append(tasks, libraryScanTask{
			index: i,
			info:  libraryAudioFileInfo{path: path, size: 1, modTime: int64(i)},
		})
	}

	completed := 0
	results, errorCount, err := scanLibraryAudioTasksParallelWithSink(
		tasks,
		"2026-01-01T00:00:00Z",
		make(chan struct{}),
		taskCount,
		&completed,
		nil,
	)
	if err != nil {
		t.Fatalf("scan returned error: %v", err)
	}
	if errorCount != 1 {
		t.Fatalf("errorCount = %d, want 1 (only the panicking file)", errorCount)
	}
	if len(results) != taskCount-1 {
		t.Fatalf("results = %d, want %d", len(results), taskCount-1)
	}
	if completed != taskCount {
		t.Fatalf("completed = %d, want %d", completed, taskCount)
	}
	if _, exists := results[7]; exists {
		t.Fatal("panicking task produced a result entry")
	}
}

func TestLibraryScanSerialPathSurvivesPanickingFile(t *testing.T) {
	const panicPath = "/nonexistent/panic-track.flac"
	withLibraryScanOneFile(t, panickingLibraryScanFixture(panicPath))

	// Fewer than 16 tasks forces the serial path, which must also contain
	// panics so a single-file scan of a corrupt file degrades to an error.
	tasks := []libraryScanTask{
		{index: 0, info: libraryAudioFileInfo{path: "/tmp/a.flac", size: 1}},
		{index: 1, info: libraryAudioFileInfo{path: panicPath, size: 1}},
		{index: 2, info: libraryAudioFileInfo{path: "/tmp/b.flac", size: 1}},
	}

	completed := 0
	results, errorCount, err := scanLibraryAudioTasksParallelWithSink(
		tasks,
		"2026-01-01T00:00:00Z",
		make(chan struct{}),
		len(tasks),
		&completed,
		nil,
	)
	if err != nil {
		t.Fatalf("scan returned error: %v", err)
	}
	if errorCount != 1 {
		t.Fatalf("errorCount = %d, want 1", errorCount)
	}
	if len(results) != 2 {
		t.Fatalf("results = %d, want 2", len(results))
	}
}

func TestISRCIndexSurvivesPanickingReader(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.flac")
	bad := filepath.Join(dir, "bad.flac")
	for _, path := range []string{good, bad} {
		if err := os.WriteFile(path, []byte("placeholder audio bytes"), 0o644); err != nil {
			t.Fatalf("failed to write fixture: %v", err)
		}
	}

	original := isrcFileReader
	isrcFileReader = func(path string) string {
		if path == bad {
			panic("corrupt flac exploded the tag reader")
		}
		return "usrc17607791"
	}
	t.Cleanup(func() { isrcFileReader = original })

	idx := buildISRCIndex(dir)
	if idx == nil {
		t.Fatal("buildISRCIndex returned nil")
	}
	if got := idx.files[good].isrc; got != "USRC17607791" {
		t.Fatalf("healthy file isrc = %q, want USRC17607791", got)
	}
	if got := idx.files[bad].isrc; got != "" {
		t.Fatalf("panicking file isrc = %q, want empty", got)
	}
	if idx.index["USRC17607791"] != good {
		t.Fatalf("index lookup = %q, want %q", idx.index["USRC17607791"], good)
	}
}

func TestLyricsFanOutSurvivesPanickingProvider(t *testing.T) {
	clearLyricsProviderHealth()
	t.Cleanup(clearLyricsProviderHealth)

	fetch := func(providerName string, _ lyricsProviderSearchRequest) (*LyricsResponse, error, bool) {
		if providerName == LyricsProviderLRCLIB {
			panic("malformed provider response exploded")
		}
		return &LyricsResponse{PlainLyrics: "hello from " + providerName, Provider: providerName}, nil, true
	}

	lyrics, err := fetchLyricsProviders(
		[]string{LyricsProviderLRCLIB, LyricsProviderNetease},
		lyricsProviderSearchRequest{trackName: "Track", artistName: "Artist"},
		fetch,
	)
	if err != nil {
		t.Fatalf("a panicking provider must not fail the whole lookup: %v", err)
	}
	if lyrics == nil || !strings.Contains(lyrics.PlainLyrics, LyricsProviderNetease) {
		t.Fatalf("expected the surviving provider's lyrics, got %#v", lyrics)
	}
}

func TestLyricsFanOutAllProvidersPanickingReturnsError(t *testing.T) {
	clearLyricsProviderHealth()
	t.Cleanup(clearLyricsProviderHealth)

	fetch := func(string, lyricsProviderSearchRequest) (*LyricsResponse, error, bool) {
		panic("every provider exploded")
	}

	lyrics, err := fetchLyricsProviders(
		[]string{LyricsProviderLRCLIB},
		lyricsProviderSearchRequest{trackName: "Track", artistName: "Artist"},
		fetch,
	)
	if lyrics != nil {
		t.Fatalf("expected no lyrics, got %#v", lyrics)
	}
	if err == nil {
		t.Fatal("expected an error when the only provider panics")
	}
	if !strings.Contains(err.Error(), "lyrics provider") {
		t.Fatalf("error %q does not identify the lyrics provider worker", err)
	}
}
