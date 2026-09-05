package gobackend

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// User-imported session cookies for extensions.
//
// Some community download sources sit behind Cloudflare-style challenges or
// require a logged-in session; browsers hold the working cookies, and users
// can export them (Netscape cookies.txt is the universal format — browser
// extensions and curl --cookie-jar all emit it). This is an *opt-in import*:
// the app never reads browser stores directly, and imported cookies live only
// in the extension's own sandbox data directory with 0600 permissions.
//
// Imported cookies are merged into the extension's cookie jar at runtime
// creation, so a seeded session survives app restarts until the user clears
// it (or the extension itself calls httpClearCookies).

const importedCookiesFileName = "imported_cookies.json"

type importedCookie struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Domain string `json:"domain"`
	Path   string `json:"path,omitempty"`
	Secure bool   `json:"secure,omitempty"`
	Expiry int64  `json:"expiry,omitempty"` // unix seconds; 0 = session cookie
}

// parseImportedCookies accepts two shapes, one cookie per line:
//
//	# Netscape cookies.txt (7 tab-separated fields)
//	.example.com	TRUE	/	TRUE	1893456000	name	value
//
//	# or a host-prefixed pair list: ".example.com sid=abc csrf=def"
//
// Blank lines and lines starting with # are ignored.
func parseImportedCookies(text string) ([]importedCookie, error) {
	var out []importedCookie

	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	for i, rawLine := range lines {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		lineNumber := i + 1

		if strings.Contains(line, "\t") {
			fields := strings.Split(line, "\t")
			if len(fields) < 7 {
				return nil, fmt.Errorf("line %d: Netscape cookies.txt lines need 7 tab-separated fields, got %d", lineNumber, len(fields))
			}
			domain := strings.TrimSpace(fields[0])
			path := strings.TrimSpace(fields[2])
			secure := strings.EqualFold(strings.TrimSpace(fields[3]), "TRUE")
			var expiry int64
			if exp := strings.TrimSpace(fields[4]); exp != "" && exp != "0" {
				if parsed, err := strconv.ParseInt(exp, 10, 64); err == nil {
					expiry = parsed
				}
			}
			name := strings.TrimSpace(fields[5])
			value := strings.Join(fields[6:], "\t")
			if domain == "" || name == "" {
				return nil, fmt.Errorf("line %d: empty domain or cookie name", lineNumber)
			}
			if path == "" {
				path = "/"
			}
			out = append(out, importedCookie{
				Name: name, Value: value, Domain: domain, Path: path,
				Secure: secure, Expiry: expiry,
			})
			continue
		}

		tokens := strings.Fields(line)
		if strings.Contains(tokens[0], "=") {
			return nil, fmt.Errorf("line %d: cookie needs a domain — paste cookies.txt content, or start the line with the host", lineNumber)
		}
		domain := tokens[0]
		pairs := tokens[1:]
		if len(pairs) == 0 {
			return nil, fmt.Errorf("line %d: no NAME=VALUE pairs after host %q", lineNumber, domain)
		}
		for _, pair := range pairs {
			name, value, ok := strings.Cut(strings.TrimSuffix(pair, ";"), "=")
			if !ok || name == "" {
				return nil, fmt.Errorf("line %d: expected NAME=VALUE pairs", lineNumber)
			}
			out = append(out, importedCookie{
				Name: name, Value: value, Domain: domain, Path: "/",
			})
		}
	}

	return out, nil
}

func (c importedCookie) cookieDomainURL() (*url.URL, error) {
	host := strings.TrimPrefix(c.Domain, ".")
	if host == "" {
		return nil, fmt.Errorf("cookie %q has an empty domain", c.Name)
	}
	// The jar matches on domain/path, not scheme; https is the safe base.
	return url.Parse("https://" + host + c.Path)
}

func (c importedCookie) toHTTPCookie() *http.Cookie {
	cookie := &http.Cookie{
		Name:   c.Name,
		Value:  c.Value,
		Domain: c.Domain,
		Path:   c.Path,
		Secure: c.Secure,
	}
	if cookie.Path == "" {
		cookie.Path = "/"
	}
	if c.Expiry > 0 {
		cookie.Expires = time.Unix(c.Expiry, 0)
	}
	return cookie
}

