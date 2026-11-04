package consumes

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// blocked is a Build that stopped on a builder-reported blocker after it wrote the candidate; the
// checkout holds the implementation the builder left. It returns the Build's id.
func (e *env) blocked(t *testing.T) string {
	t.Helper()
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "report_blocker", map[string]any{
		"paths":    []any{".kogen/intents/fixture/acceptance.feature"},
		"reason":   "The fixture requires the same value to equal A and B.",
		"evidence": "Real acceptance probe: exit status 1, fixture requires mutually exclusive B at integration_steps.js.",
	}))
	a := e.build()
	if a.err != nil || a.exit != 1 {
		t.Fatalf("exit %d, err %v\n%s", a.exit, a.err, a.out)
	}
	contains(t, "stdout", a.out.String(), "candidate/build_blocked")
	return buildID(t, a.out.String())
}

// TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation: Recover takes the project, the
// Build's id and a NEW absolute directory outside the checkout. It returns exit 0 and a nil error,
// publishes the archive there with its manifest, and restores the implementation the builder left
// while the protected files stay as they are.
func TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation(t *testing.T) {
	e := newEnv(t)
	id := e.blocked(t)
	equal(t, "app.txt before", e.read("app.txt"), "candidate\n")
	output := filepath.Join(physical(t, t.TempDir()), "archive")

	r := e.recoverBuild(id, output)
	if r.exit != 0 || r.err != nil {
		t.Fatalf("exit %d, err %v\n%s", r.exit, r.err, r.out)
	}
	if st, err := os.Stat(filepath.Join(output, "manifest.json")); err != nil || !st.Mode().IsRegular() {
		t.Fatalf("no manifest in %s: %v", output, err)
	}
	equal(t, "app.txt after", e.read("app.txt"), "baseline\n")
	equal(t, "feature", e.read(".kogen/intents/fixture/acceptance.feature"), testFeature)
	equal(t, "HEAD", len(e.gitOut("rev-parse", "HEAD")), 40)
}

// TestRecoverRefusalsAreSysErrorsWithTheirExit: a recovery that cannot proceed is a *sys.Error
// whose Exit is 1, which kogen's exitFor prints and returns whatever code Recover returned
// beside it. Nothing is written: not the archive and not the checkout.
func TestRecoverRefusalsAreSysErrorsWithTheirExit(t *testing.T) {
	cases := []struct {
		name, want string
		id         func(id string) string
		output     func(e *env) string
	}{
		{"unknown id", "candidate/recovery_unsupported: unknown checkpoint", func(string) string { return "nothex" }, nil},
		{"absent checkpoint", "candidate/recovery_unsupported: absent checkpoint", func(string) string { return "00000000" }, nil},
		{"output inside the checkout", "candidate/recovery_refused: output destination is inside checkout", nil,
			func(e *env) string { return filepath.Join(e.root, "archive") }},
		{"output exists", "candidate/recovery_refused: output destination already exists or is unsafe: ", nil,
			func(e *env) string { return e.aux }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newEnv(t)
			id := e.blocked(t)
			if c.id != nil {
				id = c.id(id)
			}
			output := filepath.Join(physical(t, t.TempDir()), "archive")
			if c.output != nil {
				output = c.output(e)
			}
			r := e.recoverBuild(id, output)
			refusal := asRefusal(t, r.err)
			if refusal.Exit != 1 || !strings.HasPrefix(refusal.Render(), c.want) {
				t.Fatalf("error %q (exit %d), want %q with exit 1", refusal.Render(), refusal.Exit, c.want)
			}
			equal(t, "app.txt", e.read("app.txt"), "candidate\n")
			if c.output == nil {
				if _, err := os.Stat(output); err == nil {
					t.Fatal("an archive was written")
				}
			}
		})
	}
}
