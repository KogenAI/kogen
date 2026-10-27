package build

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

func blockerReport(path string) map[string]any {
	return map[string]any{
		"paths":    []any{path},
		"reason":   "The fixture requires the same value to equal A and B.",
		"evidence": "Real acceptance probe: exit status 1, fixture requires mutually exclusive B at integration_steps.js.",
	}
}

func with(m map[string]any, kv ...any) map[string]any {
	out := map[string]any{}
	for k, v := range m {
		out[k] = v
	}
	for i := 0; i < len(kv); i += 2 {
		out[kv[i].(string)] = kv[i+1]
	}
	return out
}

// authority is what a stopped Build must leave as it found it.
type custody struct{ head, index, approval string }

func (e *env) authority() custody {
	idx, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	ap, _ := os.ReadFile(project.ApprovalPath(e.root, testSlug))
	return custody{e.gitOutSafe("rev-parse", "--verify", "-q", "HEAD"), string(idx), string(ap)}
}

func (e *env) gitOutSafe(args ...string) string {
	out, _ := execGit(e, args...)
	return strings.TrimSpace(out)
}

func TestABuilderReportedProtectedContradictionStopsBeforeLaterCallsOrGates(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/builder_blocker_test.exs: LOOP-7 a builder-reported protected contradiction stops before later calls or gates
	marker := filepath.Join(t.TempDir(), "fixer-ran")
	e := newEnv(t, func(c *project.Config) { c.Fix = []string{"touch " + marker} })
	report := blockerReport(stepsFile)
	f := e.prov
	f.then(
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "A\n"},
			"shell", map[string]any{"command": "echo 'fixture requires mutually exclusive B' >&2; exit 1"}),
		sse(
			f.call("finish", map[string]any{"summary": "earlier finish must not start gates"}),
			f.call("report_blocker", report),
			f.call("write_file", map[string]any{"path": "late.txt", "content": "must not run"}),
			f.call("shell", map[string]any{"command": "touch late-shell"}),
			f.call("finish", map[string]any{"summary": "must not verify"}),
		),
	)
	before := e.authority()
	a := e.build()
	if a.exit != 1 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	out := a.out.String()
	id := e.onlyRun()
	contains(t, "stdout", out, "failed fixture: build_blocked (Build "+id+")\n")
	contains(t, "stdout", out, "candidate/build_blocked: BUILDER-REPORTED protected-baseline contradiction; edits are left in place; this report is not independently proven\n")
	contains(t, "stdout", out, "  paths: "+stepsFile+"\n")
	contains(t, "stdout", out, "  reason: The fixture requires the same value to equal A and B.\n")
	contains(t, "stdout", out, "  evidence: "+report["evidence"].(string)+"\n")
	contains(t, "stdout", out, "  edited: app.txt\n")
	contains(t, "stdout", out, "  run log: "+e.runPath(id, "log.jsonl")+"\n")
	contains(t, "stdout", out, "  fixture Build "+id+" stopped in building: build_blocked; candidate: "+e.root+"; evidence: "+e.runPath(id, "")+"; index: ")
	contains(t, "stdout", out, "  kogen intent recover "+id+" --output <new-external-directory> --project '"+e.root+"'\n")
	contains(t, "stdout", out, "  Recovery preserves and clears only implementation; the builder-reported claim is unproven. Independently Refine, freshly approve and start a fresh Build; resume cannot override a protected blocker.\n")
	contains(t, "stdout", out, "  kogen intent inspect "+id+" --project '"+e.root+"'\n")
	found := false
	for _, o := range f.toolOutputs() {
		if strings.HasPrefix(o, "exit status: 1") && strings.Contains(o, "fixture requires mutually exclusive B") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no failing shell output in %q", f.toolOutputs())
	}
	if got := e.authority(); got != before {
		t.Fatal("head, index or approval changed")
	}
	eq(t, "app.txt", e.read("app.txt"), "A\n")
	for _, p := range []string{"late.txt", "late-shell"} {
		if _, err := os.Stat(filepath.Join(e.root, p)); !os.IsNotExist(err) {
			t.Fatalf("%s exists", p)
		}
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("the fixer ran")
	}
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("build_blocked"))
	eq(t, "passes", res["passes"], any(float64(0)))
	eq(t, "reviews", res["reviews"], any(float64(0)))
	blocker := res["blocker"].(map[string]any)
	eq(t, "classification", blocker["classification"], any("BUILDER-REPORTED"))
	eq(t, "evidence", blocker["evidence"], report["evidence"])
	if len(eventsNamed(e.events(id), "builder_blocker")) != 1 {
		t.Fatal("no builder_blocker event")
	}
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "resume_status", facts["resume_status"], any("unsupported"))
	eq(t, "state", facts["state"], any("build_blocked"))
	blockers := facts["blockers"].([]any)
	if paths := blockers[0].(map[string]any)["paths"].([]any); len(paths) != 1 || paths[0] != stepsFile {
		t.Fatalf("blockers %v", blockers)
	}
	requests := f.count()
	r := e.resume(id)
	eq(t, "resume exit", r.exit, 1)
	contains(t, "resume", r.shown(), "candidate/resume_refused: Build "+id+": uncertain tool boundary; inspect effects before starting a freshly approved Build;")
	if got := e.authority(); got != before {
		t.Fatal("head, index or approval changed by the refused resume")
	}
	eq(t, "requests", f.count(), requests)
}

