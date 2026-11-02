package claudecode

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestPinTable(t *testing.T) {
	if Version != "2.1.312" {
		t.Fatalf("version %q", Version)
	}
	for goos, want := range map[string]pin{
		"darwin/arm64": {"darwin-arm64", "6b5ec691195e551b02c41df9f7d723f4ea61eaa03c2df90acefe3736f1aeb620", 275988512},
		"linux/amd64":  {"linux-x64", "4f4178ce41d83e23341ebfbaecdbcf8ea6bf7baea0690025abe49eeec3a5d01d", 293592432},
	} {
		parts := strings.Split(goos, "/")
		if got, ok := pinFor(parts[0], parts[1]); !ok || got != want {
			t.Errorf("%s: %+v %v", goos, got, ok)
		}
	}
	for _, p := range [][2]string{{"darwin", "amd64"}, {"linux", "arm64"}, {"windows", "amd64"}, {"freebsd", "amd64"}} {
		if _, ok := pinFor(p[0], p[1]); ok {
			t.Errorf("%s/%s is supported", p[0], p[1])
		}
	}
	if got, want := UnsupportedMessage("windows", "amd64"), "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64"; got != want {
		t.Errorf("message %q", got)
	}
	if got := RuntimePath("/h"); got != "/h/.kogen/claude-code/2.1.312/claude" {
		t.Errorf("path %q", got)
	}
}

func TestUnsupportedPlatformStopsTheRole(t *testing.T) {
	t.Setenv(SeamEnv, "http://127.0.0.1:1")
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	o := h.f.options()
	a := New(o).(*adapter)
	a.goos, a.goarch = "windows", "amd64"
	_, err := a.Start(context.Background(), h.task, nil)
	if e := wantError(t, err, "executor/unavailable"); e.Detail != UnsupportedMessage("windows", "amd64") {
		t.Fatalf("detail %q", e.Detail)
	}
}

func TestSeamIsLoopbackOnly(t *testing.T) {
	for _, ok := range []string{"http://127.0.0.1:8080", "http://localhost:1"} {
		t.Setenv(SeamEnv, ok)
		if origin, set, err := seamOrigin(); err != nil || !set || origin != ok {
			t.Errorf("%s: %q %v %v", ok, origin, set, err)
		}
	}
	for _, bad := range []string{"", "https://127.0.0.1:8080", "http://example.com:80", "http://127.0.0.1", "http://localhost:80/x", "http://127.0.0.1:80/"} {
		t.Setenv(SeamEnv, bad)
		_, _, err := seamOrigin()
		wantError(t, err, "executor/unavailable")
		if !strings.Contains(err.Error(), SeamEnv+" must be http://127.0.0.1:<port> or http://localhost:<port>") {
			t.Errorf("%q: %v", bad, err)
		}
	}
	t.Setenv(SeamEnv, "https://example.com")
	home := t.TempDir()
	a := installer(home, nil)
	wantError(t, a.ensureRuntime(context.Background()), "executor/unavailable")
	if _, err := os.Lstat(RuntimeDir(home)); err == nil {
		t.Fatal("something was installed")
	}
}

// installer is an adapter on a fixed supported platform, so the tests run on any host.
func installer(home string, stderr *bytes.Buffer) *adapter {
	o := Options{Home: home, Stderr: io.Discard}
	if stderr != nil {
		o.Stderr = stderr
	}
	a := New(o).(*adapter)
	a.goos, a.goarch = "linux", "amd64"
	return a
}

