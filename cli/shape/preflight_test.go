package shape

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
)

const preflightLimitationText = "Setup, checks, hooks, providers, tool availability, signing and full readiness/resume safety were not executed or established. Build revalidates normally."

func (f *approveFx) preflight(slug string, jsonMode bool) (int, string) {
	f.t.Helper()
	s, out, errOut := f.session()
	in := PreflightInput{Project: f.Root, Slug: slug, JSON: jsonMode}
	if jsonMode {
		c, err := project.Checkout(f.Root)
		if err != nil {
			f.t.Fatal(err)
		}
		in.Checkout = c
	}
	exit, err := Preflight(context.Background(), s, in)
	if err != nil {
		f.t.Fatal(err)
	}
	if errOut.String() != "" {
		f.t.Fatalf("stderr %q", errOut.String())
	}
	return exit, out.String()
}

func (f *approveFx) preflightJSON(slug string) (int, map[string]any) {
	f.t.Helper()
	exit, out := f.preflight(slug, true)
	var doc map[string]any
	if err := json.Unmarshal([]byte(out), &doc); err != nil || strings.Count(out, "\n") != 1 {
		f.t.Fatalf("not one JSON line: %q (%v)", out, err)
	}
	return exit, doc
}

func (f *approveFx) approved() {
	f.t.Helper()
	if exit, _, err := f.approve(ApproveInput{Hash: f.sha()[:8]}); err != nil || exit != 0 {
		f.t.Fatalf("approve: exit %d, err %v", exit, err)
	}
}

func preflightChecks(t *testing.T, doc map[string]any) map[string]string {
	t.Helper()
	data := doc["data"].(map[string]any)
	got := map[string]string{}
	for _, c := range data["checks"].([]any) {
		c := c.(map[string]any)
		got[c["name"].(string)] = c["status"].(string)
	}
	return got
}

func preflightBlockers(doc map[string]any) []map[string]any {
	var out []map[string]any
	for _, b := range doc["data"].(map[string]any)["blockers"].([]any) {
		out = append(out, b.(map[string]any))
	}
	return out
}

func TestPreflightReadyTextAndJSON(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	f.approved()

	exit, out := f.preflight(approveSlug, false)
	want := "preflight fixture: ready (observations only)\n" +
		"  configuration: passed\n  package: passed\n  approval: passed\n  cleanliness: passed\n  conflict: passed\n" +
		"  " + preflightLimitationText + "\n"
	if exit != 0 || out != want {
		t.Fatalf("exit %d, text:\n%s\nwant:\n%s", exit, out, want)
	}

	exit, doc := f.preflightJSON(approveSlug)
	checkout, _ := project.Checkout(f.Root)
	wantDoc := map[string]any{
		"schema_version": float64(1),
		"kind":           "preflight",
		"checkout":       map[string]any{"root": checkout.Root, "git_dir": checkout.GitDir, "id": checkout.ID},
		"error":          nil,
		"data": map[string]any{
			"slug":  "fixture",
			"ready": true,
			"checks": []any{
				map[string]any{"name": "configuration", "status": "passed"},
				map[string]any{"name": "package", "status": "passed"},
				map[string]any{"name": "approval", "status": "passed"},
				map[string]any{"name": "cleanliness", "status": "passed"},
				map[string]any{"name": "conflict", "status": "passed"},
			},
			"blockers":    []any{},
			"limitations": []any{preflightLimitationText},
		},
	}
	if exit != 0 || !reflect.DeepEqual(doc, wantDoc) {
		t.Fatalf("exit %d, JSON %v\nwant %v", exit, doc, wantDoc)
	}
}

func TestPreflightJSONDefaultsCheckoutFromProject(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	s, out, _ := f.session()
	if _, err := Preflight(context.Background(), s, PreflightInput{Project: f.Root, Slug: approveSlug, JSON: true}); err != nil {
		t.Fatal(err)
	}
	checkout, _ := project.Checkout(f.Root)
	var doc struct{ Checkout project.CheckoutFacts }
	if err := json.Unmarshal([]byte(out.String()), &doc); err != nil || doc.Checkout != checkout {
		t.Fatalf("checkout %v (%v)", doc.Checkout, err)
	}
}

