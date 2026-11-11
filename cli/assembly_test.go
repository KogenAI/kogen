package main

import (
	"debug/buildinfo"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"testing"

	"kogen/internal/testrelease"
)

// TestAssemblyUsesThePinnedComponents inspects the executable from the release archive,
// rather than inferring its dependencies from the test binary.
// It catches a release executable with unpinned or replaced components.
func TestAssemblyUsesThePinnedComponents(t *testing.T) {
	t.Parallel()
	want := map[string]string{
		"github.com/KogenAI/kogen-coordinator":  "",
		"github.com/KogenAI/kogen-verification": "",
		"github.com/KogenAI/kogen-shaping":      "",
		"github.com/KogenAI/kogen-build":        "",
		"github.com/KogenAI/kogen-executor":     "",
		"github.com/KogenAI/kogen-setup":        "",
		"github.com/KogenAI/kogen-review":       "",
	}
	// Read require and replace declarations from the source manifest, before packaging.
	manifest := filepath.Join(repoRoot(t), "cli", "go.mod")
	out, err := exec.Command("go", "mod", "edit", "-json", manifest).CombinedOutput()
	if err != nil {
		t.Fatalf("read manifest: %v\n%s", err, out)
	}
	var mod struct {
		Require []struct{ Path, Version string }
		Replace []struct {
			Old struct{ Path, Version string }
		}
	}
	if err := json.Unmarshal(out, &mod); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	for _, req := range mod.Require {
		if _, ok := want[req.Path]; ok {
			want[req.Path] = req.Version
		}
	}
	for _, replacement := range mod.Replace {
		if _, ok := want[replacement.Old.Path]; ok {
			t.Errorf("%s replaced in manifest", replacement.Old.Path)
		}
	}
	for path, version := range want {
		if version == "" {
			t.Errorf("%s missing from manifest require declarations", path)
		}
	}
	archive := testrelease.Shared(t, repoRoot(t)).Archive
	dir := t.TempDir()
	if out, err := exec.Command("tar", "-xzf", archive, "-C", dir).CombinedOutput(); err != nil {
		t.Fatalf("extract: %v\n%s", err, out)
	}
	binaries, err := filepath.Glob(filepath.Join(dir, "*", "bin", "kogen"))
	if err != nil || len(binaries) != 1 {
		t.Fatalf("packaged binaries %v: %v", binaries, err)
	}
	info, err := buildinfo.ReadFile(binaries[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, dep := range info.Deps {
		if version, ok := want[dep.Path]; ok {
			if dep.Version != version || dep.Replace != nil {
				t.Errorf("%s: version %s replacement %v, want %s unreplaced", dep.Path, dep.Version, dep.Replace, version)
			}
			delete(want, dep.Path)
		}
	}
	for path := range want {
		t.Errorf("%s missing from packaged executable", path)
	}
}
