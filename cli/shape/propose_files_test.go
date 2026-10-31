package shape

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"kogen/agent"
	"kogen/executor"
)

const (
	pfIntentPath  = ".kogen/intents/is-even/intent.md"
	pfFeaturePath = ".kogen/intents/is-even/acceptance.feature"
	pfStepsPath   = "features/steps/is_even_steps.js"
	pfCustody     = ".kogen/local/shaping/is-even/proposed/"

	pfNativeTools = "read_file, view_image, list_files, search_text, probe, documentation, propose_files, submit"
)

// pfIntentDraft is a first, shorter version of the Intent that later proposals replace.
var pfIntentDraft = strings.Replace(shpIntentMD, "calc.is_even(n) returns True for even integers.", "Draft: is_even is to be written.", 1)

func pfFile(path, content string) map[string]any {
	return map[string]any{"path": path, "content": content}
}

// pfPropose is one answer that proposes files; a first call also reads the README.
func pfPropose(id string, files ...map[string]any) shpStep {
	list := make([]any, len(files))
	for i, f := range files {
		list[i] = f
	}
	return shpAnswer(shpCall(id, "propose_files", map[string]any{"files": list}))
}

func pfInspectAnd(step shpStep) shpStep {
	items := append([]map[string]any{shpCall("inspect", "read_file", map[string]any{"path": "README.md"})}, step.items...)
	return shpAnswer(items...)
}

func pfRetained(paths string, n int) string {
	return fmt.Sprintf("retained: %s; %d proposed file(s) in all. Nothing was checked: submit to check the complete package.", paths, n)
}

func pfInvalid(problems ...string) string {
	return "invalid proposal:\n" + strings.Join(problems, "\n") + "\nNo files from this call were retained; earlier proposals are unchanged."
}

// pfWatch runs check at the arrival of each request with its number (from 1), before the scripted
// answer is chosen; the scripted sequence still answers.
type pfWatch struct {
	mu     sync.Mutex
	checks map[int]func(req map[string]any)
	seen   int
}

func (f *shpFx) watch(checks map[int]func(req map[string]any)) {
	w := &pfWatch{checks: checks}
	f.Prov.route = func(req map[string]any) *shpStep {
		w.mu.Lock()
		w.seen++
		n := w.seen
		w.mu.Unlock()
		if check := w.checks[n]; check != nil {
			check(req)
		}
		return nil
	}
}

// custody is the content of a proposal in private custody, "" when absent.
func (f *shpFx) custody(path string) string {
	b, err := os.ReadFile(filepath.Join(f.Root, pfCustody, path))
	if err != nil {
		return ""
	}
	return string(b)
}

func pfEventPaths(t *testing.T, e map[string]any) string {
	t.Helper()
	list, _ := e["paths"].([]any)
	var out []string
	for _, p := range list {
		out = append(out, fmt.Sprint(p))
	}
	return strings.Join(out, ", ")
}

