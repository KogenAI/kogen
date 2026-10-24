package verify

import (
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"kogen/git"
	"kogen/project"
)

type readinessGolden struct {
	Project    string          `json:"project"`
	Head       string          `json:"head"`
	Tree       string          `json:"tree"`
	SHA256     string          `json:"sha256"`
	Baseline   []string        `json:"baseline"`
	Record     json.RawMessage `json:"record"`
	RecordText string          `json:"record_text"`
	Scenarios  []struct {
		Name   string  `json:"name"`
		Line   int     `json:"line"`
		Status string  `json:"status"`
		Detail *string `json:"detail"`
	} `json:"scenarios"`
	PackageFactsKeys []string `json:"package_facts_keys"`
}

// goldenRepo copies testdata/<name> into a new repository committed with the fixed identity
// and date testdata/gen/readiness.exs uses, so HEAD and tree equal the Elixir ones.
func goldenRepo(t *testing.T, name string) (root string, env []string) {
	t.Helper()
	root = t.TempDir()
	src := filepath.Join("testdata", name)
	err := filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		if d.IsDir() {
			return os.MkdirAll(filepath.Join(root, rel), 0o755)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(root, rel), b, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	env = testEnv("GIT_AUTHOR_DATE=2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z",
		"GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid",
		"GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.invalid")
	for _, args := range [][]string{{"init", "-q"}, {"config", "commit.gpgsign", "false"}, {"config", "core.hooksPath", t.TempDir()}, {"add", "-A"}, {"commit", "-qm", "baseline", "--no-verify"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir, cmd.Env = root, env
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	return root, env
}

func TestReadinessRecordEqualsTheElixirRecordAndReadsBack(t *testing.T) {
	var golden []readinessGolden
	readGolden(t, "readiness.json", &golden)
	if len(golden) != 2 {
		t.Fatalf("%d reference projects", len(golden))
	}
	for _, g := range golden {
		t.Run(g.Project, func(t *testing.T) {
			root, env := goldenRepo(t, g.Project)
			cfg, err := project.LoadConfig(root)
			if err != nil {
				t.Fatal(err)
			}
			s := sessionFor(root)
			s.Env = env
			r := &Readiness{Root: root, Repo: git.New(root, env), Config: cfg}
			in, err := r.inputs(s, fixtureSlug)
			if err != nil {
				t.Fatal(err)
			}
			eq(t, "head", in.head, g.Head)
			eq(t, "tree", in.tree, g.Tree)
			eq(t, "sha256", in.sha, g.SHA256)
			eqSlice(t, "baseline", in.baseline, g.Baseline)

			intent, _, err := project.CheckIntent(root, fixtureSlug, nil)
			if err != nil {
				t.Fatal(err)
			}
			expected, _ := project.ParseGherkin(string(must(os.ReadFile(filepath.Join(root, project.FeaturePath(fixtureSlug))))))
			var scenarios []ScenarioResult
			for i, e := range expected {
				result := withResult(e, g.Scenarios[i].Status, g.Scenarios[i].Detail)
				result.UnexercisedSteps = []StepRecord{}
				scenarios = append(scenarios, result)
			}
			ready := &Ready{Intent: intent, Model: intent.Model, Scenarios: scenarios, AcceptanceExit: 1,
				Baseline: in.baseline, SHA256: in.sha, Head: in.head, CandidateTree: in.tree}
			if g.Project == "readiness-full" {
				decls, err := Declarations(intent)
				if err != nil {
					t.Fatal(err)
				}
				for _, d := range decls {
					ob, err := identity(root, d)
					if err != nil {
						t.Fatal(err)
					}
					for _, c := range d.Checks {
						ob.Checks = append(ob.Checks, CheckResult{Name: c.Name, Command: c.Command, Exit: c.Exit, Output: c.Output})
					}
					ready.Feasibility = append(ready.Feasibility, ob)
				}
			}
			if err := r.RecordPass(s, fixtureSlug, ready); err != nil {
				t.Fatal(err)
			}
			path := readinessPath(root, fixtureSlug)
			got := string(must(os.ReadFile(path)))
			// Equal by value: Elixir orders the keys of small nested maps its own way.
			var expectedRecord map[string]any
			json.Unmarshal(g.Record, &expectedRecord)
			for _, scenario := range expectedRecord["scenarios"].([]any) {
				scenario.(map[string]any)["unexercised_steps"] = []any{}
			}
			sameJSON(t, "record", json.RawMessage(got), json.RawMessage(encode(expectedRecord)))
			if !strings.HasSuffix(got, "}\n") {
				t.Fatalf("a record is one JSON line: %q", got)
			}
			facts := must(os.ReadFile(filepath.Join(root, ".kogen/local/packages/fixture.json")))
			var keys map[string]any
			json.Unmarshal(facts, &keys)
			if len(keys) != len(g.PackageFactsKeys) {
				t.Fatalf("package facts = %s", facts)
			}

			// Historical records lack execution observations and are normal misses.
			os.WriteFile(path, []byte(g.RecordText), 0o644)
			if r.Cached(s, fixtureSlug) != nil {
				t.Fatal("historical metadata must miss")
			}
			os.WriteFile(path, []byte(got), 0o644)
			cached := r.Cached(s, fixtureSlug)
			if cached == nil {
				t.Fatal("the complete record is not reusable")
			}
			eq(t, "cached exit", cached.AcceptanceExit, 1)
			eq(t, "cached failures", cached.Failures(), true)
			eq(t, "cached head", cached.Head, g.Head)
			if encode(generic(cached.Scenarios)) != encode(generic(scenarios)) {
				t.Fatalf("cached scenarios differ")
			}
			if !r.Current(s, fixtureSlug, cached) {
				t.Fatal("cached evidence is current")
			}
			cmd := exec.Command("git", "commit", "--allow-empty", "-qm", "later", "--no-verify")
			cmd.Dir, cmd.Env = root, env
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("%v\n%s", err, out)
			}
			if r.Cached(s, fixtureSlug) != nil || r.Current(s, fixtureSlug, cached) {
				t.Fatal("a changed HEAD cannot acknowledge an earlier check")
			}
		})
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

var _ = strings.TrimSpace
