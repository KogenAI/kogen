// Package testrelease supports installed-release integration tests.
package testrelease

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func Copy(t *testing.T, source string) string {
	t.Helper()
	dest := t.TempDir()
	cmd := exec.Command("sh", "-c", `tar -cf - --exclude=node_modules -C "$1" LICENSE NOTICE cli packaging docs test/acceptance/fixtures/claude | tar -xf - -C "$2"`, "sh", source, dest)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("copy source: %v\n%s", err, out)
	}
	return dest
}
func Package(t *testing.T, source string, args ...string) string {
	t.Helper()
	copy := Copy(t, source)
	cmd := exec.Command("sh", append([]string{"packaging/package.sh"}, args...)...)
	cmd.Dir = copy
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("package: %v\n%s", err, out)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	archive := lines[len(lines)-1]
	listing, err := exec.Command("tar", "-tzf", archive).Output()
	if err != nil {
		t.Fatal(err)
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
		t.Fatal(err)
	}
	expected, err := os.ReadFile(filepath.Join(source, "docs/testing-rules.md"))
	if err != nil || !bytes.Equal(actual, expected) {
		t.Fatalf("packaged source differs: %v", err)
	}
	return archive
}
func Fixture(t *testing.T, source string) (string, func()) {
	t.Helper()
	root := Copy(t, source)
	run := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Dir = root
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%v: %v\n%s", args, err, out)
		}
		return string(out)
	}
	run("git", "init", "-q")
	run("git", "add", ".")
	run("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
	f := filepath.Join(root, "docs/testing-rules.md")
	b, err := os.ReadFile(f)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(f, append(b, "\nCurrent source isolation marker.\n"...), 0644); err != nil {
		t.Fatal(err)
	}
	dist := filepath.Join(root, "dist")
	if err := os.Mkdir(dist, 0755); err != nil {
		t.Fatal(err)
	}
	release := Package(t, root)
	releaseBytes, err := os.ReadFile(release)
	if err != nil {
		t.Fatal(err)
	}
	name := filepath.Base(release)
	if err := os.WriteFile(filepath.Join(dist, name), releaseBytes, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dist, "sentinel.txt"), []byte("sentinel bytes"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dist, 0555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dist, 0755) })
	before, err := os.Stat(dist)
	if err != nil {
		t.Fatal(err)
	}

	status := run("git", "status", "--porcelain", "--untracked-files=all")
	return root, func() {
		t.Helper()
		if got := run("git", "status", "--porcelain", "--untracked-files=all"); got != status {
			t.Fatalf("status changed: before %q after %q", status, got)
		}
		entries, err := os.ReadDir(dist)
		if err != nil || len(entries) != 2 {
			t.Fatalf("dist entries: %v %v", entries, err)
		}
		after, err := os.Stat(dist)
		if err != nil || !after.ModTime().Equal(before.ModTime()) {
			t.Fatalf("dist changed during workflow: %v", err)
		}
		got, err := os.ReadFile(filepath.Join(dist, name))
		if err != nil || !bytes.Equal(got, releaseBytes) {
			t.Fatalf("release changed: %v", err)
		}
		got, err = os.ReadFile(filepath.Join(dist, "sentinel.txt"))
		if err != nil || string(got) != "sentinel bytes" {
			t.Fatalf("sentinel changed: %v", err)
		}
	}
}
