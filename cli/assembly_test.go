package main

import (
	"debug/buildinfo"
	"os/exec"
	"path/filepath"
	"testing"

	"kogen/internal/testrelease"
)

// TestAssemblyUsesThePinnedComponents inspects the executable from the release archive,
// rather than inferring its dependencies from the test binary.
func TestAssemblyUsesThePinnedComponents(t *testing.T) {
	want := map[string]string{
		"github.com/KogenAI/kogen-coordinator":  "v0.0.0-20261103160727-e26a4d75cdcc",
		"github.com/KogenAI/kogen-verification": "v0.0.0-20261103160936-f0884fde435a",
		"github.com/KogenAI/kogen-shaping":      "v0.0.0-20261103154530-f04edcea9896",
		"github.com/KogenAI/kogen-build":        "v0.0.0-20261103154529-b9990a3d0903",
		"github.com/KogenAI/kogen-executor":     "v0.0.0-20261103153914-97892f55ed4f",
		"github.com/KogenAI/kogen-setup":        "v0.0.0-20261103140900-9316891471b5",
		"github.com/KogenAI/kogen-review":       "v0.0.0-20261103161351-e5005fa1daf8",
	}
	archive := testrelease.Package(t, repoRoot(t))
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
