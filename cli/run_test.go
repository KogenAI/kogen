package main

import (
	"io"
	"os"
	"path/filepath"
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
		{[]string{"intent", "build", "is-even", "--context", "absent.txt"}, 2, "intent/context_unavailable: file must be readable and regular\n"},
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