func importedCookiesPath(dataDir, extensionID string) string {
	return filepath.Join(dataDir, extensionID, importedCookiesFileName)
}

func seedImportedCookies(jar http.CookieJar, dataDir, extensionID string) {
	if jar == nil {
		return
	}
	cookies, err := loadImportedCookies(importedCookiesPath(dataDir, extensionID))
	if err != nil || len(cookies) == 0 {
		return
	}
	applyImportedCookies(jar, cookies)
}

func loadImportedCookies(path string) ([]importedCookie, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cookies []importedCookie
	if err := json.Unmarshal(data, &cookies); err != nil {
		return nil, err
	}
	return cookies, nil
}

func applyImportedCookies(jar http.CookieJar, cookies []importedCookie) {
	byHost := map[string][]*http.Cookie{}
	for _, c := range cookies {
		u, err := c.cookieDomainURL()
		if err != nil {
			continue
		}
		byHost[u.Host] = append(byHost[u.Host], c.toHTTPCookie())
	}
	for host := range byHost {
		u, err := url.Parse("https://" + host)
		if err != nil {
			continue
		}
		jar.SetCookies(u, byHost[host])
	}
}

// SetExtensionImportedCookies parses cookiesText (Netscape cookies.txt or
// "host NAME=VALUE" lines), persists it inside the extension's data dir, and
// merges it into the live cookie jar. Returns JSON {"count": n, "names": []}.
// The cookie *values* are never echoed back to the UI.
func SetExtensionImportedCookies(extensionID string, cookiesText string) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeOut, bridgeErr = "", r
		}
	}()

	ext, err := getExtensionManager().GetExtension(extensionID)
	if err != nil {
		return "", fmt.Errorf("extension %q is not installed", extensionID)
	}

	cookies, err := parseImportedCookies(cookiesText)
	if err != nil {
		return "", err
	}

	path := importedCookiesPath(ext.DataDir, ext.ID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	data, err := json.Marshal(cookies)
	if err != nil {
		return "", err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}

	if ext.runtime != nil {
		applyImportedCookies(ext.runtime.cookieJar, cookies)
	}

	out, _ := json.Marshal(importedCookiesSummary(cookies))
	return string(out), nil
}

// GetExtensionImportedCookiesInfo reports the stored import without values.
func GetExtensionImportedCookiesInfo(extensionID string) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeOut, bridgeErr = "", r
		}
	}()

	ext, err := getExtensionManager().GetExtension(extensionID)
	if err != nil {
		return "", fmt.Errorf("extension %q is not installed", extensionID)
	}

	cookies, err := loadImportedCookies(importedCookiesPath(ext.DataDir, ext.ID))
	if err != nil {
		if os.IsNotExist(err) {
			out, _ := json.Marshal(importedCookiesSummary(nil))
			return string(out), nil
		}
		return "", err
	}

	out, _ := json.Marshal(importedCookiesSummary(cookies))
	return string(out), nil
}

// ClearExtensionImportedCookies removes the stored import and the live jar so
// the extension starts from a clean session.
func ClearExtensionImportedCookies(extensionID string) (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	ext, err := getExtensionManager().GetExtension(extensionID)
	if err != nil {
		return fmt.Errorf("extension %q is not installed", extensionID)
	}
	_ = os.Remove(importedCookiesPath(ext.DataDir, ext.ID))
	if ext.runtime != nil {
		if jar, ok := ext.runtime.cookieJar.(*simpleCookieJar); ok {
			jar.Clear()
		}
	}
	return nil
}

func importedCookiesSummary(cookies []importedCookie) map[string]any {
	names := make([]string, 0, len(cookies))
	for _, c := range cookies {
		names = append(names, c.Name)
	}
	sort.Strings(names)
	return map[string]any{"count": len(cookies), "names": names}
}
