package shape

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen/git"
	"kogen/project"
	"kogen/sys"
	"kogen/verify"
)

// ---- fixture: a ready (optionally approved, optionally source-bound) draft ----

const (
	refIntentPath  = ".kogen/intents/is-even/intent.md"
	refFeaturePath = ".kogen/intents/is-even/acceptance.feature"
	refStepPath    = "features/steps/is_even_steps.js"
)

type refOpts struct {
	approved bool // the draft carries a current approval
	source   bool // the draft carries a source receipt
	red      bool // the original's dry run fails its scenarios
}

type refFx struct {
	*shpFx
	hash0    string
	approval string
}

// newRefFx is a committed project with a ready draft `is-even`: written, its readiness
// recorded (so refinement can retain it), approved when asked. The runner replays a green
// report unless red.
func newRefFx(t *testing.T, o refOpts, steps ...shpStep) *refFx {
	t.Helper()
	f := &refFx{shpFx: newShpFx(t, steps...)}
	status, code := "PASSED", 0
	if o.red {
		status, code = "FAILED", 1
	}
	f.setReport(status, code)
	for p, c := range map[string]string{refIntentPath: shpIntentMD, refFeaturePath: shpFeature, refStepPath: shpSteps} {
		f.write(p, c)
	}
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		t.Fatal(err)
	}
	if o.source {
		origin, err := project.CaptureOrigin(f.Root, cfg)
		if err != nil {
			t.Fatal(err)
		}
		err = project.CaptureSource(f.Root, shpSlug, cfg, project.ShapeSource{
			Request: "Add calc.is_even(n).", SourcePath: "", Rounds: []map[string]any{}, Origin: origin,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	f.newSession()
	rd := &verify.Readiness{Root: f.Root, Repo: f.Repo, Config: cfg}
	if _, err := rd.Check(context.Background(), f.S, shpSlug); err != nil {
		t.Fatal(err)
	}
	f.hash0 = f.hash()
	if o.approved {
		f.newSession()
		if exit, err := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0}); err != nil || exit != 0 {
			t.Fatalf("approve: exit %d, err %v\n%s", exit, err, f.Stdout)
		}
		f.approval = f.read(".kogen/local/approvals/is-even.json")
	}
	f.Prov.mu.Lock()
	f.Prov.reqs = nil
	f.Prov.mu.Unlock()
	return f
}

func (f *refFx) baseline() []string {
	f.t.Helper()
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		f.t.Fatal(err)
	}
	paths, err := project.Baseline(f.Root, shpSlug, cfg)
	if err != nil {
		f.t.Fatal(err)
	}
	return paths
}

func (f *refFx) hash() string { return project.Hash(f.Root, f.baseline()) }

// pkg is the content of every baseline file.
func (f *refFx) pkg() map[string]string {
	out := map[string]string{}
	for _, p := range f.baseline() {
		out[p] = f.read(p)
	}
	return out
}

func (f *refFx) index() string {
	b, err := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *refFx) refine(hash string) (int, error) {
	f.t.Helper()
	f.newSession()
	return Refine(context.Background(), f.S, RefineInput{
		Project: f.Root, Slug: shpSlug, Hash: hash, Request: "Clarify only the existing draft; preserve its executable contract.",
		RequestPath: filepath.Join(f.Aux, "correction.txt"), Client: f.Client,
	})
}

type refResult struct {
	exit int
	err  error
}

// refineAsync runs the refinement while the test acts on the checkout.
func (f *refFx) refineAsync(hash string) <-chan refResult {
	f.newSession()
	done := make(chan refResult, 1)
	s := f.S
	go func() {
		exit, err := Refine(context.Background(), s, RefineInput{
			Project: f.Root, Slug: shpSlug, Hash: hash, Request: "Clarify only the existing draft; preserve its executable contract.",
			RequestPath: filepath.Join(f.Aux, "correction.txt"), Client: f.Client,
		})
		done <- refResult{exit, err}
	}()
	return done
}

func refWait(t *testing.T, done <-chan refResult) refResult {
	t.Helper()
	select {
	case r := <-done:
		return r
	case <-time.After(60 * time.Second):
		t.Fatal("refinement did not finish")
		return refResult{}
	}
}

func refWaitFile(t *testing.T, path string) {
	t.Helper()
	for deadline := time.Now().Add(30 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(path); err == nil {
			return
		}
	}
	t.Fatalf("%s never appeared", path)
}

// refEvidence is the one refinement evidence folder.
func (f *refFx) evidence() string {
	f.t.Helper()
	dirs, _ := filepath.Glob(filepath.Join(f.Root, ".kogen/local/refinements/*"))
	if len(dirs) != 1 {
		f.t.Fatalf("refinement evidence folders: %v", dirs)
	}
	return dirs[0]
}

func (f *refFx) result() map[string]any {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.evidence(), "result.json"))
	if err != nil {
		f.t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		f.t.Fatal(err)
	}
	return doc
}

// refEvidenceEvents are the events of the refinement's evidence file.
func (f *refFx) evidenceEvents() []map[string]any {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.evidence(), "events.ndjson"))
	if err != nil {
		f.t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			f.t.Fatal(err)
		}
		out = append(out, ev)
	}
	return out
}

func (f *refFx) remove(rel string) {
	f.t.Helper()
	if err := os.Remove(filepath.Join(f.Root, rel)); err != nil {
		f.t.Fatal(err)
	}
}

// refSubmit is a submit_refinement call with whole files (path, content, path, content...).
func refSubmit(id string, pairs ...string) shpStep {
	var files []any
	for i := 0; i < len(pairs); i += 2 {
		files = append(files, map[string]any{"path": pairs[i], "content": pairs[i+1]})
	}
	return shpAnswer(shpCall(id, "submit_refinement", map[string]any{"files": files}))
}

func refConstraint(id, reason string) shpStep {
	return shpAnswer(shpCall(id, "submit_refinement", map[string]any{"constraint": reason}))
}

func refProbe(id, command string) shpStep {
	return shpAnswer(shpCall(id, "probe", map[string]any{"command": command}))
}

func refText(t *testing.T, what string, got, want string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %q, want %q", what, got, want)
	}
}

func refEqual(t *testing.T, what string, got, want map[string]string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: %d files, want %d\n got %v\nwant %v", what, len(got), len(want), keys(got), keys(want))
	}
	for p, w := range want {
		if g, ok := got[p]; !ok || g != w {
			t.Fatalf("%s: %s = %q, want %q", what, p, g, w)
		}
	}
}

func keys(m map[string]string) []string { return sortedKeys(m) }

func refWith(m map[string]string, kv ...string) map[string]string {
	out := map[string]string{}
	for k, v := range m {
		out[k] = v
	}
	for i := 0; i < len(kv); i += 2 {
		out[kv[i]] = kv[i+1]
	}
	return out
}

// the corrections used throughout
var (
	refTitled   = strings.Replace(shpIntentMD, "# Add an is-even check", "# Clarify the is-even check", 1)
	refFeatured = strings.Replace(shpFeature, "Feature: Is even", "Feature: Is even corrected", 1)
)

func refRequestMissing(t *testing.T, f *refFx) {
	t.Helper()
	if n := len(f.Prov.requests()); n != 0 {
		t.Fatalf("%d provider request(s), want none", n)
	}
}

func refNoScratch(t *testing.T, f *refFx) {
	t.Helper()
	left, _ := filepath.Glob(filepath.Join(f.Tmp, "kogen-refine-*"))
	if len(left) != 0 {
		t.Fatalf("scratch checkouts left: %v", left)
	}
}

// ---- the happy path and its lines ----

