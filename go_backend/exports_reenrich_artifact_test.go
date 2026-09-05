package gobackend

import (
	"encoding/json"
	"testing"
)

func TestLooksLikeFilesystemArtifact(t *testing.T) {
	yes := []string{
		"cache",
		"CACHE",
		"com.android.externalstorage.documents",
		"content://com.android.documentsui/tree",
		"file:///data/user/0/cache/spill.flac",
		"raw:/storage/emulated/0/Music",
		"Music/Album",
		"primary:Download/Music",
		"primary:Music",
	}
	no := []string{
		"",
		"Discovery",
		"Blade Runner 2049: Main Title",
		"999.256", // numeric but not a bare index
		"09",      // not the bare "0"/"1" generic names
		"Daft Punk",
	}
	for _, v := range yes {
		if !looksLikeFilesystemArtifact(v) {
			t.Errorf("expected %q to be flagged as an artifact", v)
		}
	}
	for _, v := range no {
		if looksLikeFilesystemArtifact(v) {
			t.Errorf("expected %q to look like real metadata", v)
		}
	}
}

func TestIsPlaceholderTreatsArtifactsAsMissing(t *testing.T) {
	if !isPlaceholderReEnrichValue("cache") {
		t.Fatal("artifact album must count as a placeholder so search guards accept it")
	}
	if isPlaceholderReEnrichValue("Discovery") {
		t.Fatal("real album must not count as a placeholder")
	}
}

func TestReEnrichFileStripsArtifactsInPreview(t *testing.T) {
	request := map[string]any{
		"file_path":     "/tmp/whatever.flac",
		"track_name":    "cache",
		"artist_name":   "Real Artist",
		"album_name":    "primary:Music",
		"search_online": false,
		"preview_only":  true,
	}
	raw, _ := json.Marshal(request)

	resp, err := ReEnrichFile(string(raw))
	if err != nil {
		t.Fatalf("ReEnrichFile: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(resp), &out); err != nil {
		t.Fatalf("response not JSON (%q): %v", resp, err)
	}
	meta, ok := out["enriched_metadata"].(map[string]any)
	if !ok {
		t.Fatalf("missing enriched_metadata in %q", resp)
	}
	if got := meta["track_name"]; got != "" {
		t.Errorf("artifact track_name survived: %v", got)
	}
	if got := meta["album_name"]; got != "" {
		t.Errorf("artifact album_name survived: %v", got)
	}
	if got := meta["artist_name"]; got != "Real Artist" {
		t.Errorf("legit artist_name was dropped: %v", got)
	}
}
