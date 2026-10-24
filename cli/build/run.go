// Package build is `kogen intent build` and `kogen intent resume`: the Build lock, approval
// and baseline custody, the builder conversation, verification, the review hook, the verified
// commit, run records (`.kogen/local/runs/<id>`), local facts and checkpoints (chapters
// 03-07, 09).
package build

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

// Run is a Build's run record (LOOP-10): `.kogen/local/runs/<id>/log.jsonl` with requests and
// usage, tool-call byte counts and hashes, verification passes, reviews and the outcome;
// `result.json`; `review-<n>.json`; the checkpoint. Credentials never appear in it.
type Run struct {
	ID      string `json:"id"`
	Dir     string `json:"dir"`
	LogPath string `json:"log"`

	mu     sync.Mutex
	logErr error
}

// isoTime is the timestamp format of run records: UTC with microseconds.
func isoTime(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000000Z") }

// StartRun creates a new run folder (0700) with a fresh 8-hex id under root.
func StartRun(root string) (*Run, error) {
	runs := filepath.Join(root, ".kogen/local/runs")
	if err := os.MkdirAll(runs, 0o777); err != nil {
		return nil, err
	}
	for attempt := 0; attempt < 100; attempt++ {
		var raw [4]byte
		if _, err := rand.Read(raw[:]); err != nil {
			return nil, err
		}
		id := hex.EncodeToString(raw[:])
		dir := filepath.Join(runs, id)
		err := os.Mkdir(dir, 0o777)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return nil, err
		}
		return &Run{ID: id, Dir: dir, LogPath: filepath.Join(dir, "log.jsonl")}, nil
	}
	return nil, errors.New("no free run id")
}

// encodeJSON is the JSON of v without HTML escaping and without the final newline.
func encodeJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

// Event appends one event to the run log, stamped with the time (`at`). A write failure is
// kept and reported by the next checkpoint.
func (r *Run) Event(event map[string]any) {
	if r == nil {
		return
	}
	line := make(map[string]any, len(event)+1)
	for k, v := range event {
		line[k] = v
	}
	line["at"] = isoTime(time.Now())
	b, err := encodeJSON(line)
	r.mu.Lock()
	defer r.mu.Unlock()
	if err == nil {
		var f *os.File
		if f, err = os.OpenFile(r.LogPath, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o666); err == nil {
			_, err = f.Write(append(b, '\n'))
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}
	}
	if err != nil && r.logErr == nil {
		r.logErr = fmt.Errorf("run log %s: %w", r.LogPath, err)
	}
}

// Log implements verify.Logger.
func (r *Run) Log(event map[string]any) { r.Event(event) }

// takeLogErr returns and clears the first run log write failure.
func (r *Run) takeLogErr() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	err := r.logErr
	r.logErr = nil
	return err
}

// Write writes `name` in the run folder as JSON and a newline.
func (r *Run) Write(name string, data any) error {
	b, err := encodeJSON(data)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(r.Dir, name), append(b, '\n'), 0o666)
}

// PublishCheckpoint publishes a complete checkpoint by same-directory atomic rename: a
// private (0600) temporary file, synced, then renamed over `checkpoint.json`.
func (r *Run) PublishCheckpoint(doc any) error {
	b, err := encodeJSON(doc)
	if err != nil {
		return err
	}
	path := filepath.Join(r.Dir, "checkpoint.json")
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	werr := func() error {
		if err := f.Chmod(0o600); err != nil {
			return err
		}
		if _, err := f.Write(append(b, '\n')); err != nil {
			return err
		}
		return f.Sync()
	}()
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		os.Remove(tmp)
		return werr
	}
	return os.Rename(tmp, path)
}

const logLimit = 1 << 20

// Cap is command output as recorded in the run log: at most 1 MiB with the middle cut out.
func Cap(text string) string {
	if len(text) <= logLimit {
		return text
	}
	const marker = "\n[... cut in the run log ...]\n"
	size := (logLimit - len(marker)) / 2
	return validPrefix(text[:size]) + marker + validSuffix(text[len(text)-size:])
}

func validPrefix(s string) string {
	for !validUTF8(s) {
		s = s[:len(s)-1]
	}
	return s
}

func validSuffix(s string) string {
	for !validUTF8(s) {
		s = s[1:]
	}
	return s
}

// fileMode is the permission bits of a file, or false when it cannot be inspected.
func fileMode(path string) (fs.FileMode, fs.FileMode, bool) {
	st, err := os.Lstat(path)
	if err != nil {
		return 0, 0, false
	}
	return st.Mode().Type(), st.Mode().Perm(), true
}

// fileIdentity is `root:device:inode`, the identity of a checkout's folder.
func fileIdentity(root string) (string, error) {
	st, err := os.Stat(root)
	if err != nil {
		return "", err
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return "", errors.New("no device identity")
	}
	return fmt.Sprintf("%s:%d:%d", root, uint64(sys.Dev), uint64(sys.Ino)), nil
}

func validUTF8(s string) bool { return utf8.ValidString(s) }