func TestRefineLargeRepositoryUsesNavigationAndKeepsCompleteOwnedAuthority(t *testing.T) {
	f := newRefFx(t, refOpts{}, refSubmit("c1", refIntentPath, refTitled))
	for i := 0; i < 1600; i++ {
		f.write(fmt.Sprintf("bulk/source_%d.go", i), fmt.Sprintf("package bulk\nfunc Declaration%d() {}\n", i))
	}
	f.git("add", "bulk")
	f.git("commit", "-qm", "Add unrelated repository files")
	originals := f.pkg()
	if exit, err := f.refine(f.hash0); err != nil || exit != 0 {
		t.Fatalf("exit %d err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	body := shpBody(reqs[0])
	shpContains(t, "navigation", body, "Context navigation: ")
	if strings.Contains(body, "Context index: ") || len(body) >= 100000 {
		t.Fatalf("unrelated repository material entered mandatory input: %d bytes", len(body))
	}
	for _, p := range []string{refIntentPath, refFeaturePath, refStepPath} {
		shpContains(t, "complete owned original", body, originals[p])
	}
	refEqual(t, "corrected package", f.pkg(), refWith(originals, refIntentPath, refTitled))
}

func TestRefineWritesTheCorrectionAndPrintsTheLines(t *testing.T) {
	f := newRefFx(t, refOpts{approved: true}, refSubmit("c1", refIntentPath, refTitled))
	before := f.pkg()
	index := f.index()
	head := f.head()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\nstdout: %s\nstderr: %s", exit, err, f.Stdout, f.Stderr)
	}
	evidence := f.evidence()
	lines := strings.Split(strings.TrimSuffix(f.Stdout.String(), "\n"), "\n")
	refText(t, "stdout", f.Stdout.String(),
		"refined is-even "+f.hash()[:8]+"\nChanged: "+refIntentPath+"\nEvidence: "+evidence+"\nNext: kogen intent approve is-even\n")
	if len(lines) != 4 || f.hash() == f.hash0 {
		t.Fatalf("stdout:\n%s", f.Stdout)
	}
	shpContains(t, "progress", f.Stderr.String(), "kogen: refinement evidence: "+evidence+"\n")
	shpContains(t, "progress", f.Stderr.String(), "kogen: refining is-even gpt-6.1-sol/high\n")
	shpMatch(t, "progress", f.Stderr.String(), `kogen: refinement response input=\d+ cached=40 output=30 reasoning=10 wall_ms=\d+\n`)

	refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
	shpEq(t, "HEAD", f.head(), head)
	shpEq(t, "index", f.index() == index, true)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("refinement revokes the approval")
	}
	refText(t, "archived approval", f.read(strings.TrimPrefix(evidence, f.Root+"/")+"/revoked-approval.json"), f.approval)

	// The model saw the request, the original contracts and the tools it may use.
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 1)
	shpEq(t, "tools", strings.Join(shpToolNames(reqs[0]), ", "), "read_file, list_files, search_text, probe, documentation, submit_refinement")
	shpEq(t, "model", reqs[0]["model"], any("gpt-6.1-sol"))
	body := shpBody(reqs[0])
	shpContains(t, "request", body, "Clarify only the existing draft; preserve its executable contract.")
	shpContains(t, "request", body, "Full contract inclusions: original Intent prose, Gherkin and declared model preserve exact authority")
	shpContains(t, "request", body, "Source provenance: unavailable (legacy)")
	shpContains(t, "request", body, "--- "+refIntentPath+"\n"+shpIntentMD)
	shpContains(t, "request", body, "# Exclusively owned editable files\n"+refIntentPath+"\n"+refFeaturePath+"\n"+refStepPath+"\n")
	shpContains(t, "request", body, `Configured protected files: []`)
	shpContains(t, "request", body, `Checks: [{"unit", "true"}]`)
	shpContains(t, "request", body, "Acceptance: ./accept.sh")
	shpContains(t, "request", body, "# Project README\n# Calc")
	shpContains(t, "request", body, "Use the narrowest test that exercises the rule")
	shpContains(t, "request", body, "Cumulative proposal/original manifest: ")
	shpContains(t, "request", body, "Use focused scratch probes")
	shpContains(t, "request", body, "Exact retained readiness result: "+filepath.Join(evidence, "original-readiness-observations.json"))
	shpContains(t, "request", body, "Context navigation: ")
	shpContains(t, "request", body, "End with submit_refinement.")

	// What the evidence keeps.
	refText(t, "request.md", f.read(strings.TrimPrefix(evidence, f.Root+"/")+"/request.md"), "Clarify only the existing draft; preserve its executable contract.")
	fi, err := os.Stat(evidence)
	if err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("evidence folder mode: %v, %v", fi, err)
	}
	if fi, err := os.Stat(filepath.Join(evidence, "request.md")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("request.md mode: %v, %v", fi, err)
	}
	rel := strings.TrimPrefix(evidence, f.Root+"/")
	refText(t, "original copy", f.read(rel+"/original/"+refIntentPath), shpIntentMD)
	refText(t, "original copy", f.read(rel+"/original/"+refStepPath), shpSteps)
	refText(t, "rollback copy", f.read(rel+"/rollback/"+refIntentPath), shpIntentMD)
	refText(t, "candidate copy", f.read(rel+"/candidate-1/"+refIntentPath), refTitled)
	var submission map[string]any
	if err := json.Unmarshal([]byte(f.read(rel+"/submission-1.json")), &submission); err != nil || submission["files"] == nil {
		t.Fatalf("submission-1.json: %v, %v", submission, err)
	}
	if f.exists(rel + "/publish/" + refIntentPath) {
		t.Fatal("the published copy was moved into the draft")
	}
	result := f.result()
	shpEq(t, "outcome", result["outcome"], any("ready"))
	shpEq(t, "slug", result["slug"], any("is-even"))
	shpEq(t, "baseline", result["baseline"], any(f.hash0))
	shpEq(t, "head", result["head"], any(head))
	shpEq(t, "changed", strings.Join(refStrings(result["changed"]), ","), refIntentPath)
	usage := result["usage"].(map[string]any)
	shpEq(t, "usage input", usage["input"], any(float64(100)))
	shpEq(t, "usage output", usage["output"], any(float64(30)))
	refNoScratch(t, f)
	if fi, err := os.Stat(filepath.Join(f.Root, ".kogen/local/build.lock")); err == nil {
		t.Fatalf("the Build lock is still held: %v", fi)
	}

	// Evidence events of the run.
	events := f.evidenceEvents()
	calls := shpNamed(events, "provider_call")
	shpEq(t, "provider calls", len(calls), 1)
	shpEq(t, "scope", calls[0]["scope"], any("targeted refinement"))
	shpEq(t, "role", calls[0]["role"], any("shape"))
	shpEq(t, "revision", calls[0]["revision"].(map[string]any)["head"], any(head))
	shpEq(t, "context selections", len(shpNamed(events, "context_selection")), 1)
	shpEq(t, "session ends", len(shpNamed(events, "session_end")), 1)
	shpEq(t, "usage totals", len(shpNamed(events, "usage_totals")), 1)
}

func refStrings(v any) []string {
	var out []string
	for _, e := range v.([]any) {
		out = append(out, e.(string))
	}
	return out
}

// ---- readiness: the original, red and green candidates ----

func TestRefineOriginalReadinessHitRetainsTheRecordWithoutExecution(t *testing.T) {
	f := newRefFx(t, refOpts{}, refSubmit("c1", refIntentPath, refTitled))
	runs := f.runs()
	if exit, err := f.refine(f.hash0); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	evidence := f.evidence()
	var receipt map[string]any
	if err := json.Unmarshal([]byte(f.read(strings.TrimPrefix(evidence, f.Root+"/")+"/original-readiness.json")), &receipt); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "event", receipt["event"], any("original_readiness"))
	shpEq(t, "status", receipt["status"], any("hit"))
	shpEq(t, "source", receipt["source"], any("retained"))
	shpEq(t, "reason", receipt["reason"], any("valid complete version3 protected-baseline/HEAD evidence"))
	shpEq(t, "reference", receipt["reference"], any("retained-original-readiness.json"))
	shpEq(t, "baseline", receipt["baseline"], any(f.hash0))
	shpEq(t, "head", receipt["head"], any(f.head()))
	shpEq(t, "setup executions", receipt["setup_executions"], any(float64(0)))
	shpEq(t, "acceptance executions", receipt["acceptance_executions"], any(float64(0)))
	shpEq(t, "model executions", receipt["model_executions"], any(float64(0)))
	avoided := receipt["avoided"].(map[string]any)
	for _, k := range []string{"setup", "acceptance", "model", "source_wall_ms"} {
		if v, ok := avoided[k]; !ok || v != nil {
			t.Fatalf("avoided[%s] = %v, %v", k, v, ok)
		}
	}
	var retained map[string]any
	if err := json.Unmarshal([]byte(f.read(strings.TrimPrefix(evidence, f.Root+"/")+"/"+receipt["reference"].(string))), &retained); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "retained baseline", retained["sha256"], receipt["baseline"])
	shpEq(t, "retained head", retained["head"], receipt["head"])
	if retained["sha256"] == f.hash() {
		t.Fatal("the retained original is not the refined draft")
	}
	// The original's runner never ran again for the original; the candidate's dry run did.
	shpEq(t, "runner runs", f.runs()-runs, 1)

	// The refined draft's own evidence replaced the original's.
	var evidenceRec map[string]any
	if err := json.Unmarshal([]byte(f.read(".kogen/local/readiness/is-even.json")), &evidenceRec); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "evidence outcome", evidenceRec["outcome"], any("ready"))
	shpEq(t, "evidence sha", evidenceRec["sha256"], any(f.hash()))
	shpEq(t, "evidence title", evidenceRec["title"], any("Clarify the is-even check"))
	shpEq(t, "evidence version", evidenceRec["version"], any(float64(3)))
	for _, sc := range evidenceRec["scenarios"].([]any) {
		shpEq(t, "scenario status", sc.(map[string]any)["status"], any("passed"))
	}

	// The card reuses it: no further execution.
	record := f.read(".kogen/local/readiness/is-even.json")
	runs = f.runs()
	f.newSession()
	exit, err := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug})
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpContains(t, "card", f.Stdout.String(), "Intent: is-even — Clarify the is-even check")
	shpEq(t, "runner runs by the card", f.runs()-runs, 0)
	refText(t, "readiness record", f.read(".kogen/local/readiness/is-even.json"), record)
	if len(f.Prov.requests()) != 1 {
		t.Fatalf("requests = %d", len(f.Prov.requests()))
	}
}

func TestRefineOriginalReadinessMissChecksTheOriginalInScratch(t *testing.T) {
	f := newRefFx(t, refOpts{}, refSubmit("c1", refIntentPath, refTitled))
	f.remove(".kogen/local/readiness/is-even.json")
	runs := f.runs()
	if exit, err := f.refine(f.hash0); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	rel := strings.TrimPrefix(f.evidence(), f.Root+"/")
	var receipt map[string]any
	if err := json.Unmarshal([]byte(f.read(rel+"/original-readiness.json")), &receipt); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "status", receipt["status"], any("miss"))
	shpEq(t, "source", receipt["source"], any("scratch"))
	shpEq(t, "reference", receipt["reference"], any("original-observations.txt"))
	shpEq(t, "acceptance executions", receipt["acceptance_executions"], any(float64(1)))
	// original dry run plus the candidate's
	shpEq(t, "runner runs", f.runs()-runs, 2)
	if f.exists(rel + "/retained-original-readiness.json") {
		t.Fatal("no retained record without a hit")
	}
	var obs map[string]any
	if err := json.Unmarshal([]byte(f.read(rel+"/original-readiness-observations.json")), &obs); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "observed baseline", obs["sha256"], any(f.hash0))
	shpEq(t, "observed exit", obs["acceptance_exit"], any(float64(0)))
	shpEq(t, "observed scenarios", len(obs["scenarios"].([]any)), 2)
	if f.exists(rel + "/original-observations.txt") {
		t.Fatal("green original has no observations")
	}
}

