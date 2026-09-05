package gobackend

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// Fuzz targets for the attack surface that is fed untrusted input at runtime:
// filenames from provider metadata, extension manifests from the community
// registry, and CUE sheets from user files. They assert *structural*
// invariants (and never panic); logic bugs belong in regular unit tests.
// Run nightly via .github/workflows/fuzz.yml.

func FuzzSanitizeFilename(f *testing.F) {
	seeds := []string{
		"",
		"Artist - Song.flac",
		"../../etc/passwd",
		`con::nul?"<>|*?.mp3`,
		"\x00\x1f\x7f control.bin",
		"é 日本И и.mp3",
		strings.Repeat("a", 400),
		"dir\\sub\\file.wav",
		"...",
		"  spaced   name  ",
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, name string) {
		out := sanitizeFilename(name)

		if strings.ContainsAny(out, `/\<>:"|?*`) {
			t.Fatalf("sanitizeFilename(%q) = %q: path/unsafe character survived", name, out)
		}
		for _, r := range out {
			if r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D {
				t.Fatalf("sanitizeFilename(%q) = %q: control rune %U survived", name, out, r)
			}
		}
		if len(out) > maxSanitizedFilenameBytes+2 {
			t.Fatalf("sanitizeFilename(%q) produced %d bytes, over the cap", name, len(out))
		}
		if !utf8.ValidString(out) {
			t.Fatalf("sanitizeFilename(%q) produced invalid UTF-8", name)
		}
	})
}

func FuzzBuildFilenameTemplate(f *testing.F) {
	metadata := `{"title":"T","artist":"A","album":"B","track":1,"year":"2026"}`
	seeds := [][2]string{
		{"{artist} - {title}", metadata},
		{"{track:2} - {title}", metadata},
		{"{date:YYYY}", metadata},
		{"{[}{]}", "{}"},
		{"{title}{title}{title}", metadata},
		{"[] () - _", metadata},
	}
	for _, seed := range seeds {
		f.Add(seed[0], seed[1])
	}

	f.Fuzz(func(t *testing.T, template string, metaJSON string) {
		// Errors are fine (malformed metadata must never reach the bridge
		// crash handler); a panic is not.
		_, err := BuildFilename(template, metaJSON)
		_ = err
	})
}

func FuzzExtensionManifest(f *testing.F) {
	seeds := []string{
		`{"name":"x","version":"1.0.0"}`,
		`{"name":"x","version":"1.0.0","permissions":{"network":["example.com"],"storage":true,"file":true,"allowHttp":true},"signedSession":{"baseUrl":"https://example.com"}}`,
		`{"name":"","version":""}`,
		`{"name":"x","version":"1","types":["metadata"],"capabilities":["rawFfmpeg"]}`,
		`{"name":123,"version":[1,2,3]}`,
		`not-json-at-all`,
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, raw string) {
		manifest, err := ParseManifest([]byte(raw))
		if err != nil || manifest == nil {
			return
		}
		// A parsed manifest must validate deterministically or error out —
		// never panic — because registry manifests are attacker-controlled.
		_ = manifest.Validate()
	})
}

func FuzzCueParsing(f *testing.F) {
	seeds := []string{
		"FILE \"album.wav\" WAVE",
		"TRACK 01 AUDIO",
		`TITLE "Unbalanced "quotes""`,
		"INDEX 01 00:00:00",
		"REM DATE 2026",
		"PREGAP 00:37:44",
		strings.Repeat("INDEX 01 12:34:56\n", 64),
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, line string) {
		key, rest := parseCueFileLine(line)
		// unquoteCue must tolerate any remnant without panicking.
		_ = unquoteCue(key)
		_ = unquoteCue(rest)
	})
}
