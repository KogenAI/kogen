package shape

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Ports test/integration/shape_context_publication_test.exs: local working-window custody
// guards every tool effect and the final publication of a Shape.

func seedPadding(f *shpFx) {
	f.write("padding.txt", strings.Repeat("discovery line\n", 2000))
	f.git("add", "padding.txt")
	f.git("commit", "-qm", "Seed custody regression")
}

func readPadding(n int) []shpStep {
	var steps []shpStep
	for i := 0; i < n; i++ {
		steps = append(steps, shpAnswer(shpCall("pad", "read_file", map[string]any{"path": "padding.txt"})))
	}
	return steps
}

func TestASnapshotDamagedByACompletedToolRefusesTheNextToolInTheSameBatch(t *testing.T) {
	parallel(t)
	marker := filepath.Join(t.TempDir(), "unsafe-tool-ran")
	custody := ""
	steps := readPadding(40)
	f := newShpFx(t, steps...)
	custody = filepath.Join(f.Root, ".kogen/local/shaping/is-even/working-context")
	seedPadding(f)
	damage := "for snapshot in '" + custody + "/'*/*-documentation.ndjson; do printf damage >> \"$snapshot\"; done"
	f.Prov.mu.Lock()
	f.Prov.seq = append(f.Prov.seq, shpAnswer(
		shpCall("custody-tool-1", "probe", map[string]any{"command": damage}),
		shpCall("custody-tool-2", "probe", map[string]any{"command": "touch '" + marker + "'"})))
	f.Prov.mu.Unlock()
	approval := f.exists(".kogen/local/approvals/is-even.json")
	head, index := f.head(), f.read(".git/index")

	exit, err := f.shape("Preserve diagnostic custody before each tool effect.")
	shpWantError(t, err, "candidate", "context_custody_invalid", "Shape working-context custody missing, changed or unsafe: ", 1)
	if exit == 0 {
		t.Fatal("a refused custody exited 0")
	}
	snapshots, _ := filepath.Glob(custody + "/*/*-documentation.ndjson")
	if len(snapshots) == 0 {
		t.Fatal("no snapshot was archived: the conversation never reset its window")
	}
	for _, s := range snapshots {
		if b, _ := os.ReadFile(s); !strings.HasSuffix(string(b), "damage") {
			t.Fatalf("snapshot %s was not damaged by the first probe", s)
		}
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a tool ran after bound snapshot custody was damaged")
	}
	if got := len(f.Prov.requests()); got != 41 {
		t.Fatalf("%d provider requests, want 41", got)
	}
	for _, p := range []string{".kogen/local/provenance/is-even/current.json", ".kogen/local/readiness/is-even.json"} {
		if f.exists(p) {
			t.Fatalf("%s was published", p)
		}
	}
	if f.exists(".kogen/local/approvals/is-even.json") != approval || f.head() != head || f.read(".git/index") != index {
		t.Fatal("approval, HEAD or index changed")
	}
}

func TestCustodyDamagedDuringFinalReadinessCannotPublishSuccessfulEvidence(t *testing.T) {
	parallel(t)
	f := newShpFx(t, readPadding(40)...)
	custody := filepath.Join(f.Root, ".kogen/local/shaping/is-even/working-context")
	script := f.read("accept.sh")
	damage := "if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then for archive in '" + custody + "/'*/*.json; do printf damage >> \"$archive\"; done; fi\n"
	f.write("accept.sh", strings.Replace(script, "if [ -f '", damage+"if [ -f '", 1))
	seedPadding(f)
	f.git("add", "-A")
	f.git("commit", "-qm", "damaging runner")
	f.Prov.mu.Lock()
	f.Prov.seq = append(f.Prov.seq, shpSubmit("c1", shpFiles()))
	f.Prov.mu.Unlock()
	head, index := f.head(), f.read(".git/index")

	exit, err := f.shape("Preserve the fixture with intact local custody.")
	shpWantError(t, err, "candidate", "context_custody_invalid", "", 1)
	if exit == 0 {
		t.Fatal("exit 0")
	}
	archives, _ := filepath.Glob(custody + "/*/*.json")
	if len(archives) == 0 {
		t.Fatal("no archive was written")
	}
	for _, a := range archives {
		if b, _ := os.ReadFile(a); !strings.HasSuffix(string(b), "damage") {
			t.Fatalf("archive %s was not damaged", a)
		}
	}
	if !regexp.MustCompile(`Shape local working-window reset .*custody .* \(\d+ s\)`).MatchString(f.Stderr.String()) {
		t.Fatalf("no reset progress line in\n%s", f.Stderr)
	}
	for _, p := range []string{".kogen/local/provenance/is-even/current.json", ".kogen/local/readiness/is-even.json"} {
		if f.exists(p) {
			t.Fatalf("%s was published", p)
		}
	}
	if f.head() != head || f.read(".git/index") != index {
		t.Fatal("HEAD or index changed")
	}
}