func TestRefineRedOriginalGivesTheModelItsObservationsAndAcknowledgmentReusesThem(t *testing.T) {
	f := newRefFx(t, refOpts{red: true},
		refSubmit("c1", refFeaturePath, shpFeature), // the smallest artifact, unchanged: acknowledgment
	)
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 1)
	body := shpBody(reqs[0])
	shpContains(t, "original observations", body, "Readiness observations\nChecked baseline: "+f.hash0)
	shpContains(t, "original observations", body, "Scenario: Even numbers (acceptance.feature line 2)")
	rel := strings.TrimPrefix(f.evidence(), f.Root+"/")
	obs := f.read(rel + "/original-observations.txt")
	shpEq(t, "observations file", strings.HasPrefix(obs, "Readiness observations\nChecked baseline: "+f.hash0), true)
	// Acknowledged: no new dry run for the unchanged candidate (one for the original record).
	var rec map[string]any
	if err := json.Unmarshal([]byte(f.read(".kogen/local/readiness/is-even.json")), &rec); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "evidence sha", rec["sha256"], any(f.hash0))
	shpEq(t, "evidence exit", rec["acceptance_exit"], any(float64(1)))
	shpEq(t, "refined hash unchanged", f.hash(), f.hash0)
}

func TestRefineRedCandidateReturnsObservationsAndAChangedOneIsCheckedAgain(t *testing.T) {
	f := newRefFx(t, refOpts{},
		refSubmit("c1", refIntentPath, refTitled),
		refSubmit("c2", refIntentPath, refTitled),                                     // acknowledgment of the red candidate
		refSubmit("c3", refStepPath, shpSteps+"// again\n", refIntentPath, refTitled), // never reached
	)
	f.setReport("FAILED", 1) // the candidate's dry run is red
	runs := f.runs()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 2)
	feedback := shpOutputs(reqs[1])["c1"]
	shpContains(t, "feedback", feedback, "Inspect whether fixtures, inputs and commands reached the intended behavior")
	shpContains(t, "feedback", feedback, "Acceptance exit: 1\n")
	rel := strings.TrimPrefix(f.evidence(), f.Root+"/")
	shpContains(t, "feedback", feedback, "Evidence: "+filepath.Join(f.Root, rel, "observations-1.txt"))
	shpEq(t, "acknowledged", shpOutputs(reqs[1])["c1"] != "", true)
	// the candidate was checked once; the acknowledgment ran nothing
	shpEq(t, "runner runs", f.runs()-runs, 1)
	refText(t, "title", f.read(refIntentPath), refTitled)
	var rec map[string]any
	if err := json.Unmarshal([]byte(f.read(".kogen/local/readiness/is-even.json")), &rec); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "evidence is the candidate's", rec["sha256"], any(f.hash()))
	shpEq(t, "evidence exit", rec["acceptance_exit"], any(float64(1)))
	if f.exists(rel + "/observations-2.txt") {
		t.Fatal("an acknowledgment adds no observations")
	}
	// the observation round did not count as an invalid submission
	shpEq(t, "result", f.result()["outcome"], any("ready"))
}

func TestRefineAChangedCandidateAfterRedGetsFreshChecks(t *testing.T) {
	f := newRefFx(t, refOpts{},
		refSubmit("c1", refIntentPath, refTitled),
		refSubmit("c2", refStepPath, shpSteps+"// changed\n"),
		refSubmit("c3", refStepPath, shpSteps+"// changed\n"),
	)
	f.setReport("FAILED", 1)
	runs := f.runs()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	shpContains(t, "second feedback", shpOutputs(f.Prov.requests()[2])["c2"], "Readiness observations")
	shpEq(t, "runner runs: two candidate dry runs", f.runs()-runs, 2)
	refText(t, "step", f.read(refStepPath), shpSteps+"// changed\n")
	refText(t, "intent", f.read(refIntentPath), refTitled)
}

func TestRefineUnchangedRedFromTheInitialContextAcknowledgesItsExistingCheck(t *testing.T) {
	f := newRefFx(t, refOpts{red: true}, refSubmit("c1", refIntentPath, shpIntentMD))
	f.remove(".kogen/local/readiness/is-even.json")
	runs := f.runs()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	// only the original's dry run executed; the unchanged acknowledgment reused it
	shpEq(t, "runner runs", f.runs()-runs, 1)
	prompt := shpBody(f.Prov.requests()[0])
	shpContains(t, "prompt", prompt, "Scenario: Even numbers (acceptance.feature line 2)\nacceptance.feature line 3: Given the number 4\nassertion failed in scenario Even numbers")
	m := regexp.MustCompile(`(?m)^Evidence: (.+)$`).FindStringSubmatch(prompt)
	if m == nil {
		t.Fatalf("no evidence reference in the prompt:\n%s", prompt)
	}
	reference, err := os.ReadFile(m[1])
	if err != nil {
		t.Fatal(err)
	}
	shpContains(t, "reference file", string(reference), "assertion failed in scenario Even numbers")
	retained, err := os.ReadFile(filepath.Join(f.evidence(), "original-observations.txt"))
	if err != nil || string(retained) != string(reference) {
		t.Fatalf("the retained observations differ from the reference: %v", err)
	}
	refText(t, "intent", f.read(refIntentPath), shpIntentMD)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("no approval")
	}
}

func TestRefineCumulativeRedProposalsStayUnpublishedUntilTheirObservationsAreAcknowledged(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "red-refinement-observed")
	updated := strings.Replace(shpIntentMD, "# Add an is-even check", "# Observe the is-even check", 1)
	corrected := strings.Replace(updated, "# Observe the is-even check", "# Acknowledge the is-even check", 1)
	step := shpSteps + "// observed red\n"
	f := newRefFx(t, refOpts{approved: true},
		refSubmit("c1", refIntentPath, updated, refFeaturePath, refFeatured, refStepPath, step),
		refProbe("c2", "touch '"+marker+"' && sleep 1"),
		refSubmit("c3", refIntentPath, corrected),
		refMessage("The remaining red is legitimate missing-feature behavior."),
		shpAnswer(shpCall("c4", "submit_refinement", map[string]any{"files": []any{}})),
		refSubmit("c5", refIntentPath, corrected),
	)
	f.setReport("FAILED", 1)
	before := f.pkg()
	index := f.index()
	runs := f.runs()
	done := f.refineAsync(f.hash0)
	refWaitFile(t, marker)
	refEqual(t, "package during the run", f.pkg(), before)
	refText(t, "approval during the run", f.read(".kogen/local/approvals/is-even.json"), f.approval)
	shpEq(t, "index during the run", f.index() == index, true)
	r := refWait(t, done)
	if r.err != nil || r.exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", r.exit, r.err, f.Stderr)
	}
	refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, corrected, refFeaturePath, refFeatured, refStepPath, step))
	shpEq(t, "index", f.index() == index, true)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("the approval is revoked")
	}
	// two candidates were checked (the first and the corrected); the acknowledgment ran nothing
	shpEq(t, "runner runs", f.runs()-runs, 2)
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 6)
	var feedback []string
	for _, req := range reqs {
		for _, o := range shpOutputs(req) {
			feedback = append(feedback, o)
		}
	}
	all := strings.Join(feedback, "\n")
	shpContains(t, "feedback", all, "assertion failed in scenario Even numbers")
	shpContains(t, "feedback", all, "nonempty files array")
	shpContains(t, "feedback", all, "readiness acknowledgment")
	shpEq(t, "no stale wording", strings.Contains(all, "changed existing files only"), false)
	retry := shpBody(reqs[5])
	shpEq(t, "no stale reminder", strings.Contains(retry, "Call submit_refinement with changed existing files"), false)
	shpContains(t, "reminder", retry, "Call submit_refinement with a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint.")
	// the card reuses the published candidate's observations
	record := f.read(".kogen/local/readiness/is-even.json")
	f.newSession()
	exit, err := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug})
	if err != nil || exit != 5 {
		t.Fatalf("card: exit %d, err %v", exit, err)
	}
	shpContains(t, "card", f.Stdout.String(), "assertion failed in scenario Even numbers")
	shpEq(t, "runner runs by the card", f.runs()-runs, 2)
	refText(t, "readiness record", f.read(".kogen/local/readiness/is-even.json"), record)
}

func TestRefineProviderFailureDiagnosticsReachTheResultWithoutSecrets(t *testing.T) {
	failure := map[string]any{
		"code": "unknown_overload", "type": "provider_capacity", "message": "structured overload",
		"access_token": "SECRET-TOKEN-MARKER", "request": "PRIVATE-PAYLOAD-MARKER",
	}
	f := newRefFx(t, refOpts{approved: true}, shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		shpFrame(w, map[string]any{"type": "response.failed", "response": map[string]any{"error": failure}})
	}})
	before := f.pkg()
	exit, err := f.refine(f.hash0)
	e := shpWantError(t, err, "provider", "refused", "", 4)
	shpEq(t, "exit", exit, 4)
	rendered := e.Render()
	for _, want := range []string{"unknown_overload", "provider_capacity", "response.failed"} {
		shpContains(t, "rendered", rendered, want)
	}
	result, err := os.ReadFile(filepath.Join(f.evidence(), "result.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(result, &doc); err != nil {
		t.Fatal(err)
	}
	failureRecord, _ := doc["provider_failure"].(map[string]any)
	if len(failureRecord) != 3 || failureRecord["code"] != "unknown_overload" || failureRecord["type"] != "provider_capacity" || failureRecord["event_kind"] != "response.failed" {
		t.Fatalf("provider_failure = %v", doc["provider_failure"])
	}
	for _, text := range []string{rendered, string(result)} {
		for _, secret := range []string{"SECRET-TOKEN-MARKER", "PRIVATE-PAYLOAD-MARKER"} {
			if strings.Contains(text, secret) {
				t.Fatalf("%s leaked:\n%s", secret, text)
			}
		}
	}
	refEqual(t, "package", f.pkg(), before)
	refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), f.approval)
	shpEq(t, "requests", len(f.Prov.requests()), 1)
}