func TestMalformedEmptyAndUnprotectedBlockerReportsGrantNoWrites(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/builder_blocker_test.exs: LOOP-7 malformed, empty and unprotected blocker reports return feedback and grant no writes
	e := newEnv(t)
	f := e.prov
	report := blockerReport(stepsFile)
	invalid := []map[string]any{
		blockerReport("app.txt"),
		with(report, "paths", []any{}),
		with(report, "reason", " "),
		with(report, "evidence", ""),
		with(report, "paths", []any{123}),
		with(report, "paths", []any{stepsFile, stepsFile}),
		with(report, "unexpected", true),
	}
	for _, r := range invalid {
		f.then(f.calls("report_blocker", r))
	}
	f.then(
		f.calls("write_file", map[string]any{"path": stepsFile, "content": "forbidden"}),
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "ordinary implementation\n"}),
		f.calls("finish", map[string]any{"summary": "ready"}))
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	contains(t, "stdout", a.out.String(), "landed fixture ")
	eq(t, "step file", e.read(stepsFile), "// steps\n")
	feedback := strings.Join(f.toolOutputs(), "\n")
	contains(t, "feedback", feedback, "invalid blocker")
	contains(t, "feedback", feedback, "refused: "+stepsFile)
	res := e.result(e.onlyRun())
	if _, ok := res["blocker"]; ok {
		t.Fatal("a blocker was recorded")
	}
}

func TestAcceptingABlockerStillRequiresTheOriginalHeadAndProtectedBytes(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/builder_blocker_test.exs: LOOP-7 accepting a blocker still requires the original HEAD and protected bytes
	for _, c := range []struct{ mutation, expected string }{
		{"printf changed >> " + stepsFile, "baseline_changed"},
		{"git -c commit.gpgsign=false commit --allow-empty -qm moved", "head_moved"},
		{"git update-ref -d HEAD", "head_moved"},
	} {
		t.Run(c.expected+" "+c.mutation, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			f := e.prov
			f.then(f.calls("shell", map[string]any{"command": c.mutation}, "report_blocker", blockerReport(stepsFile)))
			before := e.authority()
			a := e.build()
			eq(t, "exit", a.exit, 1)
			contains(t, "stdout", a.out.String(), c.expected)
			if res := e.result(e.onlyRun()); res["outcome"] == "build_blocked" {
				t.Fatal("the blocker was accepted")
			}
			after := e.authority()
			eq(t, "index", after.index, before.index)
			eq(t, "approval", after.approval, before.approval)
		})
	}
}
