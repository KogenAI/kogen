// Package testrelease supports installed-release integration tests.
package testrelease

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Release is the one release a test process packages. Tests read it and never write to it.
type Release struct {
	// Archive is the packaged release, mode 0444, outside any checkout.
	Archive string
	// Checkout is the disposable git checkout the release was packaged from. It carries an
	// uncommitted marker in docs/testing-rules.md and a read-only dist/ seeded with a copy of the
	// release and a sentinel.
	Checkout string

	archiveBytes []byte
	name         string
	dist         string
	releaseBytes []byte
	status       string
	distInfo     os.FileInfo
}

var (
	once    sync.Once
	dir     string
	shared  *Release
	failure error
)

// Shared returns the process's release, packaging it on the first call. Every test of one package
// test run, including each -count iteration, gets the same one. If packaging failed, every caller
// fails with the recorded failure.
func Shared(t *testing.T, source string) *Release {
	t.Helper()
	once.Do(func() { shared, failure = build(source) })
	if failure != nil {
		t.Fatalf("%v", failure)
	}
	return shared
}

// Cleanup removes the process's release. Call it after m.Run().
func Cleanup() {
	if dir == "" {
		return
	}
	os.Chmod(filepath.Join(dir, "checkout", "dist"), 0755)
	os.RemoveAll(dir)
}

func copySource(source, dest string) error {
	cmd := exec.Command("sh", "-c", `tar -cf - --exclude=node_modules -C "$1" LICENSE NOTICE cli packaging docs test/acceptance/fixtures/claude | tar -xf - -C "$2"`, "sh", source, dest)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("copy source: %v\n%s", err, out)
	}
	return nil
}

func run(in string, args ...string) (string, error) {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = in
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%v: %v\n%s", args, err, out)
	}
	return string(out), nil
}

func build(source string) (*Release, error) {
	var err error
	if dir, err = os.MkdirTemp("", "kogen-release-"); err != nil {
		return nil, err
	}
	r := &Release{Checkout: filepath.Join(dir, "checkout")}
	if err := os.Mkdir(r.Checkout, 0755); err != nil {
		return nil, err
	}
	if err := copySource(source, r.Checkout); err != nil {
		return nil, err
	}
	for _, args := range [][]string{
		{"git", "init", "-q"},
		{"git", "add", "."},
		{"git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"},
	} {
		if _, err := run(r.Checkout, args...); err != nil {
			return nil, err
		}
	}
	rules := filepath.Join(r.Checkout, "docs/testing-rules.md")
	b, err := os.ReadFile(rules)
	if err != nil {
		return nil, err
	}
	if err = os.WriteFile(rules, append(b, "\nCurrent source isolation marker.\n"...), 0644); err != nil {
		return nil, err
	}
	status, err := run(r.Checkout, "git", "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return nil, err
	}

	if r.Archive, err = packageFrom(r.Checkout, filepath.Join(dir, "archive")); err != nil {
		return nil, err
	}
	if got, err := run(r.Checkout, "git", "status", "--porcelain", "--untracked-files=all"); err != nil {
		return nil, err
	} else if got != status {
		return nil, fmt.Errorf("status changed: before %q after %q", status, got)
	}

	r.name = filepath.Base(r.Archive)
	if r.archiveBytes, err = os.ReadFile(r.Archive); err != nil {
		return nil, err
	}
	r.releaseBytes = r.archiveBytes
	r.dist = filepath.Join(r.Checkout, "dist")
	if err := os.Mkdir(r.dist, 0755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(r.dist, r.name), r.releaseBytes, 0644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(r.dist, "sentinel.txt"), []byte("sentinel bytes"), 0644); err != nil {
		return nil, err
	}
	if err := os.Chmod(r.dist, 0555); err != nil {
		return nil, err
	}
	if r.distInfo, err = os.Stat(r.dist); err != nil {
		return nil, err
	}
	if r.status, err = run(r.Checkout, "git", "--no-optional-locks", "status", "--porcelain", "--untracked-files=all"); err != nil {
		return nil, err
	}
	return r, nil
}

// packageFrom packages a copy of source, keeps the archive under out as a read-only file and
// requires that it carries source's docs/testing-rules.md.
func packageFrom(source, out string) (string, error) {
	work, err := os.MkdirTemp(dir, "package-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(work)
	if err := copySource(source, work); err != nil {
		return "", err
	}
	cmd := exec.Command("sh", "packaging/package.sh")
	cmd.Dir = work
	built, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("package: %v\n%s", err, built)
	}
	lines := strings.Split(strings.TrimSpace(string(built)), "\n")
	archive := lines[len(lines)-1]
	listing, err := exec.Command("tar", "-tzf", archive).Output()
	if err != nil {
		return "", err
	}
	var doc string
	for _, name := range strings.Split(string(listing), "\n") {
		if strings.HasSuffix(name, "/docs/testing-rules.md") {
			doc = name
			break
		}
	}
	actual, err := exec.Command("tar", "-xOzf", archive, doc).Output()
	if err != nil {
		return "", err
	}
	expected, err := os.ReadFile(filepath.Join(source, "docs/testing-rules.md"))
	if err != nil || !bytes.Equal(actual, expected) {
		return "", fmt.Errorf("packaged source differs: %v", err)
	}
	if err := os.Mkdir(out, 0755); err != nil {
		return "", err
	}
	data, err := os.ReadFile(archive)
	if err != nil {
		return "", err
	}
	kept := filepath.Join(out, filepath.Base(archive))
	if err := os.WriteFile(kept, data, 0444); err != nil {
		return "", err
	}
	return kept, nil
}

// CheckCheckout requires that the workflow run since Shared left the disposable checkout and the
// shared archive as they were: status unchanged, dist holding exactly the release and the
// sentinel, its mtime and both files' bytes unchanged.
func (r *Release) CheckCheckout(t *testing.T) {
	t.Helper()
	got, err := run(r.Checkout, "git", "--no-optional-locks", "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		t.Fatal(err)
	}
	if got != r.status {
		t.Fatalf("status changed: before %q after %q", r.status, got)
	}
	entries, err := os.ReadDir(r.dist)
	if err != nil || len(entries) != 2 {
		t.Fatalf("dist entries: %v %v", entries, err)
	}
	after, err := os.Stat(r.dist)
	if err != nil || !after.ModTime().Equal(r.distInfo.ModTime()) {
		t.Fatalf("dist changed during workflow: %v", err)
	}
	copied, err := os.ReadFile(filepath.Join(r.dist, r.name))
	if err != nil || !bytes.Equal(copied, r.releaseBytes) {
		t.Fatalf("release changed: %v", err)
	}
	copied, err = os.ReadFile(filepath.Join(r.dist, "sentinel.txt"))
	if err != nil || string(copied) != "sentinel bytes" {
		t.Fatalf("sentinel changed: %v", err)
	}
	copied, err = os.ReadFile(r.Archive)
	if err != nil || !bytes.Equal(copied, r.archiveBytes) {
		t.Fatalf("shared archive changed: %v", err)
	}
}
