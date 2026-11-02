package main

import (
	"os"
	"regexp"
	"runtime/debug"
	"testing"
)

// componentRequire is a component module cli/go.mod requires, with its exact version.
var componentRequire = regexp.MustCompile(`(?m)^\s*(?:require\s+)?(github\.com/KogenAI/kogen-[a-z]+) (v\S+)$`)

// The program is assembled from the component modules cli/go.mod pins. This test binary is built
// from the same module and go.sum as the program, so it must contain every component at exactly
// the pinned version and unreplaced: no stale internal copy or local checkout stands in for one.
func TestAssemblyUsesThePinnedComponents(t *testing.T) {
	mod, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatal(err)
	}
	pins := map[string]string{}
	for _, m := range componentRequire.FindAllStringSubmatch(string(mod), -1) {
		pins[m[1]] = m[2]
	}
	want := []string{"github.com/KogenAI/kogen-coordinator", "github.com/KogenAI/kogen-executor",
		"github.com/KogenAI/kogen-verification", "github.com/KogenAI/kogen-shaping", "github.com/KogenAI/kogen-build"}
	for _, path := range want {
		if pins[path] == "" {
			t.Errorf("cli/go.mod does not pin %s", path)
		}
	}
	if regexp.MustCompile(`(?m)^replace github\.com/KogenAI/`).Match(mod) {
		t.Error("cli/go.mod replaces a component module")
	}
	info, ok := debug.ReadBuildInfo()
	if !ok {
		t.Fatal("no build information in the test binary")
	}
	built := map[string]*debug.Module{}
	for _, dep := range info.Deps {
		built[dep.Path] = dep
	}
	for _, path := range want {
		dep := built[path]
		switch {
		case dep == nil:
			t.Errorf("%s is not in the build", path)
		case dep.Replace != nil:
			t.Errorf("%s is replaced by %s %s", path, dep.Replace.Path, dep.Replace.Version)
		case dep.Version != pins[path]:
			t.Errorf("%s is built at %s, cli/go.mod pins %s", path, dep.Version, pins[path])
		}
	}
	// The moved packages exist only in their component modules.
	for _, dir := range []string{"agent", "build", "durable", "executor", "git", "project", "shape", "testproc", "thinking", "verify"} {
		if _, err := os.Stat(dir); err == nil {
			t.Errorf("cli/%s still exists beside the pinned component", dir)
		}
	}
}