func TestProposeFilesStagesPackage(t *testing.T) {
	parallel(t)
	f := newShpFx(t,
		pfInspectAnd(pfPropose("p1", pfFile(pfIntentPath, pfIntentDraft))),
		pfPropose("p2", pfFile(pfFeaturePath, shpFeature)),
		pfPropose("p3", pfFile(pfStepsPath, shpSteps), pfFile(pfIntentPath, shpIntentMD)),
		shpAnswer(shpCall("s1", "submit", map[string]any{"files": []any{pfFile(pfIntentPath, shpIntentMD)}})),
		shpAck("ack"))

	var mu sync.Mutex
	var problems []string
	fail := func(format string, args ...any) {
		mu.Lock()
		problems = append(problems, fmt.Sprintf(format, args...))
		mu.Unlock()
	}
	custodyIs := func(n int, want map[string]string) func(map[string]any) {
		return func(map[string]any) {
			for p, c := range want {
				if got := f.custody(p); got != c {
					fail("request %d: custody of %s = %q, want %q", n, p, got, c)
				}
			}
		}
	}
	var runsAtStart atomic.Int64 // the acceptance runner is checked once before the first request
	f.watch(map[int]func(map[string]any){
		1: func(map[string]any) { runsAtStart.Store(int64(f.runs())) },
		2: custodyIs(2, map[string]string{pfIntentPath: pfIntentDraft}),
		3: custodyIs(3, map[string]string{pfIntentPath: pfIntentDraft, pfFeaturePath: shpFeature}),
		4: func(req map[string]any) {
			custodyIs(4, map[string]string{pfIntentPath: shpIntentMD, pfFeaturePath: shpFeature, pfStepsPath: shpSteps})(req)
			if n := f.runs(); int64(n) != runsAtStart.Load() {
				fail("request 4: the acceptance command ran %d time(s) since the first request, before submit", int64(n)-runsAtStart.Load())
			}
			for _, p := range []string{pfIntentPath, pfStepsPath} {
				if f.exists(p) {
					fail("request 4: %s was written into the checkout", p)
				}
			}
		},
	})

	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s\n%s", exit, err, f.Stdout, f.Stderr)
	}
	for _, p := range problems {
		t.Error(p)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 5)
	for i, r := range reqs {
		shpEq(t, fmt.Sprintf("request %d tools", i+1), strings.Join(shpToolNames(r), ", "), pfNativeTools)
	}
	shpEq(t, "output 1", shpOutputs(reqs[1])["p1"], pfRetained(pfIntentPath, 1))
	shpEq(t, "output 2", shpOutputs(reqs[2])["p2"], pfRetained(pfFeaturePath, 2))
	shpEq(t, "output 3", shpOutputs(reqs[3])["p3"], pfRetained(pfIntentPath+", "+pfStepsPath, 3))
	shpEq(t, "output 3 again", shpOutputs(reqs[4])["p3"], pfRetained(pfIntentPath+", "+pfStepsPath, 3))

	events := shpNamed(f.events(), "proposal_retained")
	shpEq(t, "proposal_retained events", len(events), 3)
	for i, want := range []struct {
		paths string
		n     float64
	}{{pfIntentPath, 1}, {pfFeaturePath, 2}, {pfIntentPath + ", " + pfStepsPath, 3}} {
		shpEq(t, fmt.Sprintf("event %d paths", i+1), pfEventPaths(t, events[i]), want.paths)
		shpEq(t, fmt.Sprintf("event %d proposed", i+1), events[i]["proposed"], any(want.n))
	}
	shpEq(t, "refusals", len(shpNamed(f.events(), "submission_refused")), 0)

	stderr := f.Stderr.String()
	shpMatch(t, "progress 1", stderr, `(?m)^kogen: shape proposal retained: \Q`+pfIntentPath+`\E \(1 proposed file\(s\)\) \(\d+ s\)$`)
	shpMatch(t, "progress 2", stderr, `(?m)^kogen: shape proposal retained: \Q`+pfFeaturePath+`\E \(2 proposed file\(s\)\) \(\d+ s\)$`)
	shpMatch(t, "progress 3", stderr, `(?m)^kogen: shape proposal retained: \Q`+pfIntentPath+", "+pfStepsPath+`\E \(3 proposed file\(s\)\) \(\d+ s\)$`)

	shpEq(t, "intent", f.read(pfIntentPath), shpIntentMD)
	shpEq(t, "feature", f.read(pfFeaturePath), shpFeature)
	shpEq(t, "steps", f.read(pfStepsPath), shpSteps)
}

