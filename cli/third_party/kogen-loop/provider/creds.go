package provider

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"kogen-loop/sys"
)

// credentials are one provider's saved login: the parsed JSON object, nil when no file
// exists and empty when the file cannot be read or is not a JSON object.
type credentials map[string]any

func credentialsPath(home string, p Info) string {
	return filepath.Join(home, ".kogen", "credentials", p.Name+".json")
}

func lockPath(home string, p Info) string {
	return filepath.Join(home, ".kogen", "credentials", p.Name+".lock")
}

func hostIDPath(home string) string { return filepath.Join(home, ".kogen", "host-id") }

func readCredentials(home string, p Info) credentials {
	data, err := os.ReadFile(credentialsPath(home, p))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return credentials{}
	}
	v, err := decodeJSON(data)
	if m, ok := v.(map[string]any); err == nil && ok {
		return credentials(m)
	}
	return credentials{}
}

// usable is the GPT-4 / supergrok usability rule of a saved login; for a key provider it
// is the key rule.
func (c credentials) usable(p Info) bool {
	if p.key {
		_, ok := c.apiKey(p)
		return ok
	}
	if _, ok := asInt(c["expires_at"]); !ok {
		return false
	}
	if !nonempty(c["access_token"]) || !nonempty(c["refresh_token"]) {
		return false
	}
	id, _ := c["client_id"].(string)
	switch p.Name {
	case "chatgpt":
		return len(id) > 7 && strings.HasPrefix(id, "oaiapp_")
	default:
		return id != "" && c["referrer"] == "kogen"
	}
}

func (c credentials) expiresAt() int64 {
	n, _ := asInt(c["expires_at"])
	return n
}

func emailSuffix(email any) string {
	if s, ok := email.(string); ok && s != "" {
		return " (" + s + ")"
	}
	return ""
}

func loginHint(p Info) string { return "run kogen provider login " + p.Name }

// Status is the offline `kogen provider list` output: one line per provider, in
// catalog order. It reads only Kogen's own credential files and makes no request. A provider
// whose key is optional (openai-compatible) is listed only once a key is saved: a keyless
// local host needs no login.
func Status(home string) []string {
	var lines []string
	for _, p := range Catalog() {
		c := readCredentials(home, p)
		var state string
		switch {
		case c == nil && p.optionalKey:
			continue
		case c == nil:
			state = "not signed in"
		case p.key && c.usable(p):
			state = "key saved (not verified)"
		case p.Name == "anthropic" || p.optionalKey:
			// An unusable Anthropic file reads as no login at all.
			state = "not signed in"
		case c.usable(p):
			state = "signed in" + emailSuffix(c["email"])
		default:
			state = "saved login cannot be used; " + loginHint(p)
		}
		lines = append(lines, p.Name+": "+state)
	}
	return lines
}

// RequireLogin refuses (provider/login, exit 4) before any request when a provider used by
// roles has no usable login. Only the providers the roles use are checked.
func RequireLogin(home string, roles []Role) error {
	seen := map[string]bool{}
	for _, r := range roles {
		p, ok := Lookup(r.Provider)
		if !ok || seen[p.Name] {
			continue
		}
		seen[p.Name] = true
		if err := requireStored(home, p); err != nil {
			return err
		}
	}
	return nil
}

func providerFail(reason, detail string) *sys.Error {
	return sys.Fail("provider", reason, detail, 4)
}

// requireStored refuses when the provider has no usable saved login (a key for a key provider).
// A provider whose key is optional needs none.
func requireStored(home string, p Info) error {
	if p.optionalKey {
		return nil
	}
	if p.key {
		_, err := storedKey(home, p)
		return err
	}
	_, err := storedCredentials(home, p)
	return err
}

// storedCredentials returns the usable saved login or the GPT-5 refusal.
func storedCredentials(home string, p Info) (credentials, error) {
	c := readCredentials(home, p)
	if c == nil {
		return nil, providerFail("login", "not signed in; "+loginHint(p))
	}
	if !c.usable(p) {
		return nil, providerFail("login", "saved login cannot be used; "+loginHint(p))
	}
	return c, nil
}

// privateDirs creates ~/.kogen and its credentials directory with mode 0700, whatever the umask.
func privateDirs(home string) error {
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	for _, d := range []string{filepath.Dir(dir), dir} {
		if err := os.Chmod(d, 0o700); err != nil {
			return err
		}
	}
	return nil
}

// writeCredentials replaces the provider's credentials file atomically: a private
// (0600) temporary file in a 0700 directory under a 0700 ~/.kogen, whatever the umask.
func writeCredentials(home string, p Info, c credentials) error {
	return writePrivate(home, p, c, nil)
}

// writePrivate is writeCredentials with a last look before the rename: a non-nil error from
// beforeRename (an interrupt) leaves the old file and removes the temporary one.
func writePrivate(home string, p Info, c credentials, beforeRename func() error) error {
	path := credentialsPath(home, p)
	if err := privateDirs(home); err != nil {
		return err
	}
	data, err := encodeJSON(map[string]any(c))
	if err != nil {
		return err
	}
	raw := make([]byte, 8)
	rand.Read(raw)
	tmp := path + "." + hex.EncodeToString(raw)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if err := f.Chmod(0o600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && beforeRename != nil {
		err = beforeRename()
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// hostID is the stable per-machine ext_agent_host_id, created on first use.
func hostID(home string) (string, error) {
	path := hostIDPath(home)
	data, err := os.ReadFile(path)
	if err == nil {
		return strings.TrimSpace(string(data)), nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	id := "urn:uuid:" + uuid4()
	if err := os.MkdirAll(filepath.Dir(path), 0o777); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(id+"\n"), 0o666); err != nil {
		return "", err
	}
	return id, nil
}

func uuid4() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