func sum(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

// seam serves the official manifest shape and the runtime of linux-x64, and counts requests.
type seam struct {
	*httptest.Server
	mu        sync.Mutex
	requests  []string
	downloads atomic.Int32
}

func newSeam(t *testing.T, binary []byte, checksum string, serve func(w http.ResponseWriter, r *http.Request, binary []byte)) *seam {
	t.Helper()
	s := &seam{}
	if checksum == "" {
		checksum = sum(binary)
	}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.requests = append(s.requests, r.URL.Path)
		s.mu.Unlock()
		switch r.URL.Path {
		case "/2.1.312/manifest.json":
			fmt.Fprintf(w, `{"version":"2.1.312","platforms":{"linux-x64":{"binary":"claude","checksum":%q,"size":%d}}}`, checksum, len(binary))
		case "/2.1.312/linux-x64/claude":
			s.downloads.Add(1)
			if serve != nil {
				serve(w, r, binary)
				return
			}
			w.Header().Set("Content-Length", fmt.Sprint(len(binary)))
			w.Write(binary)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	t.Setenv(SeamEnv, s.URL)
	return s
}

// script is a runtime that logs every start to log and answers --version.
func script(version, log string) []byte {
	return []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + log + "'\necho '" + version + "'\n")
}

func entries(t *testing.T, dir string) []string {
	t.Helper()
	list, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range list {
		names = append(names, e.Name())
	}
	return names
}

func TestInstallsThePinnedRuntime(t *testing.T) {
	log := filepath.Join(t.TempDir(), "runs")
	binary := script("2.1.312 (Claude Code)", log)
	s := newSeam(t, binary, "", nil)
	home := t.TempDir()
	var stderr bytes.Buffer
	if err := installer(home, &stderr).ensureRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := "kogen: installing Claude Code 2.1.312 into " + RuntimeDir(home) + "\nkogen: installed Claude Code 2.1.312 (sha256 " + sum(binary) + ")\n"
	if stderr.String() != want {
		t.Fatalf("progress %q, want %q", stderr.String(), want)
	}
	got, err := os.ReadFile(RuntimePath(home))
	if err != nil || !bytes.Equal(got, binary) {
		t.Fatalf("installed bytes: %v", err)
	}
	for path, mode := range map[string]os.FileMode{RuntimePath(home): 0o755, RuntimeDir(home): 0o700, Root(home): 0o700, ConfigDir(home): 0o700} {
		if st, err := os.Stat(path); err != nil || st.Mode().Perm() != mode {
			t.Errorf("%s: %v %v", path, st, err)
		}
	}
	if names := entries(t, Root(home)); strings.Join(names, " ") != "2.1.312 config install.lock" {
		t.Fatalf("entries %v", names)
	}
	// Only the verification ran the downloaded bytes, from the partial directory.
	runs, _ := os.ReadFile(log)
	if string(runs) != "--version\n" || s.downloads.Load() != 1 {
		t.Fatalf("runs %q downloads %d", runs, s.downloads.Load())
	}
	// A second role start finds the runtime and asks nothing.
	if err := installer(home, &stderr).ensureRuntime(context.Background()); err != nil || s.downloads.Load() != 1 || len(s.requests) != 2 {
		t.Fatalf("second start: %v, requests %v", err, s.requests)
	}
}

func TestInstallRefusals(t *testing.T) {
	log := filepath.Join(t.TempDir(), "runs")
	good := script("2.1.312 (Claude Code)", log)
	cases := []struct {
		name   string
		binary []byte
		sum    string
		serve  func(http.ResponseWriter, *http.Request, []byte)
		want   string
		ran    bool
	}{
		{"digest mismatch", good, sum([]byte("other")), nil, "the downloaded Claude Code 2.1.312 does not match its pinned SHA-256; nothing was installed", false},
		{"size mismatch", good, "", func(w http.ResponseWriter, r *http.Request, b []byte) { w.Write(append(append([]byte{}, b...), '#')) }, "the downloaded Claude Code 2.1.312 does not match its pinned SHA-256; nothing was installed", false},
		{"another version", script("2.1.314 (Claude Code)", log), "", nil, "the downloaded Claude Code reports 2.1.314 (Claude Code), not 2.1.312; nothing was installed", true},
		{"not found", good, "", func(w http.ResponseWriter, r *http.Request, b []byte) { http.NotFound(w, r) }, "cannot download Claude Code 2.1.312 from %s/2.1.312/linux-x64/claude: HTTP 404 Not Found", false},
		{"dropped connection", good, "", func(w http.ResponseWriter, r *http.Request, b []byte) {
			w.Header().Set("Content-Length", fmt.Sprint(len(b)))
			w.Write(b[:len(b)/2])
			w.(http.Flusher).Flush()
			panic(http.ErrAbortHandler)
		}, "cannot download Claude Code 2.1.312 from %s/2.1.312/linux-x64/claude: ", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			os.Remove(log)
			s := newSeam(t, c.binary, c.sum, c.serve)
			home := t.TempDir()
			// A leftover of an interrupted installation is removed by the next installation.
			leftover := filepath.Join(Root(home), ".partial-killed")
			if err := os.MkdirAll(leftover, 0o700); err != nil {
				t.Fatal(err)
			}
			err := installer(home, nil).ensureRuntime(context.Background())
			e := wantError(t, err, "executor/unavailable")
			if want := strings.Replace(c.want, "%s", s.URL, 1); !strings.HasPrefix(e.Detail, want) || (c.name != "dropped connection" && e.Detail != want) {
				t.Fatalf("detail %q, want %q", e.Detail, want)
			}
			if names := entries(t, Root(home)); strings.Join(names, " ") != "config install.lock" {
				t.Fatalf("entries %v", names)
			}
			if _, err := os.Stat(log); c.ran != (err == nil) {
				t.Fatalf("downloaded bytes ran = %v, want %v", err == nil, c.ran)
			}
		})
	}
}

