package build

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

func TestSatisfiedRebuildAlreadyPresent(t *testing.T)        { satisfiedRebuild(t, false) }
func TestSatisfiedRebuildPreservesStagedIntent(t *testing.T) { satisfiedRebuild(t, true) }

func satisfiedRebuild(t *testing.T, staged bool) {
	marker := filepath.Join(t.TempDir(), "checks")
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "fixture-check", Run: "grep -qx candidate app.txt && echo check >> '" + marker + "'"}}
	})
	// Acceptance checks the already-implemented output as well as producing the report.
	accept := filepath.Join(e.aux, "accept.sh")
	body, err := os.ReadFile(accept)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, accept, strings.Replace(string(body), "if grep -qx red", "grep -qx candidate app.txt || exit 1\nif grep -qx red", 1), 0o755)
	// An outside change implements the output before this package is freshly approved.
	if err := os.Remove(project.ApprovalPath(e.root, testSlug)); err != nil {
		t.Fatal(err)
	}
	e.write("app.txt", "candidate\n")
	e.run("git", "add", ".")
	e.run("git", "commit", "-qm", "outside implementation")
	bin := buildKogen(t)
	cfg, err := project.LoadConfig(e.root)
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := project.Baseline(e.root, testSlug, cfg)
	if err != nil {
		t.Fatal(err)
	}
	code, out := e.cli(bin, "intent", "approve", testSlug, project.Hash(e.root, baseline))
	if code != 0 {
		t.Fatalf("approve exit %d: %s", code, out)
	}
	if err := os.Remove(marker); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if staged {
		e.stageOtherIntent()
	}
	head, tree, count, index := e.head(), e.gitOut("rev-parse", "HEAD^{tree}"), e.gitOut("rev-list", "--count", "HEAD"), e.state()["index"]
	stagedIndex := e.gitOut("ls-files", "--stage")
	e.credentials()
	f := e.prov
	f.then(f.calls("finish", map[string]any{"summary": "already implemented"}), submit(f, "approve"))
	code, out = e.cli(bin, "intent", "build", testSlug)
	if code != 0 {
		t.Fatalf("build exit %d: %s", code, out)
	}
	contains(t, "build", out, "already present")
	eq(t, "head", e.head(), head)
	eq(t, "tree", e.gitOut("rev-parse", "HEAD^{tree}"), tree)
	eq(t, "commit count", e.gitOut("rev-list", "--count", "HEAD"), count)
	eq(t, "index bytes", e.state()["index"], index)
	eq(t, "index entries", e.gitOut("ls-files", "--stage"), stagedIndex)
	if staged {
		eq(t, "staged file", e.read(".kogen/intents/staged/draft.md"), "caller staged this Intent\n")
		eq(t, "staged paths", e.staged(), ".kogen/intents/staged/draft.md")
		eq(t, "staged blob", e.gitOut("show", ":.kogen/intents/staged/draft.md"), "caller staged this Intent")
	} else {
		eq(t, "clean", e.gitOut("status", "--porcelain"), "")
	}
	if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); !os.IsNotExist(err) {
		t.Fatal("approval not consumed")
	}
	id := e.onlyRun()
	result := e.result(id)
	eq(t, "outcome", result["outcome"], any("already_present"))
	eq(t, "existing HEAD", result["commit"], any(head))
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	contains(t, "verification", jsonText(facts["verification"]), `"green":true`)
	contains(t, "review", jsonText(facts["reviews"]), `"verdict":"approve"`)
	if len(f.reviewRequests()) != 1 {
		t.Fatalf("review requests: %d", len(f.reviewRequests()))
	}
	cp := e.jsonFile(filepath.Join(e.root, ".kogen/local/runs", id, "checkpoint.json"))
	state := cp["state"].(map[string]any)
	pass := state["last_pass"].(map[string]any)
	review := state["last_review"].(map[string]any)
	eq(t, "verified tree", pass["tree"], any(tree))
	eq(t, "reviewed tree", review["tree"], any(tree))
	eq(t, "review verdict", review["verdict"], any("approve"))
	if pass["acceptance"] == nil || pass["acceptance"] == "not_run" {
		t.Fatal("acceptance not run")
	}
	contains(t, "executed check", jsonText(pass["checks"]), "fixture-check")
	contains(t, "acceptance", jsonText(e.events(id)), "acceptance")
	checks, err := os.ReadFile(marker)
	if err != nil || len(checks) == 0 {
		t.Fatalf("checks not executed: %s %v", checks, err)
	}
	code, out = e.cli(bin, "intent", "resume", id)
	if code != 0 {
		t.Fatalf("resume exit %d: %s", code, out)
	}
	contains(t, "resume", out, "already present")
	for _, args := range [][]string{{"intent", "inspect", id}, {"intent", "inspect", id, "--json"}, {"intent", "list"}, {"intent", "list", "--json"}, {"context"}} {
		code, out := e.cli(bin, args...)
		if code != 0 {
			t.Fatalf("%v exit %d: %s", args, code, out)
		}
		if args[0] == "intent" && args[1] == "inspect" {
			contains(t, "inspect", out, "already_present")
		}
		if args[0] == "intent" && args[1] == "list" {
			contains(t, "list", out, "absent")
		}
		if args[0] == "context" {
			contains(t, "context", out, id)
		}
		if strings.Contains(out, "uncertain commit boundary") || strings.Contains(out, "commit_failed") || strings.Contains(out, "approval current") {
			t.Fatalf("%v: %s", args, out)
		}
	}
}