func TestProposeFilesRefusals(t *testing.T) {
	parallel(t)
	const unsafe = "calc.js: shaping may write only .kogen/intents/is-even/{intent.md,acceptance.feature,model.qnt} and step files under features/steps/"
	f := newShpFx(t,
		pfInspectAnd(shpAnswer(shpCall("e1", "propose_files", map[string]any{"files": []any{}}))),
		pfPropose("v1", pfFile(pfIntentPath, shpIntentMD)),
		pfPropose("u1", pfFile("calc.js", "x")),
		pfPropose("m1", pfFile(pfFeaturePath, shpFeature), pfFile("calc.js", "x")),
		pfPropose("d1", pfFile(pfFeaturePath, shpFeature), pfFile(pfFeaturePath, "other")),
		shpAnswer(shpCall("n1", "propose_files", map[string]any{})),
		shpAnswer(shpCall("s1", "submit", map[string]any{"files": []any{pfFile(pfFeaturePath, shpFeature), pfFile(pfStepsPath, shpSteps)}})),
		shpAck("ack"))

	var mu sync.Mutex
	var problems []string
	f.watch(map[int]func(map[string]any){
		3: func(map[string]any) {
			if got := f.custody(pfIntentPath); got != shpIntentMD {
				mu.Lock()
				problems = append(problems, fmt.Sprintf("custody of the valid proposal = %q", got))
				mu.Unlock()
			}
		},
		7: func(map[string]any) {
			for _, p := range []string{pfFeaturePath, "calc.js"} {
				if got := f.custody(p); got != "" {
					mu.Lock()
					problems = append(problems, fmt.Sprintf("custody holds a refused %s: %q", p, got))
					mu.Unlock()
				}
			}
		},
	})

	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s\n%s", exit, err, f.Stdout, f.Stderr)
	}
	for _, p := range problems {
		t.Error(p)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 8)
	empty := pfInvalid("propose_files takes a non-empty files list")
	shpEq(t, "empty files", shpOutputs(reqs[1])["e1"], empty)
	shpEq(t, "valid proposal", shpOutputs(reqs[2])["v1"], pfRetained(pfIntentPath, 1))
	shpEq(t, "unsafe path", shpOutputs(reqs[3])["u1"], pfInvalid(unsafe))
	shpEq(t, "mixed payload", shpOutputs(reqs[4])["m1"], pfInvalid(unsafe))
	shpEq(t, "duplicate paths", shpOutputs(reqs[5])["d1"], pfInvalid("file paths must be unique; no proposals from this submission were retained"))
	shpEq(t, "missing files", shpOutputs(reqs[6])["n1"], empty)

	events := f.events()
	shpEq(t, "retained events", len(shpNamed(events, "proposal_retained")), 1)
	shpEq(t, "submission_refused events", len(shpNamed(events, "submission_refused")), 0)
	counts := shpNamed(events, "shaping_turn_counts")
	if len(counts) != 1 || counts[0]["invalid_submissions"] != any(float64(0)) {
		t.Fatalf("turn counts %v", counts)
	}
	shpEq(t, "intent", f.read(pfIntentPath), shpIntentMD)
	shpEq(t, "feature", f.read(pfFeaturePath), shpFeature)
	shpEq(t, "steps", f.read(pfStepsPath), shpSteps)
}

// pfIncomplete is a stream the provider cuts off at its output limit.
func pfIncomplete() shpStep {
	return shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		shpFrame(w, map[string]any{"type": "response.incomplete", "response": map[string]any{
			"id": "resp-cut", "incomplete_details": map[string]any{"reason": "max_output_tokens"},
		}})
	}}
}

func TestProposeFilesCutOffReply(t *testing.T) {
	parallel(t)
	const detail = "shaping stopped on a provider error after its retries; the failed request wrote no files. Rerun kogen intent shape is-even - with the original request on stdin (or the same answers if questions are pending), or write the Intent yourself."

	t.Run("earlier proposals are kept and named", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t,
			pfInspectAnd(pfPropose("p1", pfFile(pfIntentPath, shpIntentMD))),
			pfPropose("p2", pfFile(pfFeaturePath, shpFeature)),
			pfIncomplete())
		exit, err := f.shape("Add calc.is_even(n).")
		shpEq(t, "exit", exit, 4)
		shpWantError(t, err, "shape", "provider_failed", detail, 4)
		shpEq(t, "requests", len(f.Prov.requests()), 3)
		kept := "kogen: shaping kept 2 proposed file(s) under " + pfCustody + ": " + pfFeaturePath + ", " + pfIntentPath + "\n"
		out := f.Stdout.String()
		shpEq(t, "kept lines", strings.Count(out, "kogen: shaping kept"), 1)
		if !strings.HasSuffix(out, kept) || strings.Index(out, "provider/") < 0 || strings.Index(out, "provider/") > strings.Index(out, kept) {
			t.Fatalf("stdout %q does not end with the kept line after the provider error", out)
		}
		shpEq(t, "custody intent", f.custody(pfIntentPath), shpIntentMD)
		shpEq(t, "custody feature", f.custody(pfFeaturePath), shpFeature)
		if f.exists(".kogen/intents/is-even") || f.exists(pfStepsPath) {
			t.Fatal("a proposal was written into the checkout")
		}
	})

	t.Run("a provider failure before any proposal names nothing", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t, pfIncomplete())
		exit, err := f.shape("Add calc.is_even(n).")
		shpEq(t, "exit", exit, 4)
		shpWantError(t, err, "shape", "provider_failed", detail, 4)
		if strings.Contains(f.Stdout.String(), "shaping kept") {
			t.Fatalf("stdout %q", f.Stdout)
		}
		if f.exists(pfCustody) {
			t.Fatal("custody exists without a proposal")
		}
	})
}

