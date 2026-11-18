package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// runCaptured runs one invocation in this process and returns its exit code and stdout.
func runCaptured(t *testing.T, args ...string) (int, string) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = w
	root := t.TempDir()
	code := run(args, func() (string, error) { return root, nil })
	os.Stdout = stdout
	w.Close()
	out, _ := io.ReadAll(r)
	return code, string(out)
}

func TestRunRefusesBeforeAnythingStarts(t *testing.T) {
	dir := t.TempDir()
	wd, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	for _, tt := range []struct {
		args []string
		code int
		line string
	}{
		{[]string{"intent", "shape", "ab", "-"}, 2, "intent/invalid_slug: Slug must be 3 to 48 characters and use lowercase letters, digits and dashes.\n"},
		{[]string{"intent", "shape", "is-even", "-", "--project", filepath.Join(dir, "absent")}, 3, "environment/project_unavailable: " + filepath.Join(dir, "absent") + "\n"},
		{[]string{"intent", "shape", "is-even", filepath.Join(dir, "request.md")}, 2, "intent/request_unavailable: " + filepath.Join(dir, "request.md") + ": not found\n"},
		{[]string{"intent", "build", "is-even", "--context", "absent.txt"}, 2, "intent/context_unavailable: " + filepath.Join(dir, "absent.txt") + ": not found\n"},
		{[]string{"intent", "frobnicate"}, 2, "kogen intent: unknown command 'frobnicate'\n"},
	} {
		code, out := runCaptured(t, tt.args...)
		if code != tt.code || len(out) < len(tt.line) || out[:len(tt.line)] != tt.line {
			t.Errorf("kogen %v = %d %q, want %d %q", tt.args, code, out, tt.code, tt.line)
		}
	}
	t.Setenv("KOGEN_PROVIDER_URL", "https://example.com")
	code, out := runCaptured(t, "intent", "build", "is-even")
	if want := "environment/invalid_test_seam: KOGEN_PROVIDER_URL must be http://127.0.0.1:<port> or http://localhost:<port>\n"; code != 3 || out != want {
		t.Errorf("seam refusal = %d %q", code, out)
	}
}

// contextRefusal runs a build with --context file from dir and returns the exit code and stdout.
func contextRefusal(t *testing.T, dir, file string) (int, string) {
	t.Helper()
	wd, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	return runCaptured(t, "intent", "build", "is-even", "--context", file)
}

func TestBuildContextRefusalNamesAbsolutePathWhenMissing(t *testing.T) {
	dir := t.TempDir()
	code, out := contextRefusal(t, dir, "absent.txt")
	if want := "intent/context_unavailable: " + filepath.Join(dir, "absent.txt") + ": not found\n"; code != 2 || out != want {
		t.Errorf("got %d %q, want 2 %q", code, out, want)
	}
}

func TestBuildContextRefusalSaysNotARegularFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "notes"), 0o755); err != nil {
		t.Fatal(err)
	}
	code, out := contextRefusal(t, dir, "notes")
	if want := "intent/context_unavailable: " + filepath.Join(dir, "notes") + ": not a regular file\n"; code != 2 || out != want {
		t.Errorf("got %d %q, want 2 %q", code, out, want)
	}
}

func TestBuildContextRefusalStatesTheByteLimit(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "big.txt"), []byte(strings.Repeat("x", 262145)), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out := contextRefusal(t, dir, "big.txt")
	if want := "intent/context_unavailable: " + filepath.Join(dir, "big.txt") + ": larger than 262144 bytes\n"; code != 2 || out != want {
		t.Errorf("got %d %q, want 2 %q", code, out, want)
	}
}

func TestBuildContextRefusalSeparatesBlankFromInvalidUtf8(t *testing.T) {
	dir := t.TempDir()
	for _, tt := range []struct {
		name  string
		data  []byte
		cause string
	}{
		{"blank.txt", []byte(" \n\t"), "blank"},
		{"empty.txt", nil, "blank"},
		{"binary.bin", []byte{0xff, 0xfe}, "not valid UTF-8"},
	} {
		if err := os.WriteFile(filepath.Join(dir, tt.name), tt.data, 0o600); err != nil {
			t.Fatal(err)
		}
		code, out := contextRefusal(t, dir, tt.name)
		if want := "intent/context_unavailable: " + filepath.Join(dir, tt.name) + ": " + tt.cause + "\n"; code != 2 || out != want {
			t.Errorf("%s: got %d %q, want 2 %q", tt.name, code, out, want)
		}
	}
}

func TestBuildContextAcceptsFileOfExactlyTheByteLimit(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "limit.txt"), []byte(strings.Repeat("x", 262144)), 0o600); err != nil {
		t.Fatal(err)
	}
	_, out := contextRefusal(t, dir, "limit.txt")
	if strings.Contains(out, "context_unavailable") {
		t.Errorf("refused a file of exactly 262144 bytes: %q", out)
	}
}