func TestPreflightBlockedWithoutApproval(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	approval := filepath.Join(f.Root, ".kogen/local/approvals/fixture.json")

	exit, out := f.preflight(approveSlug, false)
	want := "preflight fixture: blocked\n" +
		"  configuration: passed\n  package: passed\n  approval: blocked\n  cleanliness: passed\n  conflict: passed\n" +
		"  intent/approval_changed: exact current approval is absent or changed\n    " + approval + "\n" +
		"  " + preflightLimitationText + "\n"
	if exit != 1 || out != want {
		t.Fatalf("exit %d, text:\n%s", exit, out)
	}

	exit, doc := f.preflightJSON(approveSlug)
	bl := preflightBlockers(doc)
	if exit != 1 || doc["data"].(map[string]any)["ready"] != false || len(bl) != 1 ||
		!reflect.DeepEqual(bl[0], map[string]any{"class": "intent", "reason": "approval_changed",
			"detail": "exact current approval is absent or changed", "paths": []any{approval}}) {
		t.Fatalf("exit %d, JSON %v", exit, doc)
	}
}

func TestPreflightStaleAndMalformedApproval(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	f.approved()
	f.write("features/steps/fixture_steps.js", "// changed after approval\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "change")
	exit, doc := f.preflightJSON(approveSlug)
	if bl := preflightBlockers(doc); exit != 1 || len(bl) != 1 || bl[0]["reason"] != "approval_changed" {
		t.Fatalf("changed baseline: exit %d, %v", exit, doc)
	}
	for _, broken := range []string{"{broken", "[1,2]", ""} {
		f.write(".kogen/local/approvals/fixture.json", broken)
		exit, doc = f.preflightJSON(approveSlug)
		if bl := preflightBlockers(doc); exit != 1 || len(bl) != 1 || bl[0]["reason"] != "approval_changed" {
			t.Fatalf("approval %q: exit %d, %v", broken, exit, doc)
		}
	}
}

func TestPreflightMissingPackage(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	exit, doc := f.preflightJSON("missing")
	checks := preflightChecks(t, doc)
	if exit != 1 || doc["error"] != nil || doc["data"].(map[string]any)["ready"] != false {
		t.Fatalf("exit %d, %v", exit, doc)
	}
	if checks["cleanliness"] != "not_evaluated" || checks["package"] != "blocked" || checks["approval"] != "blocked" {
		t.Fatalf("checks %v", checks)
	}
	bl := preflightBlockers(doc)
	if bl[0]["reason"] != "invalid_package" || bl[0]["detail"] != "intent.md does not exist" ||
		!reflect.DeepEqual(bl[0]["paths"], []any{".kogen/intents/missing/intent.md", ".kogen/intents/missing/acceptance.feature"}) {
		t.Fatalf("blockers %v", bl)
	}
	_, text := f.preflight("missing", false)
	if !strings.Contains(text, "  intent/invalid_package: intent.md does not exist\n    .kogen/intents/missing/intent.md\n    .kogen/intents/missing/acceptance.feature\n") ||
		!strings.Contains(text, "  cleanliness: not_evaluated\n") {
		t.Fatalf("text:\n%s", text)
	}
}

func TestPreflightInvalidPackageJoinsProblems(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	f.write(project.FeaturePath(approveSlug), "Feature: Empty\n")
	_, doc := f.preflightJSON(approveSlug)
	var package_ map[string]any
	for _, b := range preflightBlockers(doc) {
		if b["reason"] == "invalid_package" {
			package_ = b
		}
	}
	_, _, err := project.CheckIntent(f.Root, approveSlug, nil)
	e, _ := sys.AsError(err)
	if package_ == nil || e == nil || package_["detail"] != strings.Join(e.Lines, "; ") || len(e.Lines) == 0 {
		t.Fatalf("blockers %v (check: %v)", preflightBlockers(doc), err)
	}
}

func TestPreflightDirtyTree(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	f.approved()
	f.write("stray.txt", "x\n")
	f.write(".kogen/intents/other/draft.md", "another Intent's draft\n") // allowed
	f.write(".kogen/intents/fixture/notes.md", "own folder\n")           // allowed (changes the baseline)
	exit, doc := f.preflightJSON(approveSlug)
	var dirty map[string]any
	for _, b := range preflightBlockers(doc) {
		if b["reason"] == "dirty_tree" {
			dirty = b
		}
	}
	if exit != 1 || dirty == nil || dirty["class"] != "environment" ||
		dirty["detail"] != "1 changed path(s) are not part of an Intent; commit, stash or discard them first" ||
		!reflect.DeepEqual(dirty["paths"], []any{"stray.txt"}) {
		t.Fatalf("exit %d, %v", exit, doc)
	}
	_, text := f.preflight(approveSlug, false)
	if !strings.Contains(text, "  cleanliness: blocked\n") ||
		!strings.Contains(text, "  environment/dirty_tree: 1 changed path(s) are not part of an Intent; commit, stash or discard them first\n    stray.txt\n") {
		t.Fatalf("text:\n%s", text)
	}
}

func TestPreflightDirtyTreeListsAtMostTwentyPaths(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	for i := 0; i < 25; i++ {
		f.write("stray/"+string(rune('a'+i))+".txt", "x\n")
	}
	_, doc := f.preflightJSON(approveSlug)
	for _, b := range preflightBlockers(doc) {
		if b["reason"] == "dirty_tree" {
			if b["detail"] != "25 changed path(s) are not part of an Intent; commit, stash or discard them first" || len(b["paths"].([]any)) != 20 {
				t.Fatalf("blocker %v", b)
			}
			return
		}
	}
	t.Fatal("no dirty_tree blocker")
}

func TestPreflightConflicts(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	f.approved()

	lock := git.NewLock(git.BuildLockPath(f.Root))
	if _, err := lock.Acquire(); err != nil {
		t.Fatal(err)
	}
	exit, doc := f.preflightJSON(approveSlug)
	bl := preflightBlockers(doc)
	if exit != 1 || len(bl) != 1 || bl[0]["reason"] != "build_running" || bl[0]["detail"] != "a Build owns this checkout" || preflightChecks(t, doc)["conflict"] != "blocked" {
		t.Fatalf("lock: exit %d, %v", exit, doc)
	}
	lock.Release()
	if exit, _ := f.preflightJSON(approveSlug); exit != 0 {
		t.Fatalf("released lock: exit %d", exit)
	}

	if err := os.WriteFile(filepath.Join(f.Root, ".git/MERGE_HEAD"), []byte(f.git("rev-parse", "HEAD")), 0o644); err != nil {
		t.Fatal(err)
	}
	exit, doc = f.preflightJSON(approveSlug)
	bl = preflightBlockers(doc)
	if exit != 1 || len(bl) != 1 || bl[0]["reason"] != "git_operation_in_progress" || bl[0]["detail"] != "merge" {
		t.Fatalf("merge: exit %d, %v", exit, doc)
	}
}

func TestPreflightProjectConfigurationUnreadable(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	if err := os.Remove(filepath.Join(f.Root, ".kogen/project.yaml")); err != nil {
		t.Fatal(err)
	}
	cfgErr := func() *sysErrorView {
		_, err := project.LoadConfig(f.Root)
		e, _ := sys.AsError(err)
		return &sysErrorView{e.Class, e.Reason, e.Detail}
	}()

	exit, out := f.preflight(approveSlug, false)
	if exit != 3 || out != "preflight: "+cfgErr.detail+"\n" {
		t.Fatalf("exit %d, text %q", exit, out)
	}
	exit, doc := f.preflightJSON(approveSlug)
	if exit != 3 || doc["data"] != nil || !reflect.DeepEqual(doc["error"],
		map[string]any{"class": cfgErr.class, "reason": cfgErr.reason, "detail": cfgErr.detail, "paths": []any{}}) {
		t.Fatalf("exit %d, %v", exit, doc)
	}
}

func TestPreflightObservesWithoutRunningGitHooksOrWriting(t *testing.T) {
	parallel(t)
	f := newApproveFx(t)
	f.approved()
	monitor, marker := filepath.Join(f.Aux, "fsmonitor"), filepath.Join(f.Aux, "fsmonitor-ran")
	if err := os.WriteFile(monitor, []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	f.git("config", "core.fsmonitor", monitor)
	index := f.read(".git/index")
	exit, doc := f.preflightJSON(approveSlug)
	if exit != 0 || doc["data"].(map[string]any)["ready"] != true {
		t.Fatalf("exit %d, %v", exit, doc)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("the fsmonitor hook ran")
	}
	if f.read(".git/index") != index {
		t.Fatal("preflight changed the index")
	}
}

type sysErrorView struct{ class, reason, detail string }
