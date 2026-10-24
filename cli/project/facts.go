package project

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	kgit "kogen/git"
)

// CheckoutFacts identifies one checkout: the physical work tree root, the physical Git
// directory and an opaque id (docs/checkout-facts.md). A linked worktree has its own Git
// directory and so its own id.
type CheckoutFacts struct {
	Root   string `json:"root"`
	GitDir string `json:"git_dir"`
	ID     string `json:"id"`
}

// Checkout returns the facts of the checkout at root: the root and Git directory with
// every symbolic link resolved, and the id, the lowercase hex SHA-256 of the physical Git
// directory's path.
func Checkout(root string) (CheckoutFacts, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return CheckoutFacts{}, err
	}
	physical, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return CheckoutFacts{}, fmt.Errorf("checkout %s: %w", root, err)
	}
	dir, err := kgit.New(physical, nil).GitDir()
	if err != nil {
		return CheckoutFacts{}, fmt.Errorf("checkout %s: %w", root, err)
	}
	gitDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return CheckoutFacts{}, fmt.Errorf("checkout %s: %w", root, err)
	}
	return CheckoutFacts{Root: physical, GitDir: gitDir, ID: checkoutID(gitDir)}, nil
}

func checkoutID(gitDir string) string {
	sum := sha256.Sum256([]byte(gitDir))
	return hex.EncodeToString(sum[:])
}

// OwnerFacts names the process that holds a Build lock: its pid, its start time as `ps`
// prints it and the lock's owner token (nil when no lock is held).
type OwnerFacts struct {
	PID   int     `json:"pid"`
	Birth string  `json:"birth"`
	Token *string `json:"token"`
}

// Owner describes this process as the owner of the Build lock whose unique token is
// token; an empty token records no lock. The birth is `ps -p <pid> -o lstart=`, which
// together with the pid tells a live owner from a reused pid.
func Owner(token string) (OwnerFacts, error) {
	pid := os.Getpid()
	out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "lstart=").Output()
	if err != nil {
		return OwnerFacts{}, fmt.Errorf("ps -p %d: %w", pid, err)
	}
	o := OwnerFacts{PID: pid, Birth: strings.TrimSpace(string(out))}
	if token != "" {
		o.Token = &token
	}
	return o, nil
}

// packageFacts is `.kogen/local/packages/<slug>.json`.
type packageFacts struct {
	CheckoutID   string   `json:"checkout_id"`
	Paths        []string `json:"paths"`
	SHA256       string   `json:"sha256"`
	PackageState string   `json:"package_state"`
}

// WritePackageFacts records the Intent package's retained static identity in
// `.kogen/local/packages/<slug>.json`, replacing the file atomically: the checkout id, the
// sorted baseline paths, their approval hash and `valid` or `invalid` for whether the
// Intent passes its check. It is read for listing; it never grants approval.
func WritePackageFacts(root, slug string, cfg *Config) error {
	paths, err := Baseline(root, slug, cfg)
	if err != nil {
		return err
	}
	paths = slices.Clone(paths)
	slices.Sort(paths)
	checkout, err := Checkout(root)
	if err != nil {
		return err
	}
	state := "valid"
	if _, _, err := CheckIntent(root, slug, nil); err != nil {
		state = "invalid"
	}
	dir := filepath.Join(root, ".kogen/local/packages")
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return err
	}
	return WriteJSONAtomic(filepath.Join(dir, slug+".json"), packageFacts{
		CheckoutID:   checkout.ID,
		Paths:        paths,
		SHA256:       Hash(root, paths),
		PackageState: state,
	})
}

// WriteJSONAtomic writes the JSON of v and a newline to path.tmp and renames it over path, so
// a reader sees the old file or the new one, never a torn one. It is how every
// `.kogen/local` record is written.
func WriteJSONAtomic(path string, v any) error {
	b, err := EncodeJSON(v)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o666); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// EncodeJSON is the compact JSON Kogen's local records use: object keys in byte order, strings
// escaped only for `"`, `\` and control characters, integers and numbers carried as
// json.Number verbatim. Values are nil, bool, string, json.Number, integers, []string, []any,
// map[string]any, map[string]string, []map[string]any, or anything encoding/json can encode
// to those (structs with tags). A string that is not valid UTF-8 is an error.
func EncodeJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := writeJSON(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func writeJSON(b *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(x))
	case string:
		return writeJSONString(b, x)
	case json.Number:
		b.WriteString(string(x))
	case int:
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case []string:
		b.WriteByte('[')
		for i, s := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeJSONString(b, s); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case []any:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeJSON(b, e); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case []map[string]any:
		items := make([]any, len(x))
		for i, m := range x {
			items[i] = m
		}
		return writeJSON(b, items)
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		slices.Sort(keys)
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeJSONString(b, k); err != nil {
				return err
			}
			b.WriteByte(':')
			if err := writeJSON(b, x[k]); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	case map[string]string:
		m := make(map[string]any, len(x))
		for k, s := range x {
			m[k] = s
		}
		return writeJSON(b, m)
	default:
		raw, err := json.Marshal(v)
		if err != nil {
			return err
		}
		norm, err := decodeJSON(raw)
		if err != nil {
			return err
		}
		return writeJSON(b, norm)
	}
	return nil
}

func writeJSONString(b *bytes.Buffer, s string) error {
	if !utf8.ValidString(s) {
		return fmt.Errorf("JSON string is not valid UTF-8: %q", s)
	}
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c == '\b':
			b.WriteString(`\b`)
		case c == '\f':
			b.WriteString(`\f`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20:
			fmt.Fprintf(b, `\u%04X`, c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return nil
}

// decodeJSON parses one JSON value, keeping numbers as json.Number so that re-encoding
// does not change them.
func decodeJSON(data []byte) (any, error) {
	if !json.Valid(data) {
		return nil, fmt.Errorf("invalid JSON")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return v, nil
}
