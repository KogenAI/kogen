package consumes

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
)

// redWhile adds a project check that fails while the flag file exists, the way kogen-build's own
// recover test does: the builder's blocker claim must rest on a failing verification pass.
func redWhile(flag string) func(*project.Config) {
	return func(cfg *project.Config) {
		cfg.Checks = append(cfg.Checks, project.Check{Name: "contradiction",
			Run: "[ ! -e '" + flag + "' ] || { echo 'cannot pass: .kogen/intents/fixture/acceptance.feature' >&2; exit 1; }"})
	}
}

// blocked is a Build that stopped on a builder-reported blocker after it wrote the candidate; the
// checkout holds the implementation the builder left. In the first round the builder writes the
// candidate and raises the flag that turns the redWhile check red, so verification fails; in the
// next round it reports the blocker. It returns the Build's id.
func (e *env) blocked(t *testing.T, flag string) string {
	t.Helper()
	f := e.prov
	f.then(
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"},
			"shell", map[string]any{"command": "touch '" + flag + "'"},
			"finish", map[string]any{"summary": "done"}),
		f.calls("report_blocker", map[string]any{
			"paths":    []any{".kogen/intents/fixture/acceptance.feature"},
			"reason":   "The fixture requires the same value to equal A and B.",
			"evidence": "Real acceptance probe: exit status 1, fixture requires mutually exclusive B at integration_steps.js.",
		}))
	a := e.build()
	if a.err != nil || a.exit != 1 {
		t.Fatalf("exit %d, err %v\n%s", a.exit, a.err, a.out)
	}
	contains(t, "stdout", a.out.String(), "candidate/build_blocked")
	if err := os.Remove(flag); err != nil {
		t.Fatal(err)
	}
	return buildID(t, a.out.String())
}

// TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation: Recover takes the project, the
// Build's id and a NEW absolute directory outside the checkout. It returns exit 0 and a nil error,
// publishes the archive there with its manifest, and restores the implementation the builder left
// while the protected files stay as they are.
func TestRecoverArchivesTheBlockedBuildAndClearsTheImplementation(t *testing.T) {
	flag := filepath.Join(physical(t, t.TempDir()), "red")
	e := newEnv(t, redWhile(flag))
	id := e.blocked(t, flag)
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
		prepare    func(t *testing.T, e *env, id string)
	}{
		{"unknown id", "candidate/recovery_unsupported: \"nothex\" is not a Build id; a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d; kogen intent list lists Build attempts",
			func(string) string { return "nothex" }, nil, nil},
		{"no recorded Build", "candidate/recovery_unsupported: Build 00000000: no Build with this id in this checkout; kogen intent list lists Build attempts",
			func(string) string { return "00000000" }, nil, nil},
		{"absent checkpoint", "candidate/recovery_unsupported: unknown checkpoint: absent checkpoint", nil, nil,
			func(t *testing.T, e *env, id string) {
				if err := os.Remove(filepath.Join(e.root, ".kogen", "local", "runs", id, "checkpoint.json")); err != nil {
					t.Fatal(err)
				}
			}},
		{"output inside the checkout", "candidate/recovery_refused: output destination is inside checkout", nil,
			func(e *env) string { return filepath.Join(e.root, "archive") }, nil},
		{"output exists", "candidate/recovery_refused: output destination already exists or is unsafe: ", nil,
			func(e *env) string { return e.aux }, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			flag := filepath.Join(physical(t, t.TempDir()), "red")
			e := newEnv(t, redWhile(flag))
			id := e.blocked(t, flag)
			if c.prepare != nil {
				c.prepare(t, e, id)
			}
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