// ---- proposals accumulate ----

func TestRefineNarrowRetryPreservesAllEarlierProposalsUntilMergedReadiness(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "probe-started")
	pending := strings.NewReplacer(
		"# Add an is-even check", "# Correct the is-even check",
		"- Non-integers raise TypeError. (source: request)", "- Non-integers raise TypeError.",
		"Model: not applicable — a pure function without state", "Model: not applicable",
	).Replace(shpIntentMD)
	corrected := strings.NewReplacer(
		"# Add an is-even check", "# Correct the is-even check",
		"- Non-integers raise TypeError. (source: request)", "- Non-integers raise TypeError. (source: request)\n- Keep all corrected artifacts. (source: request)",
	).Replace(shpIntentMD)
	step := shpSteps + "// corrected\n"
	f := newRefFx(t, refOpts{approved: true},
		refSubmit("c1", refIntentPath, pending, refFeaturePath, refFeatured, refStepPath, step),
		refProbe("c2", "touch '"+marker+"' && sleep 1"),
		refSubmit("c3", refIntentPath, corrected),
	)
	before := f.pkg()
	index := f.index()
	done := f.refineAsync(f.hash0)
	refWaitFile(t, marker)
	refEqual(t, "package during the run", f.pkg(), before)
	refText(t, "approval during the run", f.read(".kogen/local/approvals/is-even.json"), f.approval)
	shpEq(t, "index during the run", f.index() == index, true)
	r := refWait(t, done)
	if r.err != nil || r.exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", r.exit, r.err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 3)
	lint := shpOutputs(reqs[1])["c1"]
	shpContains(t, "lint feedback", lint, "decisions: a decision has no source")
	shpContains(t, "lint feedback", lint, "model: the Model: line must be")
	shpContains(t, "lint feedback", lint, "Well-formed proposals are retained in this run; submit only corrections.")
	refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, corrected, refFeaturePath, refFeatured, refStepPath, step))
	shpEq(t, "index", f.index() == index, true)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("the approval is revoked")
	}
	archived := f.read(strings.TrimPrefix(f.evidence(), f.Root+"/") + "/revoked-approval.json")
	refText(t, "archived approval", archived, f.approval)
	var rec map[string]any
	if err := json.Unmarshal([]byte(f.read(".kogen/local/readiness/is-even.json")), &rec); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "evidence sha", rec["sha256"], any(f.hash()))
	// the manifest of the third request names what was proposed, from the scratch copy
	manifest := shpBody(reqs[2])
	shpContains(t, "manifest", manifest, `"submitted_sha256":"`+ContentHash([]byte(pending))+`"`)
	shpContains(t, "manifest", manifest, `"submitted_sha256":"`+ContentHash([]byte(step))+`"`)
	// The build refuses: fresh approval is required.
	if _, err := os.Stat(filepath.Join(f.Root, ".kogen/local/approvals/is-even.json")); err == nil {
		t.Fatal("approval exists")
	}
}

func TestRefineAMixedUnsafePayloadContributesNoProposals(t *testing.T) {
	f := newRefFx(t, refOpts{},
		refSubmit("c1", refIntentPath, strings.Replace(shpIntentMD, "# Add an is-even check", "# Must never publish", 1), "app.txt", "unsafe"),
		refSubmit("c2", refFeaturePath, refFeatured),
	)
	before := f.pkg()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	refEqual(t, "package", f.pkg(), refWith(before, refFeaturePath, refFeatured))
	refText(t, "app.txt", f.read("app.txt"), "red\n")
	feedback := shpOutputs(f.Prov.requests()[1])["c1"]
	refText(t, "feedback", feedback, refineInvalidFiles)
	rel := strings.TrimPrefix(f.evidence(), f.Root+"/")
	refText(t, "diagnostic file", f.read(rel+"/diagnostic-1.txt"), refineInvalidFiles)
	if f.exists(rel + "/candidate-1") {
		t.Fatal("an invalid submission has no candidate")
	}
	// only the second submission is a candidate
	refText(t, "candidate", f.read(rel+"/candidate-2/"+refFeaturePath), refFeatured)
	if f.exists(rel + "/candidate-2/" + refIntentPath) {
		t.Fatal("the unsafe proposal leaked into a candidate")
	}
}

func TestRefineLaterProposalsReplaceAPathAndOriginalBytesRevertIt(t *testing.T) {
	pending := strings.Replace(shpIntentMD, "- Non-integers raise TypeError. (source: request)", "- Non-integers raise TypeError. Retain the feature correction.", 1)
	latest := strings.Replace(pending, "# Add an is-even check", "# Latest correction", 1)
	corrected := strings.Replace(latest, "Retain the feature correction.", "Retain the feature correction. (source: request)", 1)
	f := newRefFx(t, refOpts{},
		refSubmit("c1", refIntentPath, pending, refFeaturePath, refFeatured, refStepPath, shpSteps+"\n// proposed helper\n"),
		refSubmit("c2", refIntentPath, latest, refStepPath, shpSteps),
		refSubmit("c3", refIntentPath, corrected),
	)
	before := f.pkg()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, corrected, refFeaturePath, refFeatured))
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	// the first submission was lint-red: nothing published, proposals retained in scratch
	shpContains(t, "feedback", shpOutputs(f.Prov.requests()[1])["c1"], "decisions: a decision has no source")
	result := f.result()
	changed := strings.Join(refStrings(result["changed"]), ",")
	shpEq(t, "changed", changed, refFeaturePath+","+refIntentPath+","+refStepPath)
}

func refMessage(text string) shpStep {
	return shpAnswer(map[string]any{"type": "message", "id": "m", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text}}})
}

func TestRefineInvalidSubmitIsRetriedAndAnAnswerWithoutCallsIsAsked(t *testing.T) {
	f := newRefFx(t, refOpts{},
		refMessage("done"), // no call at all
		shpAnswer(shpCall("c1", "submit_refinement", map[string]any{"files": []any{}})),
		refSubmit("c3", refIntentPath, refTitled),
	)
	before := f.pkg()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 3)
	shpContains(t, "reminder", shpBody(reqs[1]), "Call submit_refinement with a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint.")
	shpContains(t, "replayed message", shpBody(reqs[1]), "\ndone\n")
	refText(t, "empty files", shpOutputs(reqs[2])["c1"], refineInvalidShape)
	refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
}

func TestRefineThreeInvalidSubmissionsStopIt(t *testing.T) {
	f := newRefFx(t, refOpts{},
		refMessage("done"),
		shpAnswer(shpCall("c1", "submit_refinement", map[string]any{"files": []any{}})),
		shpAnswer(shpCall("c2", "submit_refinement", map[string]any{"files": []any{map[string]any{"path": refIntentPath}}})),
		refSubmit("c3", refIntentPath, refTitled),
	)
	before := f.pkg()
	exit, err := f.refine(f.hash0)
	e := shpWantError(t, err, "shape", "refinement_invalid", "no valid ready correction after 3 submissions; the original draft is preserved", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "lines", strings.Join(e.Lines, "|"), strings.Join(strings.Split(refineInvalidFiles, "\n"), "|"))
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	refText(t, "empty files", shpOutputs(f.Prov.requests()[2])["c1"], refineInvalidShape)
	refEqual(t, "package", f.pkg(), before)
	rendered := e.Render()
	shpContains(t, "render", rendered, "shape/refinement_invalid: no valid ready correction after 3 submissions; the original draft is preserved\n  invalid: a path is not")
}

func TestRefineBlankConstraintIsInvalid(t *testing.T) {
	f := newRefFx(t, refOpts{}, refConstraint("c1", "  "), refConstraint("c2", ""), refConstraint("c3", " \n"))
	_, err := f.refine(f.hash0)
	e := shpWantError(t, err, "shape", "refinement_invalid", "", 1)
	shpEq(t, "lines", strings.Join(e.Lines, "|"), "constraint must explain the unsupported work")
	refText(t, "feedback", shpOutputs(f.Prov.requests()[1])["c1"], "invalid: constraint must explain the unsupported work")
}

func TestRefineAReadOnlyAnswerDoesNotCountAsInvalid(t *testing.T) {
	read := func(id string) shpStep {
		return shpAnswer(shpCall(id, "read_file", map[string]any{"path": refIntentPath}))
	}
	f := newRefFx(t, refOpts{}, read("r1"), read("r2"), read("r3"), read("r4"), refSubmit("c1", refIntentPath, refTitled))
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpContains(t, "read result", shpOutputs(f.Prov.requests()[1])["r1"], "Slug: is-even")
}

func TestRefineOnlyOneSubmissionCountsPerResponse(t *testing.T) {
	f := newRefFx(t, refOpts{}, shpAnswer(
		shpCall("c1", "submit_refinement", map[string]any{"files": []any{map[string]any{"path": refIntentPath, "content": refTitled}}}),
		shpCall("c2", "submit_refinement", map[string]any{"constraint": "ignored"}),
		shpCall("c3", "write_file", map[string]any{"path": "x", "content": "y"}),
	))
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	refText(t, "title", f.read(refIntentPath), refTitled)
}

