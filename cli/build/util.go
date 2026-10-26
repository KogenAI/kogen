package build

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"

	"kogen-loop/provider"
	"kogen/project"
)

func itoa(n int) string { return strconv.Itoa(n) }

func readFile(root, rel string) ([]byte, error) { return os.ReadFile(filepath.Join(root, rel)) }

func decodeBase64(s string) ([]byte, error) { return base64.StdEncoding.DecodeString(s) }

func encodeBase64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func jsonUnmarshal(data []byte, v any) error { return json.Unmarshal(data, v) }

// providerRole is a configured role as the provider needs it.
func providerRole(r project.Role) provider.Role {
	return provider.Role{Provider: r.Provider, Model: r.Model, Effort: r.Effort, BaseURL: r.BaseURL}
}

// shellQuote quotes s for /bin/sh.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// short is the first 8 characters of a hash.
func short(s string) string { return s[:min(8, len(s))] }

// fileDigest is the SHA-256 of a file, or "missing".
func fileDigest(root, rel string) string {
	b, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		return "missing"
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// inspectStrings renders a list of strings the way Elixir's inspect/1 does.
func inspectStrings(list []string) string {
	parts := make([]string, len(list))
	for i, s := range list {
		parts[i] = inspectString(s)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func inspectString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	rs := []rune(s)
	for i, r := range rs {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == 0x1b:
			b.WriteString(`\e`)
		case r == 7:
			b.WriteString(`\a`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r == '\v':
			b.WriteString(`\v`)
		case r == 0:
			b.WriteString(`\0`)
		case r == '#' && i+1 < len(rs) && rs[i+1] == '{':
			b.WriteString(`\#`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02X`, r)
		case !unicode.IsPrint(r):
			fmt.Fprintf(&b, `\u%04X`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// decodeJSONNumbers decodes one JSON value keeping numbers as json.Number.
func decodeJSONNumbers(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, fmt.Errorf("trailing data")
	}
	return v, nil
}

// display is a JSON scalar as text, the way string interpolation shows it (nil is empty).
func display(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case json.Number:
		return x.String()
	case float64:
		if x == float64(int64(x)) {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'g', -1, 64)
	}
	return fmt.Sprint(v)
}
