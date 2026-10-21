package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiagnosticBytes(t *testing.T) {
	for _, n := range []int{1, 262143, 262144, 262145} {
		if got := validateDiagnostic([]byte(strings.Repeat("x", n))); got != (n <= 262144) {
			t.Fatalf("size %d: %v", n, got)
		}
	}
	for _, s := range []string{"", " \t\r\n\u00a0", string([]byte{255}), strings.Repeat("é", 131073)} {
		if validateDiagnostic([]byte(s)) {
			t.Fatalf("accepted invalid data")
		}
	}
	text := "  Δ🙂\r\n尾\n "
	dir := t.TempDir()
	name := filepath.Join(dir, "診断.txt")
	if err := os.WriteFile(name, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := readDiagnostic(dir, "診断.txt")
	if err != nil || got["text"] != text || got["source_path"] != name {
		t.Fatalf("%v %v", got, err)
	}
	for _, p := range []string{"absent", "."} {
		if _, err := readDiagnostic(dir, p); err == nil {
			t.Fatalf("accepted %s", p)
		}
	}
}

func TestFreshBuildContextGrammar(t *testing.T) {
	for _, args := range [][]string{
		{"intent", "build", "--context=a", "fixture", "--project=other", "--context", "b"},
		{"intent", "build", "fixture", "--project", "other", "--context=b"},
	} {
		inv, _, err := parse(args)
		if err != nil || inv.context == nil || *inv.context != "b" || inv.project != "other" {
			t.Fatalf("%+v %v", inv, err)
		}
	}
	for _, args := range [][]string{{"intent", "resume", "deadbeef"}, {"intent", "shape", "fixture", "request"}, {"intent", "refine", "fixture", strings.Repeat("a", 64), "request"}, {"intent", "approve", "fixture"}, {"init"}, {"provider", "list"}, {"provider", "login", "chatgpt"}, {"version"}, {"uninstall"}, {"help"}} {
		if _, _, err := parse(append(args, "--context=x")); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
}

func TestContextHistoryTrap(t *testing.T) {
	c := factProject(t)
	root := c["root"].(string)
	for _, p := range []string{"runs", "shaping", "refinements"} {
		if e := os.Mkdir(filepath.Join(root, ".kogen/local", p), 0000); e != nil {
			t.Fatal(e)
		}
	}
	if got := contextData(c); got["integration_state"] != "missing" {
		t.Fatal(got)
	}
}