// ---- refusals and unsupported corrections keep the draft ----

func TestRefineInvalidUnsupportedProviderAndNotReadyResultsPreserveTheReadyDraft(t *testing.T) {
	undefined := "Feature: Fixture\n  Scenario: Undefined\n    Then a new undefined sentence\n"
	cases := []struct {
		name    string
		steps   []shpStep
		class   string
		reason  string
		exit    int
		message string
		outcome string
	}{
		{"invalid", []shpStep{
			refSubmit("c1", "new.txt", "no"), refSubmit("c2", "new.txt", "no"), refSubmit("c3", "new.txt", "no"),
		}, "shape", "refinement_invalid", 1, "no valid ready correction after 3 submissions; the original draft is preserved", "failed"},
		{"unsupported", []shpStep{
			refConstraint("c1", "This needs a new step file; refinement changes existing files only."),
		}, "shape", "refinement_constraint", 1, "This needs a new step file; refinement changes existing files only. The original draft is preserved.", "failed"},
		{"provider", []shpStep{
			refSubmit("c1", refFeaturePath, undefined), {status: 400, code: "invalid_request_error"},
		}, "provider", "", 4, "", "failed"},
		{"not ready", []shpStep{
			refSubmit("c1", refFeaturePath, undefined), refSubmit("c2", refFeaturePath, undefined), refSubmit("c3", refFeaturePath, undefined),
		}, "shape", "refinement_invalid", 1, "no valid ready correction after 3 submissions; the original draft is preserved", "failed"},
		{"topology", []shpStep{
			refSubmit("c1", refIntentPath, strings.Replace(shpIntentMD, "- features/steps/is_even_steps.js\n", "", 1)),
		}, "shape", "refinement_constraint", 1, refineTopology + " The original draft is preserved. The original draft is preserved.", "failed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newRefFx(t, refOpts{}, c.steps...)
			before := f.pkg()
			exit, err := f.refine(f.hash0)
			e, ok := sys.AsError(err)
			if !ok || e.Class != c.class || (c.reason != "" && e.Reason != c.reason) || e.Exit != c.exit || exit != c.exit {
				t.Fatalf("exit %d, err %v", exit, err)
			}
			if c.message != "" {
				shpEq(t, "detail", e.Detail, c.message)
			}
			refEqual(t, "package", f.pkg(), before)
			if f.exists(".kogen/local/approvals/is-even.json") {
				t.Fatal("no approval appears")
			}
			result := f.result()
			shpEq(t, "outcome", result["outcome"], any(c.outcome))
			shpContains(t, "result error", result["error"].(string), e.Error())
			refNoScratch(t, f)
			if c.name == "not ready" {
				shpContains(t, "feedback", shpOutputs(f.Prov.requests()[1])["c1"], "not ready:\nintent/not_ready: the Intent is not ready to build\n")
				shpEq(t, "invalid lines end with the split's empty string", e.Lines[len(e.Lines)-1], "")
			}
			if c.name == "provider" {
				if _, has := result["provider_failure"]; !has && e.ProviderFailure != nil {
					t.Fatalf("provider failure diagnostics not retained: %v", result)
				}
			}
		})
	}
}

func TestRefineRejectsProtectedAndSharedStepEditsWithoutChangingThePackage(t *testing.T) {
	for _, target := range []string{".kogen/project.yaml", "features/steps/calc_steps.js", refStepPath} {
		t.Run(target, func(t *testing.T) {
			f := newRefFx(t, refOpts{},
				refSubmit("c1", target, "changed"), refSubmit("c2", target, "changed"), refSubmit("c3", target, "changed"))
			switch target {
			case refStepPath: // another Intent lists the step: shared
				f.write(".kogen/intents/other/intent.md", "# Other\nAcceptance:\n- .kogen/intents/other/acceptance.feature\n- "+refStepPath+"\n")
			case "features/steps/calc_steps.js": // tracked: absent from HEAD is required
			}
			before := f.pkg()
			original := f.read(target)
			exit, err := f.refine(f.hash0)
			e := shpWantError(t, err, "shape", "refinement_invalid", "", 1)
			shpEq(t, "exit", exit, 1)
			shpContains(t, "lines", strings.Join(e.Lines, "\n"), "not an exclusively owned editable draft file")
			refEqual(t, "package", f.pkg(), before)
			refText(t, target, f.read(target), original)
		})
	}
}

func TestRefineProtectedPathsAreNotEditable(t *testing.T) {
	f := newRefFx(t, refOpts{})
	cfgText := f.read(".kogen/project.yaml")
	f.write(".kogen/project.yaml", cfgText+"protect: [features/steps/is_even_steps.js]\n")
	f.git("add", ".kogen/project.yaml")
	f.git("commit", "-qm", "protect the step")
	// re-record readiness for the changed configuration
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		t.Fatal(err)
	}
	f.newSession()
	if _, err := (&verify.Readiness{Root: f.Root, Repo: f.Repo, Config: cfg}).Check(context.Background(), f.S, shpSlug); err != nil {
		t.Fatal(err)
	}
	f.Prov.mu.Lock()
	f.Prov.seq = []shpStep{refSubmit("c1", refStepPath, "changed"), refSubmit("c2", refStepPath, "changed"), refSubmit("c3", refStepPath, "changed")}
	f.Prov.next = 0
	f.Prov.mu.Unlock()
	exit, err := f.refine(f.hash())
	e := shpWantError(t, err, "shape", "refinement_invalid", "", 1)
	shpEq(t, "exit", exit, 1)
	shpContains(t, "lines", strings.Join(e.Lines, "\n"), "not an exclusively owned editable draft file")
	shpContains(t, "request", shpBody(f.Prov.requests()[0]), `Configured protected files: ["features/steps/is_even_steps.js"]`)
	shpContains(t, "request", shpBody(f.Prov.requests()[0]), "# Exclusively owned editable files\n"+refIntentPath+"\n"+refFeaturePath+"\n# Protection")
}

func TestRefineFixersFormatTheCandidateAndCannotTouchOtherFiles(t *testing.T) {
	setup := func(t *testing.T, fix string, steps ...shpStep) *refFx {
		f := newRefFx(t, refOpts{})
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"  fix: ["+fix+"]\n")
		f.git("add", ".kogen/project.yaml")
		f.git("commit", "-qm", "fixer")
		cfg, err := project.LoadConfig(f.Root)
		if err != nil {
			t.Fatal(err)
		}
		f.newSession()
		if _, err := (&verify.Readiness{Root: f.Root, Repo: f.Repo, Config: cfg}).Check(context.Background(), f.S, shpSlug); err != nil {
			t.Fatal(err)
		}
		f.Prov.mu.Lock()
		f.Prov.seq, f.Prov.next = steps, 0
		f.Prov.mu.Unlock()
		return f
	}
	t.Run("formats the submitted files", func(t *testing.T) {
		f := setup(t, `"printf '// formatted\\n' >> features/steps/is_even_steps.js"`, refSubmit("c1", refStepPath, shpSteps))
		exit, err := f.refine(f.hash())
		if err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		refText(t, "step", f.read(refStepPath), shpSteps+"// formatted\n")
	})
	t.Run("a failing fixer is unsupported work", func(t *testing.T) {
		f := setup(t, `"exit 3"`, refSubmit("c1", refIntentPath, refTitled))
		before := f.pkg()
		_, err := f.refine(f.hash())
		// the detail carries the suffix twice, as the Elixir Refine does for a constraint raised
		// while checking a submission
		shpWantError(t, err, "shape", "refinement_constraint",
			"A configured fixer failed: exit 3 The original draft is preserved. The original draft is preserved.", 1)
		refEqual(t, "package", f.pkg(), before)
	})
	t.Run("a fixer changing another file", func(t *testing.T) {
		f := setup(t, `"printf x >> app.txt"`, refSubmit("c1", refIntentPath, refTitled))
		before := f.pkg()
		_, err := f.refine(f.hash())
		shpWantError(t, err, "shape", "refinement_constraint", "A fixer changed files outside the submitted correction.", 1)
		refEqual(t, "package", f.pkg(), before)
		refText(t, "app.txt", f.read("app.txt"), "red\n")
	})
}

