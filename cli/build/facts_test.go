package build

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sync"
	"testing"

	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// factsRepo is an initialized project whose Build lock is held by this process.
func factsRepo(t *testing.T) (root, lock string, cfg *project.Config) {
	t.Helper()
	root = physical(t, t.TempDir())
	cmd := exec.Command("git", "init", "-q", root)
	cmd.Env = isolatedEnv()
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
	writeFile(t, filepath.Join(root, ".kogen/project.yaml"), project.Template(), 0o644)
	cfg, err := project.LoadConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	l := git.NewLock(git.BuildLockPath(root))
	if res, err := l.Acquire(); err != nil || res.Status != git.Acquired {
		t.Fatalf("lock: %v %v", res, err)
	}
	t.Cleanup(func() { l.Release() })
	return root, git.BuildLockPath(root), cfg
}

func TestStartPublishesCoherentCustodyAndRepeatedReplacementsNeverTear(t *testing.T) {
	// ExUnit: test/integration/local_facts_test.exs: start publishes coherent custody and repeated replacements never tear
	root, lock, cfg := factsRepo(t)
	first, err := StartRun(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := startFacts(root, "fixture", first, cfg, "", ""); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, ".kogen/local/context.json")
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 300; i++ {
			b, err := os.ReadFile(path)
			if err != nil {
				t.Errorf("read %d: %v", i, err)
				return
			}
			var doc struct {
				Active    map[string]any `json:"active"`
				LastBuilt map[string]any `json:"last_built"`
			}
			if err := json.Unmarshal(b, &doc); err != nil {
				t.Errorf("read %d: torn context.json %q: %v", i, b, err)
				return
			}
			if doc.Active == nil || doc.Active["run_id"] != doc.LastBuilt["run_id"] || doc.Active["phase"] != "startup" || doc.Active["verification_pass"] != nil {
				t.Errorf("read %d: incoherent custody %v / %v", i, doc.Active, doc.LastBuilt)
				return
			}
		}
	}()
	for i := 0; i < 20; i++ {
		run, err := StartRun(root)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := startFacts(root, "fixture", run, cfg, "", ""); err != nil {
			t.Fatal(err)
		}
	}
	wg.Wait()
	var doc struct {
		Owner struct {
			Token string `json:"token"`
		} `json:"owner"`
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	_, token, held := git.LockOwner(lock)
	if !held || token == "" || token != doc.Owner.Token {
		t.Fatalf("lock token %q held %v, owner token %q", token, held, doc.Owner.Token)
	}
}

func TestADamagedCatalogCannotAbortCustodyPublicationAndInheritedEvidenceKeepsOriginalLocations(t *testing.T) {
	// ExUnit: test/integration/local_facts_test.exs: damaged catalog cannot abort custody publication; inherited evidence keeps original locations
	root, _, cfg := factsRepo(t)
	writeFile(t, filepath.Join(root, ".kogen/local/catalog.json"), "{broken", 0o644)
	original, err := StartRun(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := startFacts(root, "fixture", original, cfg, "", ""); err != nil {
		t.Fatalf("a damaged catalog aborted publication: %v", err)
	}
	resumed, err := StartRun(root)
	if err != nil {
		t.Fatal(err)
	}
	facts, err := startFacts(root, "fixture", resumed, cfg, original.ID, original.ID)
	if err != nil {
		t.Fatal(err)
	}
	b := &Attempt{State: State{
		Root: root, Run: resumed, Pass: 3,
		LastPass: &verify.Pass{N: 3, Green: true, Tree: "tree"},
		LastReview: &ReviewRecord{N: 1, Verdict: "changes", Findings: []map[string]any{
			{"path": "app.txt", "severity": "blocking", "message": "fix"}}},
		Continuation: Continuation{Stage: StageReviewVerify},
	}, facts: facts}
	facts.inherit(b, original)
	if err := facts.update(b, "reviewing", "review_blocked"); err != nil {
		t.Fatal(err)
	}
	doc := (&env{t: t, root: root}).jsonFile(filepath.Join(root, ".kogen/local/facts", resumed.ID+".json"))
	first := func(key string) map[string]any { return doc[key].([]any)[0].(map[string]any) }
	if first("verification")["path"] != original.LogPath {
		t.Fatalf("verification evidence location %v, want %s", first("verification")["path"], original.LogPath)
	}
	if first("reviews")["path"] != original.LogPath {
		t.Fatalf("review evidence location %v, want %s", first("reviews")["path"], original.LogPath)
	}
	if got := first("blockers")["paths"]; !reflect.DeepEqual(got, []any{"app.txt"}) {
		t.Fatalf("blocker paths %v", got)
	}
	eq(t, "resumed_from", doc["resumed_from"], any(original.ID))
	eq(t, "root_run", doc["root_run"], any(original.ID))
}
