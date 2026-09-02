package gobackend

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExtensionSettingsRejectsTraversalIDs(t *testing.T) {
	store := &ExtensionSettingsStore{
		settings: make(map[string]map[string]any),
	}
	dir := t.TempDir()
	if err := store.SetDataDir(dir); err != nil {
		t.Fatalf("SetDataDir: %v", err)
	}

	if err := store.Set("../escape", "value", "x"); err == nil {
		t.Fatal("expected traversal extension ID to be rejected")
	}
	if err := store.SetAll("../escape", map[string]any{"value": "x"}); err == nil {
		t.Fatal("expected traversal extension ID to be rejected by SetAll")
	}
	if err := store.Remove("../escape", "value"); err == nil {
		t.Fatal("expected traversal extension ID to be rejected by Remove")
	}

	escapeDir := filepath.Join(filepath.Dir(dir), "escape")
	if _, err := os.Stat(escapeDir); err == nil {
		t.Fatalf("traversal ID created a path outside the settings root: %s", escapeDir)
	}
}

func TestExtensionSettingsWriteIsAtomicAndReloadable(t *testing.T) {
	store := &ExtensionSettingsStore{
		settings: make(map[string]map[string]any),
	}
	dir := t.TempDir()
	if err := store.SetDataDir(dir); err != nil {
		t.Fatalf("SetDataDir: %v", err)
	}
	if err := store.Set("ext-a", "quality", "lossless"); err != nil {
		t.Fatalf("Set: %v", err)
	}

	reloaded := &ExtensionSettingsStore{
		settings: make(map[string]map[string]any),
	}
	if err := reloaded.SetDataDir(dir); err != nil {
		t.Fatalf("SetDataDir(reload): %v", err)
	}
	got := reloaded.GetAll("ext-a")
	if got["quality"] != "lossless" {
		t.Fatalf("reloaded settings = %#v", got)
	}
}

func TestAddAllowedDownloadDirDeduplicates(t *testing.T) {
	SetAllowedDownloadDirs(nil)
	defer SetAllowedDownloadDirs(nil)

	AddAllowedDownloadDir("/tmp/downloads-a")
	AddAllowedDownloadDir("/tmp/downloads-a")
	AddAllowedDownloadDir("/tmp/downloads-a/")

	allowedDownloadDirsMu.RLock()
	count := len(allowedDownloadDirs)
	allowedDownloadDirsMu.RUnlock()
	if count != 1 {
		t.Fatalf("expected deduplicated allow-list, got %d entries", count)
	}
}