func TestRefineRefusalsBeforeTheModel(t *testing.T) {
	t.Run("hash must be the full lowercase digest", func(t *testing.T) {
		for _, h := range []string{"", "abc123", strings.ToUpper(strings.Repeat("a", 64)), strings.Repeat("a", 63) + "g"} {
			f := newRefFx(t, refOpts{})
			exit, err := f.refine(h)
			shpWantError(t, err, "intent", "refinement_hash", "refinement requires the full 64-character baseline SHA-256", 2)
			shpEq(t, "exit", exit, 2)
			refRequestMissing(t, f)
		}
	})
	t.Run("unknown Intent", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		f.newSession()
		exit, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: "missing", Hash: f.hash0, Request: "x"})
		shpWantError(t, err, "intent", "not_found", "Intent does not exist", 2)
		shpEq(t, "exit", exit, 2)
	})
	t.Run("an Intent that is not ready", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		f.write(refIntentPath, strings.Replace(shpIntentMD, "- none\n", "", 1))
		exit, err := f.refine(f.hash0)
		e := shpWantError(t, err, "intent", "not_ready", "refinement requires an existing ready Intent", 1)
		shpEq(t, "exit", exit, 1)
		shpContains(t, "lines", strings.Join(e.Lines, "\n"), "feasibility:")
		refRequestMissing(t, f)
	})
	t.Run("pending shaping questions", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		f.write(".kogen/local/shaping/is-even/state.json", "{}")
		_, err := f.refine(f.hash0)
		shpWantError(t, err, "shape", "refinement_constraint",
			"Finish or discard the pending shaping questions before refining this draft. The original draft is preserved.", 1)
		refRequestMissing(t, f)
	})
	t.Run("acceptance not configured", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		f.write(".kogen/project.yaml", "version: 1\ncommands:\n  checks: [{name: unit, run: 'true'}]\n")
		_, err := f.refine(f.hash0)
		shpWantError(t, err, "environment", "acceptance_unconfigured", "set commands.acceptance in .kogen/project.yaml", 3)
	})
	t.Run("a Build owns the checkout", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		lock := git.NewLock(git.BuildLockPath(f.Root))
		if _, err := lock.Acquire(); err != nil {
			t.Fatal(err)
		}
		defer lock.Release()
		exit, err := f.refine(f.hash0)
		shpWantError(t, err, "environment", "build_running", "", 3)
		shpEq(t, "exit", exit, 3)
		refRequestMissing(t, f)
	})
	t.Run("not a repository", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		f.newSession()
		exit, err := Refine(context.Background(), f.S, RefineInput{Project: t.TempDir(), Slug: shpSlug, Hash: f.hash0, Request: "x"})
		shpWantError(t, err, "environment", "not_a_git_repo", "", 3)
		shpEq(t, "exit", exit, 3)
	})
	t.Run("not signed in", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		os.RemoveAll(filepath.Join(f.Home, ".kogen"))
		exit, err := f.refine(f.hash0)
		shpWantError(t, err, "provider", "login", "", 4)
		shpEq(t, "exit", exit, 4)
		if f.exists(".kogen/local/refinements") {
			dirs, _ := filepath.Glob(filepath.Join(f.Root, ".kogen/local/refinements/*"))
			if len(dirs) != 0 {
				t.Fatalf("evidence before the login check: %v", dirs)
			}
		}
	})
	// ExUnit provider_test.exs "Shape includes enabled workers but Refine can select only the Shape
	// role": workers on a provider without a login cannot stop Refine at its login check.
	t.Run("enabled workers need no login for Refine", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		cfg, err := os.ReadFile(filepath.Join(f.Root, ".kogen/project.yaml"))
		if err != nil {
			t.Fatal(err)
		}
		workers := "shape_workers:\n  enabled: true\n" +
			"  read: {provider: supergrok, model: grok-4.7, effort: low}\n" +
			"  probe: {provider: supergrok, model: grok-4.7, effort: low}\n" +
			"  draft: {provider: supergrok, model: grok-4.7, effort: low}\n"
		f.write(".kogen/project.yaml", string(cfg)+workers)
		// The configuration is valid and the shape role (ChatGPT) is signed in, so Refine reaches its
		// model; a SuperGrok login refusal would mean it checked a worker's role.
		if _, err := project.LoadConfig(f.Root); err != nil {
			t.Fatalf("fixture configuration: %v", err)
		}
		_, err = f.refine(f.hash()) // the configuration is part of the package hash
		if se, ok := sys.AsError(err); ok && (se.Reason == "login" || se.Class == "environment") {
			t.Fatalf("Refine stopped before its model: %v", se)
		}
		if len(f.Prov.requests()) == 0 {
			t.Fatalf("Refine never reached its model: %v", err)
		}
	})
	t.Run("no commit", func(t *testing.T) {
		f := newRefFx(t, refOpts{})
		root := t.TempDir()
		cmd := exec.Command("git", "init", "-q")
		cmd.Dir = root
		cmd.Env = f.Env
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v\n%s", err, out)
		}
		for p, c := range map[string]string{
			".gitignore":           ".kogen/local/\n",
			".kogen/project.yaml":  f.read(".kogen/project.yaml"),
			refIntentPath:          shpIntentMD,
			refFeaturePath:         shpFeature,
			refStepPath:            shpSteps,
			"accept.sh":            f.read("accept.sh"),
			"features/steps/x.txt": "",
		} {
			full := filepath.Join(root, p)
			os.MkdirAll(filepath.Dir(full), 0o755)
			os.WriteFile(full, []byte(c), 0o755)
		}
		cfg, _ := project.LoadConfig(root)
		paths, _ := project.Baseline(root, shpSlug, cfg)
		f.newSession()
		_, err := Refine(context.Background(), f.S, RefineInput{Project: root, Slug: shpSlug, Hash: project.Hash(root, paths), Request: "x", Client: f.Client})
		shpWantError(t, err, "environment", "no_head", "commit the project before refining", 3)
	})
}

func itoa(n int) string {
	return strings.TrimSpace(strings.Repeat(" ", 0) + string(rune('0'+0)) + "")[:0] + refInt(n)
}

func refInt(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func TestRefineStaleHashesApprovalMismatchesAndDirtyImplementationRefuseBeforeModelRequests(t *testing.T) {
	// Ports "SHP-11 stale hashes and approved-current dirty implementation refuse before model
	// requests": a marker for another contract no longer refuses by itself.
	for _, kind := range []string{"hash", "dirty"} {
		t.Run(kind, func(t *testing.T) {
			f := newRefFx(t, refOpts{approved: true})
			if kind == "dirty" {
				f.write("app.txt", "unfinished candidate\n")
			}
			before := f.pkg()
			index := f.index()
			arg := f.hash()
			if kind == "hash" {
				arg = strings.Repeat("0", 64)
			}
			exit, err := f.refine(arg)
			if kind == "dirty" {
				e := shpWantError(t, err, "environment", "dirty_tree", "1 changed path(s) are not part of an Intent; commit, stash or discard them first", 5)
				shpEq(t, "lines", strings.Join(e.Lines, ","), "app.txt")
				shpEq(t, "exit", exit, 5)
			} else {
				shpWantError(t, err, "intent", "refinement_stale",
					"is-even is now "+f.hash()+", not "+arg+"; run kogen intent approve is-even to review the full current hash, then retry Refine; nothing was replaced", 1)
				shpEq(t, "exit", exit, 1)
			}
			refEqual(t, "package", f.pkg(), before)
			refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), f.approval)
			shpEq(t, "index", f.index() == index, true)
			refRequestMissing(t, f)
			if f.exists(".kogen/local/refinements") {
				dirs, _ := filepath.Glob(filepath.Join(f.Root, ".kogen/local/refinements/*"))
				if len(dirs) != 0 {
					t.Fatalf("a refused refinement leaves no evidence: %v", dirs)
				}
			}
		})
	}
}

func TestRefineAnUnrelatedStaleLegacyApprovalDoesNotImposeBuildCleanRestrictions(t *testing.T) {
	f := newRefFx(t, refOpts{approved: true})
	f.write(refIntentPath, f.read(refIntentPath)+"\nCurrent draft.\n")
	f.write("app.txt", "unrelated unfinished implementation\n")
	before := f.pkg()
	marker := f.read(".kogen/local/approvals/is-even.json")
	index := f.index()
	head := f.head()
	updated := before[refIntentPath] + "\nClarified only.\n"
	f.Prov.mu.Lock()
	f.Prov.seq = []shpStep{refSubmit("c1", refIntentPath, updated)}
	f.Prov.next = 0
	f.Prov.mu.Unlock()
	exit, err := f.refine(f.hash())
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	want := map[string]string{}
	for k, v := range before {
		want[k] = v
	}
	want[refIntentPath] = updated
	refEqual(t, "package", f.pkg(), want)
	shpEq(t, "unrelated work", f.read("app.txt"), "unrelated unfinished implementation\n")
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("the stale approval is revoked")
	}
	refText(t, "archived approval", f.read(strings.TrimPrefix(f.evidence(), f.Root+"/")+"/revoked-approval.json"), marker)
	shpEq(t, "index", f.index() == index, true)
	shpEq(t, "HEAD", f.head(), head)
}

// ---- approval ----

func TestRefineAnApprovedCorrectionArchivesTheExactApprovalAndNeedsAFreshOne(t *testing.T) {
	f := newRefFx(t, refOpts{approved: true}, refSubmit("c1", refIntentPath, refTitled))
	index := f.index()
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpEq(t, "index", f.index() == index, true)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("the old approval is revoked")
	}
	archived := f.read(strings.TrimPrefix(f.evidence(), f.Root+"/") + "/revoked-approval.json")
	refText(t, "archived approval", archived, f.approval)
	f.newSession()
	exit, err = Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Hash: f.hash()})
	if err != nil || exit != 0 {
		t.Fatalf("approve: exit %d, err %v", exit, err)
	}
	shpContains(t, "approval", f.Stdout.String(), "approved is-even "+f.hash()[:8])
	var approval map[string]any
	if err := json.Unmarshal([]byte(f.read(".kogen/local/approvals/is-even.json")), &approval); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "approval hash", approval["sha256"], any(f.hash()))
}

