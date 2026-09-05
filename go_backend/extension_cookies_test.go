package gobackend

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestParseImportedCookiesNetscape(t *testing.T) {
	text := "# Netscape HTTP Cookie File\n" +
		".example.com\tTRUE\t/\tTRUE\t1893456000\tsid\tabc123\n" +
		".example.com\tFALSE\t/api\tFALSE\t0\tcsrf\t-\n" +
		"\n"
	cookies, err := parseImportedCookies(text)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(cookies) != 2 {
		t.Fatalf("want 2 cookies, got %d", len(cookies))
	}
	first := cookies[0]
	if first.Name != "sid" || first.Value != "abc123" || !first.Secure || first.Expiry != 1893456000 {
		t.Fatalf("unexpected first cookie: %+v", first)
	}
	second := cookies[1]
	if second.Path != "/api" || second.Value != "-" {
		t.Fatalf("unexpected second cookie: %+v", second)
	}
}

func TestParseImportedCookiesHostPairLines(t *testing.T) {
	cookies, err := parseImportedCookies(".cf.example.com turnstile=ok; __cf_bm=xyz\n")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(cookies) != 2 {
		t.Fatalf("want 2 cookies, got %d", len(cookies))
	}
	if cookies[0].Name != "turnstile" || cookies[0].Value != "ok" {
		t.Fatalf("unexpected cookie: %+v", cookies[0])
	}
	if cookies[1].Name != "__cf_bm" || cookies[1].Value != "xyz" {
		t.Fatalf("unexpected cookie: %+v", cookies[1])
	}
}

func TestParseImportedCookiesRejectsGarbage(t *testing.T) {
	for _, bad := range []string{
		"just-a-host-and-nothing-else",
		"sid=value without a domain",
		"short\tTRUE\t/",
	} {
		if _, err := parseImportedCookies(bad); err == nil {
			t.Errorf("expected error for %q", bad)
		}
	}
}

func TestImportedCookiesFileRoundTripAndJarSeed(t *testing.T) {
	dir := t.TempDir()
	path := importedCookiesPath(dir, "ext-test")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}

	cookies, err := parseImportedCookies(".example.com\tTRUE\t/\tTRUE\t0\tsid\tabc")
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(cookies)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	loaded, err := loadImportedCookies(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(loaded) != 1 || loaded[0].Value != "abc" {
		t.Fatalf("round trip lost data: %+v", loaded)
	}

	jar, err := newSimpleCookieJar()
	if err != nil {
		t.Fatal(err)
	}
	seedImportedCookies(jar, dir, "ext-test")

	u, _ := url.Parse("https://example.com/whatever")
	got := jar.Cookies(u)
	found := false
	for _, c := range got {
		if c.Name == "sid" && c.Value == "abc" {
			found = true
		}
	}
	if !found {
		t.Fatalf("seeded cookie not visible in jar: %v", got)
	}

	// A different extension id must see nothing.
	other, _ := newSimpleCookieJar()
	seedImportedCookies(other, dir, "other-ext")
	if len(other.Cookies(u)) != 0 {
		t.Fatal("cookie leaked across extensions")
	}
}