func TestNextInstallRecoversAfterAFailure(t *testing.T) {
	log := filepath.Join(t.TempDir(), "runs")
	binary := script("2.1.312 (Claude Code)", log)
	var fail atomic.Bool
	fail.Store(true)
	s := newSeam(t, binary, "", func(w http.ResponseWriter, r *http.Request, b []byte) {
		if fail.Load() {
			http.Error(w, "down", http.StatusBadGateway)
			return
		}
		w.Write(b)
	})
	home := t.TempDir()
	wantError(t, installer(home, nil).ensureRuntime(context.Background()), "executor/unavailable")
	fail.Store(false)
	if err := installer(home, nil).ensureRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s.downloads.Load() != 2 {
		t.Fatalf("downloads %d", s.downloads.Load())
	}
	if _, err := os.Stat(RuntimePath(home)); err != nil {
		t.Fatal(err)
	}
}

func TestConcurrentInstallationsSerialize(t *testing.T) {
	log := filepath.Join(t.TempDir(), "runs")
	binary := script("2.1.312 (Claude Code)", log)
	release := make(chan struct{})
	s := newSeam(t, binary, "", func(w http.ResponseWriter, r *http.Request, b []byte) {
		<-release
		w.Write(b)
	})
	home := t.TempDir()
	errs := make(chan error, 2)
	for range 2 {
		go func() { errs <- installer(home, nil).ensureRuntime(context.Background()) }()
	}
	deadline := time.Now().Add(5 * time.Second)
	for s.downloads.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("no installation started")
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(300 * time.Millisecond)
	if n := s.downloads.Load(); n != 1 {
		t.Fatalf("%d downloads while the first installation holds the lock", n)
	}
	close(release)
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if n := s.downloads.Load(); n != 1 {
		t.Fatalf("%d downloads, want 1", n)
	}
}

func TestWaitingForTheLockEndsWithTheContext(t *testing.T) {
	s := newSeam(t, script("2.1.312 (Claude Code)", filepath.Join(t.TempDir(), "runs")), "", nil)
	home := t.TempDir()
	if err := os.MkdirAll(Root(home), 0o700); err != nil {
		t.Fatal(err)
	}
	held, err := lockInstall(context.Background(), filepath.Join(Root(home), "install.lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	wantError(t, installer(home, nil).ensureRuntime(ctx), "executor/deadline")
	if len(s.requests) != 0 {
		t.Fatalf("requests %v", s.requests)
	}
}

func TestInstalledRuntimeIsNeverReplaced(t *testing.T) {
	s := newSeam(t, script("2.1.312 (Claude Code)", filepath.Join(t.TempDir(), "runs")), "", nil)
	home := t.TempDir()
	if err := os.MkdirAll(RuntimeDir(home), 0o700); err != nil {
		t.Fatal(err)
	}
	other := script("2.1.314 (Claude Code)", filepath.Join(t.TempDir(), "runs"))
	if err := os.WriteFile(RuntimePath(home), other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := installer(home, nil).ensureRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(RuntimePath(home))
	if !bytes.Equal(got, other) || len(s.requests) != 0 {
		t.Fatalf("replaced or downloaded: %v", s.requests)
	}
}

func TestOlderVersionDirectoryIsUntouched(t *testing.T) {
	newSeam(t, script("2.1.312 (Claude Code)", filepath.Join(t.TempDir(), "runs")), "", nil)
	home := t.TempDir()
	old := filepath.Join(Root(home), "2.1.300", "claude")
	if err := os.MkdirAll(filepath.Dir(old), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(old, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := installer(home, nil).ensureRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(old); err != nil || string(b) != "old" {
		t.Fatalf("older runtime changed: %q %v", b, err)
	}
}