func TestRefineFailedAndCancelledApprovedCorrectionsPreservePackageRawApprovalAndIndex(t *testing.T) {
	undefined := "Feature: Fixture\n  Scenario: Undefined\n    Then a new undefined sentence\n"
	for _, kind := range []string{"provider", "invalid", "not ready", "cancel"} {
		t.Run(kind, func(t *testing.T) {
			marker := filepath.Join(t.TempDir(), "probe-started")
			var steps []shpStep
			switch kind {
			case "provider":
				steps = []shpStep{{status: 400, code: "invalid_request_error"}}
			case "invalid":
				steps = []shpStep{refSubmit("c1", "app.txt", "not an artifact"), refSubmit("c2", "app.txt", "not an artifact"), refSubmit("c3", "app.txt", "not an artifact")}
			case "not ready":
				steps = []shpStep{refSubmit("c1", refFeaturePath, undefined), refSubmit("c2", refFeaturePath, undefined), refSubmit("c3", refFeaturePath, undefined)}
			case "cancel":
				steps = []shpStep{refProbe("c1", "touch '"+marker+"' && sleep 10")}
			}
			f := newRefFx(t, refOpts{approved: true, source: true}, steps...)
			before := f.pkg()
			index := f.index()
			receipt := f.read(".kogen/local/provenance/is-even/current.json")
			if kind == "cancel" {
				done := f.refineAsync(f.hash0)
				refWaitFile(t, marker)
				// approval takes the Build lock too: refused while the refinement runs
				f2 := f.S
				asession := sys.NewWith(f.Env, f.Root)
				var out strings.Builder
				asession.Stdout, asession.Stderr = &out, &out
				exit, err := Approve(context.Background(), asession, ApproveInput{Project: f.Root, Slug: shpSlug})
				shpWantError(t, err, "environment", "build_running", "", 3)
				shpEq(t, "approve exit", exit, 3)
				f2.Interrupt("SIGINT")
				r := refWait(t, done)
				var i *sys.Interrupted
				if !errors.As(r.err, &i) || i.Signal != "SIGINT" || r.exit != 130 {
					t.Fatalf("exit %d, err %v", r.exit, r.err)
				}
			} else {
				exit, err := f.refine(f.hash0)
				if err == nil || exit == 0 {
					t.Fatalf("exit %d, err %v", exit, err)
				}
			}
			refEqual(t, "package", f.pkg(), before)
			refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), f.approval)
			shpEq(t, "index", f.index() == index, true)
			shpEq(t, "receipt", f.read(".kogen/local/provenance/is-even/current.json"), receipt)
			refNoScratch(t, f)
		})
	}
}

func TestRefineFailedApprovalRevocationRestoresAReadOnlyArtifactAndRetainsApproval(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "probe-started")
	f := newRefFx(t, refOpts{approved: true},
		refProbe("c1", "touch '"+marker+"' && sleep 1"),
		refSubmit("c2", refIntentPath, refTitled),
	)
	before := f.pkg()
	index := f.index()
	done := f.refineAsync(f.hash0)
	refWaitFile(t, marker)
	// The scratch candidate is already copied; the live destination becomes read-only before
	// publication, which can still replace it through its writable directory.
	if err := os.Chmod(filepath.Join(f.Root, refIntentPath), 0o444); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(f.Root, refIntentPath))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(f.evidence(), "revoked-approval.json"), 0o755); err != nil {
		t.Fatal(err)
	}
	r := refWait(t, done)
	if r.err == nil || r.exit == 0 {
		t.Fatalf("exit %d, err %v", r.exit, r.err)
	}
	refEqual(t, "package", f.pkg(), before)
	st, err := os.Stat(filepath.Join(f.Root, refIntentPath))
	if err != nil || st.Mode() != fi.Mode() {
		t.Fatalf("mode = %v, want %v (%v)", st.Mode(), fi.Mode(), err)
	}
	refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), f.approval)
	shpEq(t, "index", f.index() == index, true)
	shpEq(t, "outcome", f.result()["outcome"], any("failed"))
}

func TestRefineChangesToHeadRawApprovalOrIndexPreventApprovedPublication(t *testing.T) {
	for _, kind := range []string{"head", "approval", "index"} {
		t.Run(kind, func(t *testing.T) {
			marker := filepath.Join(t.TempDir(), "probe-started")
			f := newRefFx(t, refOpts{approved: true},
				refProbe("c1", "touch '"+marker+"' && sleep 1"),
				refSubmit("c2", refIntentPath, refTitled),
			)
			before := f.pkg()
			done := f.refineAsync(f.hash0)
			refWaitFile(t, marker)
			switch kind {
			case "head":
				f.git("commit", "--allow-empty", "-qm", "External HEAD")
			case "approval":
				f.write(".kogen/local/approvals/is-even.json", f.approval+"\n")
			case "index":
				f.git("add", refFeaturePath)
			}
			approval := f.read(".kogen/local/approvals/is-even.json")
			index := f.index()
			r := refWait(t, done)
			shpWantError(t, r.err, "intent", "refinement_stale", "", 1)
			shpEq(t, "exit", r.exit, 1)
			refEqual(t, "package", f.pkg(), before)
			refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), approval)
			shpEq(t, "index", f.index() == index, true)
		})
	}
}

func TestRefineAnExternalEditWhileRefiningIsPreservedAndPreventsPublication(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "probe-started")
	f := newRefFx(t, refOpts{},
		refProbe("c1", "touch '"+marker+"' && sleep 1"),
		refSubmit("c2", refIntentPath, refTitled),
	)
	before := f.pkg()
	done := f.refineAsync(f.hash0)
	refWaitFile(t, marker)
	// approval is refused while the refinement holds the Build lock
	asession := sys.NewWith(f.Env, f.Root)
	var out strings.Builder
	asession.Stdout, asession.Stderr = &out, &out
	_, err := Approve(context.Background(), asession, ApproveInput{Project: f.Root, Slug: shpSlug})
	shpWantError(t, err, "environment", "build_running", "", 3)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("no approval while refining")
	}
	external := before[refFeaturePath] + "\n# external edit\n"
	f.write(refFeaturePath, external)
	r := refWait(t, done)
	shpWantError(t, r.err, "intent", "refinement_stale", "", 1)
	shpEq(t, "exit", r.exit, 1)
	refEqual(t, "package", f.pkg(), refWith(before, refFeaturePath, external))
}

func TestRefineInterruptionDuringAProbePreservesThePackageAndRetainsEvidence(t *testing.T) {
	for _, c := range []struct {
		signal string
		exit   int
	}{{"SIGINT", 130}, {"SIGTERM", 143}, {"SIGHUP", 129}} {
		t.Run(c.signal, func(t *testing.T) {
			marker := filepath.Join(t.TempDir(), "probe-started")
			f := newRefFx(t, refOpts{approved: true}, refProbe("c1", "touch '"+marker+"' && sleep 10"))
			before := f.pkg()
			done := f.refineAsync(f.hash0)
			refWaitFile(t, marker)
			f.S.Interrupt(c.signal)
			r := refWait(t, done)
			var i *sys.Interrupted
			if !errors.As(r.err, &i) || i.Signal != c.signal || r.exit != c.exit {
				t.Fatalf("exit %d, err %v", r.exit, r.err)
			}
			refEqual(t, "package", f.pkg(), before)
			refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), f.approval)
			result := f.result()
			shpEq(t, "outcome", result["outcome"], any("interrupted"))
			shpEq(t, "signal", result["signal"], any(c.signal))
			probes := shpNamed(f.evidenceEvents(), "probe_result")
			shpEq(t, "probes", len(probes), 1)
			shpEq(t, "probe status", probes[0]["status"], any("cancelled"))
			shpEq(t, "session ends", len(shpNamed(f.evidenceEvents(), "session_end")), 1)
			refNoScratch(t, f)
			if f.exists(".kogen/local/build.lock") {
				t.Fatal("the Build lock is released")
			}
		})
	}
}

// ---- probes ----

func TestRefineLocalIgnoredWarmthStaysAvailableToProbesButOutOfFinalProof(t *testing.T) {
	for _, mode := range []string{"info/exclude", "core.excludesFile"} {
		t.Run(mode, func(t *testing.T) {
			f := newRefFx(t, refOpts{approved: true},
				refProbe("c1", "cat local-cache/warm.txt"),
				refSubmit("c2", refIntentPath, refTitled),
			)
			switch mode {
			case "info/exclude":
				if err := os.WriteFile(filepath.Join(f.Root, ".git/info/exclude"), []byte("local-cache/\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			default:
				exclude := filepath.Join(f.Aux, "local-excludes")
				os.WriteFile(exclude, []byte("local-cache/\n"), 0o644)
				f.git("config", "core.excludesFile", exclude)
			}
			f.write("local-cache/warm.txt", "workspace only\n")
			before := f.pkg()
			index := f.index()
			exit, err := f.refine(f.hash0)
			if err != nil || exit != 0 {
				t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
			}
			refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
			shpEq(t, "index", f.index() == index, true)
			refText(t, "warmth", f.read("local-cache/warm.txt"), "workspace only\n")
			shpContains(t, "probe output", shpOutputs(f.Prov.requests()[1])["c1"], "workspace only")
			var rec map[string]any
			if err := json.Unmarshal([]byte(f.read(".kogen/local/readiness/is-even.json")), &rec); err != nil {
				t.Fatal(err)
			}
			for _, sc := range rec["scenarios"].([]any) {
				shpEq(t, "scenario", sc.(map[string]any)["status"], any("passed"))
			}
			tree := f.git("ls-tree", "-r", "--name-only", rec["candidate_tree"].(string))
			if strings.Contains(tree, "local-cache") {
				t.Fatalf("warmth is part of the proof tree:\n%s", tree)
			}
			// a card afterwards reuses the record
			record := f.read(".kogen/local/readiness/is-even.json")
			f.newSession()
			if exit, err := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug}); err != nil || exit != 5 {
				t.Fatalf("card: exit %d, err %v", exit, err)
			}
			refText(t, "record", f.read(".kogen/local/readiness/is-even.json"), record)
		})
	}
}