func TestProposeFilesDroppedStream(t *testing.T) {
	parallel(t)
	dropped := shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler)
	}}
	f := newShpFx(t,
		pfInspectAnd(pfPropose("p1", pfFile(pfIntentPath, shpIntentMD), pfFile(pfFeaturePath, shpFeature))),
		dropped,
		shpAnswer(shpCall("p2", "propose_files", map[string]any{"files": []any{pfFile(pfStepsPath, shpSteps)}}),
			shpCall("s1", "submit", map[string]any{"files": []any{pfFile(pfIntentPath, shpIntentMD)}})),
		shpAck("ack"))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s\n%s", exit, err, f.Stdout, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 4)
	if !reflect.DeepEqual(reqs[1]["input"], reqs[2]["input"]) {
		t.Fatal("the retried request does not carry the dropped request's input")
	}
	shpEq(t, "retained output", shpOutputs(reqs[2])["p1"], pfRetained(pfFeaturePath+", "+pfIntentPath, 2))
	body := shpBody(reqs[2])
	shpContains(t, "retried request", body, "propose_files")
	shpEq(t, "step output", shpOutputs(reqs[3])["p2"], pfRetained(pfStepsPath, 3))
	shpEq(t, "proposal events", len(shpNamed(f.events(), "proposal_retained")), 2)
	shpEq(t, "intent", f.read(pfIntentPath), shpIntentMD)
	shpEq(t, "feature", f.read(pfFeaturePath), shpFeature)
	shpEq(t, "steps", f.read(pfStepsPath), shpSteps)
}

func TestProposeFilesNativeOnly(t *testing.T) {
	parallel(t)

	t.Run("workers follow submit in the native list", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t, shpAnswer(shpCall("q", "submit", map[string]any{"questions": []any{shpQuestion("Which?")}})))
		f.withWorkers()
		if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 5 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 1)
		shpEq(t, "tools", strings.Join(shpToolNames(reqs[0]), ", "), "read_file, view_image, list_files, search_text, probe, documentation, propose_files, submit, shape_batch")
	})

	t.Run("refine does not offer it", func(t *testing.T) {
		parallel(t)
		f := newRefFx(t, refOpts{approved: true}, refSubmit("c1", refIntentPath, refTitled))
		if exit, err := f.refine(f.hash0); err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 1)
		names := strings.Join(shpToolNames(reqs[0]), ", ")
		shpEq(t, "tools", names, "read_file, list_files, search_text, probe, documentation, submit_refinement")
	})

	t.Run("the external shaper names it unavailable and keeps submit's schema", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t)
		f.useExternalShape(6)
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(shpFiles()), result(map[string]any{"files": []any{
			map[string]any{"path": pfFeaturePath, "content": shpFeature}}})}}
		if exit, err := f.shapeWith(x, "Add calc.is_even(n)."); err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		task := x.starts[0]
		shpContains(t, "task", task.Brief.Stable, "(probe, view_image, documentation records, shape_batch, propose_files)")
		var got, want any
		if err := json.Unmarshal(task.Schema, &got); err != nil {
			t.Fatal(err)
		}
		b, _ := json.Marshal(agent.Defs(agent.SubmitTool)[0]["parameters"])
		json.Unmarshal(b, &want)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("schema %s differs from submit's parameters %s", task.Schema, b)
		}
		if n := len(f.Prov.requests()); n != 0 {
			t.Fatalf("%d native requests", n)
		}
	})
}
