package tools

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// wantSnapshot is the snapshot the delivered tool outputs make: list_files, then read_file
// of each shown name.
func wantSnapshot(t *testing.T, tl *Tools, shown ...string) string {
	t.Helper()
	list, err := tl.Run(ListFilesTool, map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	b.WriteString(SnapshotHeader + "\n\nlist_files:\n" + list.Cut().Text)
	for _, name := range shown {
		out, err := tl.Run(ReadFileTool, map[string]any{"path": name})
		if err != nil {
			t.Fatal(err)
		}
		b.WriteString("\n\nread_file " + strconv.Quote(name) + ":\n" + out.Cut().Text)
	}
	return b.String()
}

func TestSnapshotIsTheDeliveredToolOutputs(t *testing.T) {
	t.Parallel()
	_, root := newRepo(t)
	write(t, root, "café notes.md", "note\n")
	write(t, root, "empty.txt", "")
	write(t, root, "src/main.go", "package main\n\nfunc main() {}")
	write(t, root, ".gitignore", "build/\n")
	write(t, root, "build/out.txt", "ignored\n")
	commitAll(t, root)
	write(t, root, "untracked.txt", "new\n")
	tl := newTools(root, ReadFileTool, ListFilesTool)
	want := wantSnapshot(t, tl, "untracked.txt", ".gitignore", "café notes.md", "empty.txt", "src/main.go")
	if got := tl.Snapshot(); got != want {
		t.Fatalf("snapshot\n%q\nwant\n%q", got, want)
	}
	if !strings.Contains(want, "\"caf\\303\\251 notes.md\"") || strings.Contains(want, "build/out.txt") {
		t.Fatalf("listing: %q", want)
	}
}

func TestSnapshotListsOnlyWhatReadFileCannotShow(t *testing.T) {
	t.Parallel()
	base, root := newRepo(t)
	write(t, root, "small.txt", "small\n")
	write(t, root, "exact.txt", strings.Repeat("x", 4096))
	write(t, root, "lines.txt", strings.Repeat("\n", 4096))
	write(t, root, "over.txt", strings.Repeat("x", 4097))
	write(t, root, "binary.dat", "a\x00b")
	write(t, root, "latin1.txt", "caf\xe9\n")
	write(t, root, "gone.txt", "gone\n")
	write(t, root, "target.txt", "target\n")
	write(t, root, "pipe", "p\n")
	if err := os.WriteFile(filepath.Join(base, "secret.txt"), []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("target.txt", filepath.Join(root, "link.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../secret.txt", filepath.Join(root, "outside.txt")); err != nil {
		t.Fatal(err)
	}
	gitIn(t, root, "add", "-A")
	if err := os.Remove(filepath.Join(root, "pipe")); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(root, "pipe"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "gone.txt")); err != nil {
		t.Fatal(err)
	}
	tl := newTools(root, ReadFileTool, ListFilesTool)
	done := make(chan string, 1)
	go func() { done <- tl.Snapshot() }()
	var got string
	select {
	case got = <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Snapshot waits on the FIFO")
	}
	want := wantSnapshot(t, tl, "exact.txt", "lines.txt", "link.txt", "small.txt", "target.txt")
	if got != want {
		t.Fatalf("snapshot\n%q\nwant\n%q", got, want)
	}
	for _, name := range []string{"binary.dat", "gone.txt", "latin1.txt", "outside.txt", "over.txt", "pipe"} {
		if !strings.Contains(got, "\n"+name+"\n") && !strings.HasSuffix(got, "\n"+name) || strings.Contains(got, "read_file \""+name+"\"") {
			t.Errorf("%s is not listed only", name)
		}
	}
}

func TestSnapshotBounds(t *testing.T) {
	t.Parallel()
	paths := func(n int) *Tools {
		_, root := newRepo(t)
		for i := range n {
			write(t, root, fmt.Sprintf("f%02d.txt", i), "x\n")
		}
		return newTools(root, ReadFileTool, ListFilesTool)
	}
	if got := paths(64).Snapshot(); got == "" {
		t.Error("64 paths: no snapshot")
	}
	if got := paths(65).Snapshot(); got != "" {
		t.Errorf("65 paths: %q", got)
	}
	bytes := func(extra int) *Tools {
		_, root := newRepo(t)
		for i := range 8 {
			write(t, root, fmt.Sprintf("k%d.txt", i), strings.Repeat("k", 4096))
		}
		write(t, root, "big.txt", strings.Repeat("b", 5000)) // listed only: not counted
		if extra > 0 {
			write(t, root, "k8.txt", strings.Repeat("k", extra))
		}
		return newTools(root, ReadFileTool, ListFilesTool)
	}
	if got := bytes(0).Snapshot(); got == "" {
		t.Error("32768 shown bytes: no snapshot")
	}
	if got := bytes(1).Snapshot(); got != "" {
		t.Errorf("32769 shown bytes: %q", got)
	}
}

func TestSnapshotNeedsBothToolsAndANonEmptyRepository(t *testing.T) {
	t.Parallel()
	_, root := newRepo(t)
	if got := newTools(root, ReadFileTool, ListFilesTool).Snapshot(); got != "" {
		t.Errorf("empty repository: %q", got)
	}
	write(t, root, "a.txt", "a\n")
	if got := newTools(root, ReadFileTool, ListFilesTool).Snapshot(); got == "" {
		t.Error("no snapshot")
	}
	for _, enabled := range [][]string{{ReadFileTool, ShellTool}, {ListFilesTool, ShellTool}} {
		if got := newTools(root, enabled...).Snapshot(); got != "" {
			t.Errorf("%v: %q", enabled, got)
		}
	}
	plain := t.TempDir()
	write(t, plain, "a.txt", "a\n")
	if got := newTools(plain, ReadFileTool, ListFilesTool).Snapshot(); got != "" {
		t.Errorf("not a repository: %q", got)
	}
}