func TestRefineProbeRunsInTheScratchCopyWithTheProposalApplied(t *testing.T) {
	unsourced := strings.Replace(shpIntentMD, "- Non-integers raise TypeError. (source: request)", "- Non-integers raise TypeError.", 1)
	f := newRefFx(t, refOpts{},
		refSubmit("c1", refFeaturePath, refFeatured, refIntentPath, unsourced),
		refProbe("c2", "grep -c 'Is even corrected' .kogen/intents/is-even/acceptance.feature; pwd -P"),
		refConstraint("c3", "needs unsupported work"),
	)
	before := f.pkg()
	exit, err := f.refine(f.hash0)
	shpWantError(t, err, "shape", "refinement_constraint", "needs unsupported work The original draft is preserved.", 1)
	shpEq(t, "exit", exit, 1)
	out := shpOutputs(f.Prov.requests()[2])["c2"]
	shpContains(t, "probe output", out, "exit status: 0\ntimed_out: false\nwall: ")
	shpContains(t, "probe output", out, "\n1\n")
	if strings.Contains(out, f.Root+"\n") {
		t.Fatalf("the probe ran in the project:\n%s", out)
	}
	refEqual(t, "package", f.pkg(), before)
	probes := shpNamed(f.evidenceEvents(), "probe_result")
	shpEq(t, "probe events", len(probes), 1)
	shpEq(t, "probe status", probes[0]["status"], any("completed"))
	// the manifest of the next request shows the proposal's scratch copy
	shpContains(t, "manifest", shpBody(f.Prov.requests()[1]), `"submitted_sha256":"`+ContentHash([]byte(refFeatured))+`"`)
}

// ---- source provenance ----

func TestRefineRecordsTheCorrectionInTheSourceReceipt(t *testing.T) {
	f := newRefFx(t, refOpts{source: true, approved: true}, refSubmit("c1", refIntentPath, strings.Replace(refTitled, "- The request asks for is_even; the feature covers it.", "- The correction is addressed; the request is superseded where it conflicts.", 1)))
	receiptPath := filepath.Join(f.Root, ".kogen/local/provenance/is-even/current.json")
	original, err := os.ReadFile(receiptPath)
	if err != nil {
		t.Fatal(err)
	}
	var approval map[string]any
	if err := json.Unmarshal([]byte(f.approval), &approval); err != nil || approval["source_provenance"] == nil {
		t.Fatalf("approval binds no source: %v, %v", approval, err)
	}
	exit, err := f.refine(f.hash0)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpContains(t, "request", shpBody(f.Prov.requests()[0]), "Diagnostic source provenance (not authority): "+receiptPath)
	var doc map[string]any
	b, err := os.ReadFile(receiptPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	corrections := doc["corrections"].([]any)
	shpEq(t, "corrections", len(corrections), 1)
	c := corrections[0].(map[string]any)
	shpEq(t, "correction text", c["text"], any("Clarify only the existing draft; preserve its executable contract."))
	shpEq(t, "correction path", c["source_path"], any(filepath.Join(f.Aux, "correction.txt")))
	shpEq(t, "correction sha", c["sha256"], any(ContentHash([]byte("Clarify only the existing draft; preserve its executable contract."))))
	shpEq(t, "prior contract", c["prior_contract_sha256"], any(f.hash0))
	shpEq(t, "contract", doc["contract_sha256"], any(f.hash()))
	shpEq(t, "comparison", doc["comparison"], any("- The correction is addressed; the request is superseded where it conflicts."))
	req := doc["request"].(map[string]any)
	shpEq(t, "original request kept", req["text"], any("Add calc.is_even(n)."))
	// the previous receipt is archived under its hash
	archives, _ := filepath.Glob(filepath.Join(f.Root, ".kogen/local/provenance/is-even/*"))
	found := false
	for _, a := range archives {
		if ab, err := os.ReadFile(a); err == nil && string(ab) == string(original) {
			found = true
		}
	}
	if !found {
		t.Fatalf("the prior receipt is not archived: %v", archives)
	}
	// a fresh approval binds the new receipt
	f.newSession()
	if exit, err := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Hash: f.hash()}); err != nil || exit != 0 {
		t.Fatalf("approve: exit %d, err %v", exit, err)
	}
}

func TestRefineRefusesChangedOrDeletedBoundSourceDuringInferenceWithoutPublishingOrRevoking(t *testing.T) {
	for _, drift := range []string{"changed", "deleted"} {
		t.Run(drift, func(t *testing.T) {
			f := newRefFx(t, refOpts{source: true, approved: true})
			before := f.pkg()
			index := f.index()
			head := f.head()
			source := filepath.Join(f.Root, ".kogen/local/provenance/is-even/current.json")
			paused, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			step := refSubmit("c1", refIntentPath, before[refIntentPath]+"\nClarified only.\n")
			f.Prov.route = func(req map[string]any) *shpStep {
				once.Do(func() { close(paused) })
				<-release
				return &step
			}
			done := f.refineAsync(f.hash0)
			select {
			case <-paused:
			case <-time.After(30 * time.Second):
				t.Fatal("the provider was never asked")
			}
			if drift == "changed" {
				b, _ := os.ReadFile(source)
				os.WriteFile(source, append(b, ' '), 0o600)
			} else {
				os.Remove(source)
			}
			drifted, driftErr := os.ReadFile(source)
			close(release)
			r := refWait(t, done)
			shpWantError(t, r.err, "candidate", "source_provenance_changed", "", 1)
			shpEq(t, "exit", r.exit, 1)
			refEqual(t, "package", f.pkg(), before)
			refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), f.approval)
			shpEq(t, "index", f.index() == index, true)
			shpEq(t, "head", f.head(), head)
			again, againErr := os.ReadFile(source)
			shpEq(t, "source untouched", string(again) == string(drifted) && (driftErr == nil) == (againErr == nil), true)
		})
	}
}

func TestRefineSourceReceiptThatIsNotBoundIsRefusedBeforeTheModel(t *testing.T) {
	f := newRefFx(t, refOpts{source: true})
	source := filepath.Join(f.Root, ".kogen/local/provenance/is-even/current.json")
	if err := os.Chmod(source, 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := f.refine(f.hash0)
	shpWantError(t, err, "candidate", "source_provenance_changed", "", 1)
	refRequestMissing(t, f)
}

// ---- the session's own cancellation ----

func TestRefineStopsWhenTheContextIsCancelled(t *testing.T) {
	f := newRefFx(t, refOpts{}, refSubmit("c1", refIntentPath, refTitled))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f.newSession()
	exit, err := Refine(ctx, f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0, Request: "x", Client: f.Client})
	if err == nil || exit == 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	refText(t, "intent", f.read(refIntentPath), shpIntentMD)
}

// ---- source receipts: historical contract, pinned approval, rollback ----

func receiptOf(f *refFx) string { return f.read(".kogen/local/provenance/is-even/current.json") }

func TestRefineOfAHistoricalContractResolvesTheStaleMarkersReceiptAndKeepsThePredecessor(t *testing.T) {
	f := newRefFx(t, refOpts{approved: true, source: true})
	original := receiptOf(f)
	f.write(refIntentPath, f.read(refIntentPath)+"\nCurrent draft.\n")
	updated := f.read(refIntentPath) + "\nClarified only.\n"
	f.Prov.mu.Lock()
	f.Prov.seq = []shpStep{refSubmit("c1", refIntentPath, updated)}
	f.Prov.mu.Unlock()
	exit, err := f.refine(f.hash())
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	var current map[string]any
	if err := json.Unmarshal([]byte(receiptOf(f)), &current); err != nil {
		t.Fatal(err)
	}
	previous, _ := current["previous_receipt"].(map[string]any)
	if previous["sha256"] != ContentHash([]byte(original)) || f.read(strings.TrimPrefix(previous["path"].(string), f.Root+"/")) != original {
		t.Fatalf("previous_receipt %v does not hold the receipt Refine started from", previous)
	}
	if current["contract_sha256"] != f.hash() {
		t.Fatalf("contract %v, want the refined %s", current["contract_sha256"], f.hash())
	}
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("the stale marker is revoked")
	}
}

func TestRefineRefusesAMarkerWhoseReceiptPointerIsNotThePinnedCurrentOne(t *testing.T) {
	f := newRefFx(t, refOpts{approved: true, source: true})
	var marker map[string]any
	if err := json.Unmarshal([]byte(f.approval), &marker); err != nil {
		t.Fatal(err)
	}
	ref := marker["source_provenance"].(map[string]any)
	ref["sha256"] = "not-a-digest"
	b, _ := json.Marshal(marker)
	f.write(".kogen/local/approvals/is-even.json", string(b)+"\n")
	before := f.pkg()
	_, err := f.refine(f.hash())
	shpWantError(t, err, "candidate", "source_provenance_changed", "source provenance custody missing, changed or unsafe: ", 1)
	refEqual(t, "package", f.pkg(), before)
	refRequestMissing(t, f)
}

func TestRefineRollsBackItsReceiptWhenTheCheckoutChangesDuringPublication(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "probe-started")
	f := newRefFx(t, refOpts{approved: true, source: true},
		refProbe("c1", "touch '"+marker+"' && sleep 1"),
		refSubmit("c2", refIntentPath, refTitled))
	original := receiptOf(f)
	before := f.pkg()
	done := f.refineAsync(f.hash0)
	refWaitFile(t, marker)
	// An unrelated committed change moves HEAD before publication: nothing may publish.
	f.write("other.txt", "moved\n")
	f.git("add", "other.txt")
	f.git("commit", "-qm", "move head")
	r := refWait(t, done)
	if r.err == nil || r.exit == 0 {
		t.Fatalf("exit %d, err %v", r.exit, r.err)
	}
	refEqual(t, "package", f.pkg(), before)
	shpEq(t, "receipt", receiptOf(f), original)
	refText(t, "approval", f.read(".kogen/local/approvals/is-even.json"), f.approval)
}
