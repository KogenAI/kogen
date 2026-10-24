package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestZshDynamicWiring(t *testing.T) {
	zsh, e := exec.LookPath("zsh")
	if e != nil {
		t.Fatal("Zsh is required for completion integration")
	}
	dir := t.TempDir()
	file := filepath.Join(dir, "_kogen")
	if e = os.WriteFile(file, []byte(zshCompletion), 0600); e != nil {
		t.Fatal(e)
	}
	// Use real Zsh evaluation and the real completion function. Capture compadd at
	// its public boundary; emulate the candidate process to check project forwarding.
	script := `compdef() { :; }
 _files() { :; }
 _directories() { print directory; }
 compadd() { if [[ $1 == -a ]]; then print -l -- "${(@P)2}"; else print -l -- "$@"; fi; }
 kogen() { print -r -- "$*" >&2; print 'fixture\tdescription'; }
 source "$1"
 words=(kogen); CURRENT=2; PREFIX=''; _kogen
 words=(kogen intent build --project '/selected checkout' fi); CURRENT=6; PREFIX=fi; _kogen
 words=(kogen intent build --project='/selected checkout' fi); CURRENT=5; PREFIX=fi; _kogen
 words=(kogen provider login ''); CURRENT=4; PREFIX=''; _kogen
 words=(kogen context --j); CURRENT=3; PREFIX=--j; _kogen
 words=(kogen context --project ''); CURRENT=4; PREFIX=''; _kogen
 `
	cmd := exec.Command(zsh, "-f", "-c", script, "fixture", file)
	out, e := cmd.CombinedOutput()
	if e != nil {
		t.Fatalf("%s: %v", out, e)
	}
	for _, want := range []string{"chatgpt", "supergrok", "opencode-go", "anthropic", "context", "fixture", "--json", "directory", "__complete build --project /selected checkout"} {
		if !strings.Contains(string(out), want) {
			t.Fatalf("missing %q in %s", want, out)
		}
	}
}

func TestCompletionHistoryTrap(t *testing.T) {
	c := factProject(t)
	root := c["root"].(string)
	for _, p := range []string{"runs", "shaping", "refinements"} {
		if e := os.Mkdir(filepath.Join(root, ".kogen/local", p), 0000); e != nil {
			t.Fatal(e)
		}
	}
	// The completion entry point only consumes its fixed catalog, not history.
	handled, code := localRead([]string{"__complete", "build", "--project", root})
	if !handled || code != 0 {
		t.Fatal(handled, code)
	}
}
