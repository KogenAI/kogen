package shape

import (
	"context"
	"encoding/json"
	"fmt"
	"kogen-loop/tools"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
)

const shpWorkersConfig = "version: 1\ncommands:\n  checks: [{name: unit, run: 'true'}]\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\nprotect: [guard.txt]\nshape_workers:\n  enabled: true\n  read: {model: luna, effort: medium}\n  probe: {model: luna, effort: medium}\n  draft: {model: luna, effort: max}\n"

// withWorkers enables shape workers in the committed project configuration.
func (f *shpFx) withWorkers() {
	f.t.Helper()
	f.write("guard.txt", "protected")
	f.write(".kogen/project.yaml", shpWorkersConfig)
	f.git("add", "-A")
	f.git("commit", "-qm", "workers")
}

// shaping is the state a batch validates against, for a project that has no Intent yet.
func (f *shpFx) shaping() *shaping {
	f.t.Helper()
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		f.t.Fatal(err)
	}
	return &shaping{s: f.S, repo: f.Repo, root: f.Root, slug: shpSlug, cfg: cfg, ev: f.evidence(), client: f.Client,
		originals: map[string]original{}, proposed: map[string]string{}}
}

func (f *shpFx) evidence() *Evidence {
	f.t.Helper()
	ev, err := NewEvidence(filepath.Join(f.Root, ".kogen/local/shaping", shpSlug), shpSlug)
	if err != nil {
		f.t.Fatal(err)
	}
	return ev
}

// brief is a complete shared brief for the checkout as it is now.
func (f *shpFx) brief(artifacts ...string) map[string]any {
	f.t.Helper()
	rev, err := CurrentRevision(f.Repo)
	if err != nil {
		f.t.Fatal(err)
	}
	list := []any{}
	for _, a := range artifacts {
		list = append(list, map[string]any{"path": a, "expectation": "agreement"})
	}
	return map[string]any{
		"revision": map[string]any{"head": rev.Head, "tree": rev.Tree}, "outcomes": "literal input", "interfaces": "exact output",
		"transitions": "stateless", "fixtures": "runner and red baseline", "exclusions": "no authority",
		"protected_paths": []any{".kogen/project.yaml", "guard.txt"}, "artifacts": list,
	}
}

func shpJob(id, role string, paths []any, owns ...string) map[string]any {
	o := []any{}
	for _, p := range owns {
		o = append(o, p)
	}
	return map[string]any{"id": id, "role": role, "scope": "one exact independent task", "paths": paths, "owns": o}
}

// workerJobID is the id of the job a worker request is for, "" for the main conversation.
func workerJobID(req map[string]any) string {
	isWorker := false
	for _, n := range shpToolNames(req) {
		isWorker = isWorker || n == "worker_result"
	}
	if !isWorker {
		return ""
	}
	input, _ := req["input"].([]any)
	first, _ := input[0].(map[string]any)
	text, _ := first["content"].(string)
	if blocks, ok := first["content"].([]any); ok && len(blocks) > 0 {
		block, _ := blocks[0].(map[string]any)
		text, _ = block["text"].(string)
	}
	var doc struct{ Job struct{ ID string } }
	json.Unmarshal([]byte(text), &doc)
	return doc.Job.ID
}

func shpWorkerResult(id, evidence string, files ...map[string]any) shpStep {
	list := []any{}
	for _, f := range files {
		list = append(list, f)
	}
	return shpAnswer(shpCall(id, "worker_result", map[string]any{"evidence": evidence, "files": list}))
}

// batchResult is the shape_batch result the next main request carries.
func batchResult(t *testing.T, req map[string]any, callID string) map[string]any {
	t.Helper()
	text := shpOutputs(req)[callID]
	var out map[string]any
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("batch result %q: %v", text, err)
	}
	return out
}

func TestShapeBatchRunsWorkersAndReturnsTheirResults(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.withWorkers()
	brief := f.brief("features/steps/draft.js")
	jobs := []any{shpJob("inspect", "probe", []any{"app.txt"}), shpJob("draft", "draft", []any{}, "features/steps/draft.js")}
	draft := map[string]any{"path": "features/steps/draft.js", "content": "// drafted\n"}
	f.Prov.route = func(req map[string]any) *shpStep {
		switch workerJobID(req) {
		case "inspect":
			if len(shpOutputs(req)) == 0 {
				st := shpAnswer(shpCall("w1", "read_file", map[string]any{"path": "app.txt"}), shpCall("w2", "probe", map[string]any{"command": "printf focused"}))
				return &st
			}
			st := shpWorkerResult("w3", "inspected the fixture")
			return &st
		case "draft":
			st := shpWorkerResult("d1", "drafted the step", draft)
			return &st
		}
		return nil
	}
	f.Prov.seq = []shpStep{
		shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": brief, "jobs": jobs})),
		shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}),
	}
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	var main, workers []map[string]any
	for _, r := range reqs {
		if workerJobID(r) == "" {
			main = append(main, r)
		} else {
			workers = append(workers, r)
		}
	}
	shpEq(t, "main requests", len(main), 2)
	shpEq(t, "worker requests", len(workers), 3)
	shpEq(t, "main tools", strings.Join(shpToolNames(main[0]), ", "), "read_file, view_image, list_files, search_text, probe, documentation, submit, shape_batch")

	result := batchResult(t, main[1], "b1")
	shpEq(t, "status", result["status"], any("completed"))
	list := result["jobs"].([]any)
	shpEq(t, "jobs", len(list), 2)
	inspect, drafted := list[0].(map[string]any), list[1].(map[string]any)
	shpEq(t, "inspect id", inspect["id"], any("inspect"))
	shpEq(t, "inspect evidence", inspect["evidence"], any("inspected the fixture"))
	shpEq(t, "inspect status", inspect["status"], any("completed"))
	shpEq(t, "draft files", len(drafted["files"].([]any)), 1)
	shpEq(t, "draft content", drafted["files"].([]any)[0].(map[string]any)["content"], any("// drafted\n"))
	shpEq(t, "draft error", drafted["error"], nil)
	shpEq(t, "revision echoed", drafted["revision"].(map[string]any)["head"], brief["revision"].(map[string]any)["head"])
	if f.exists("features/steps/draft.js") {
		t.Fatal("workers never write live files")
	}

	for _, w := range workers {
		shpContains(t, "worker instructions", fmt.Sprint(w["instructions"])+shpBody(w), "Scoped worker. Shared brief is authoritative.")
		shpContains(t, "worker brief", shpBody(w), "literal input")
	}
	byJob := map[string][]string{}
	for _, w := range workers {
		byJob[workerJobID(w)] = shpToolNames(w)
	}
	shpEq(t, "probe worker tools", strings.Join(byJob["inspect"], ", "), "read_file, list_files, search_text, probe, worker_result")
	shpEq(t, "draft worker tools", strings.Join(byJob["draft"], ", "), "worker_result")
	progress := f.Stderr.String()
	shpContains(t, "progress", progress, "kogen: worker inspect probe luna/medium\n")
	shpContains(t, "progress", progress, "kogen: worker draft draft luna/max\n")
	shpContains(t, "progress", progress, "kogen: worker draft draft completed\n")

	events := f.events()
	jobEvents := shpNamed(events, "job_result")
	shpEq(t, "job results", len(jobEvents), 2)
	batch := shpNamed(events, "batch_result")
	shpEq(t, "batch results", len(batch), 1)
	shpEq(t, "batch status", batch[0]["status"], any("completed"))
	calls := map[string]map[string]any{}
	for _, c := range shpNamed(events, "provider_call") {
		if job, ok := c["job"].(string); ok {
			calls[job+"/"+c["status"].(string)] = c
		}
	}
	if calls["inspect/completed"] == nil || calls["draft/completed"] == nil {
		t.Fatalf("worker provider calls are recorded with their job: %v", calls)
	}
	shpEq(t, "worker role", calls["inspect/completed"]["role"], any("probe"))
	shpEq(t, "worker scope", calls["inspect/completed"]["scope"], any("one exact independent task"))
	shpEq(t, "worker model", calls["draft/completed"]["configured_model"], any("luna"))
	shpEq(t, "worker effort", calls["draft/completed"]["configured_effort"], any("max"))
	probes := shpNamed(events, "probe_result")
	if len(probes) != 1 || probes[0]["job"] != "inspect" || probes[0]["role"] != "probe" {
		t.Fatalf("probe events = %v", probes)
	}
	for _, ev := range jobEvents {
		if ev["job"] == "inspect" {
			shpEq(t, "ordinary tools", ev["ordinary_tools"], any(float64(1)))
			shpEq(t, "probes", ev["probes"], any(float64(1)))
			shpEq(t, "provider calls", ev["provider_calls"], any(float64(2)))
		}
	}
}

func TestShapeBatchBoundsTwelveToolsAndTwoProbes(t *testing.T) {
	parallel(t)
	for _, tc := range []struct {
		reads, probes int
		want, errText string
	}{
		{12, 2, "completed", ""}, {13, 2, "failed", "ordinary tool bound exhausted"}, {12, 3, "failed", "probe bound exhausted"},
	} {
		t.Run(fmt.Sprintf("%d reads, %d probes", tc.reads, tc.probes), func(t *testing.T) {
			parallel(t)
			f := newShpFx(t)
			f.withWorkers()
			var calls []map[string]any
			for i := 1; i <= tc.reads; i++ {
				calls = append(calls, shpCall(fmt.Sprintf("read%d", i), "read_file", map[string]any{"path": "app.txt"}))
			}
			for i := 1; i <= tc.probes; i++ {
				calls = append(calls, shpCall(fmt.Sprintf("probe%d", i), "probe", map[string]any{"command": "printf focused"}))
			}
			calls = append(calls, shpCall("result", "worker_result", map[string]any{"evidence": "inspected", "files": []any{}}))
			f.Prov.seq = []shpStep{
				shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": f.brief(), "jobs": []any{shpJob("inspect", "probe", []any{"app.txt"})}})),
				shpAnswer(calls...),
				shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Inspect the fixture?")}}),
			}
			exit, err := f.shape("Inspect only the fixture.")
			if err != nil || exit != 5 {
				t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
			}
			reqs := f.Prov.requests()
			result := batchResult(t, reqs[2], "b1")
			shpEq(t, "status", result["status"], any(tc.want))
			job := result["jobs"].([]any)[0].(map[string]any)
			shpEq(t, "job status", job["status"], any(tc.want))
			if tc.want == "failed" {
				shpEq(t, "error", job["error"], any(tc.errText))
			}
			workerCalls := 0
			for _, r := range reqs {
				if workerJobID(r) != "" {
					workerCalls++
				}
			}
			shpEq(t, "one worker request, no replay", workerCalls, 1)
		})
	}
}

func TestShapeBatchRefusalsAndOneBatchPerConversation(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.withWorkers()
	stale := f.brief()
	stale["revision"] = map[string]any{"head": "0000", "tree": "0000"}
	f.Prov.seq = []shpStep{
		shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": stale, "jobs": []any{shpJob("inspect", "read", []any{})}})),
		shpAnswer(
			shpCall("b2", "shape_batch", map[string]any{"brief": f.brief(), "jobs": []any{shpJob("inspect", "read", []any{})}}),
			shpCall("b3", "shape_batch", map[string]any{"brief": f.brief(), "jobs": []any{shpJob("inspect", "read", []any{})}})),
		shpWorkerResult("w1", "nothing to find"),
		shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}),
	}
	if exit, err := f.shape("Inspect."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	refused := batchResult(t, reqs[1], "b1")
	shpEq(t, "status", refused["status"], any("refused"))
	shpEq(t, "reason", refused["reason"], any("incomplete boundaries, stale revision, unsafe path or conflicting ownership"))
	shpEq(t, "no jobs", len(refused["jobs"].([]any)), 0)
	// A refused batch used the conversation's one batch.
	second := batchResult(t, reqs[len(reqs)-1], "b2")
	shpEq(t, "second batch", second["status"], any("refused"))
	shpEq(t, "second reason", second["reason"], any("one batch per conversation"))
	third := batchResult(t, reqs[len(reqs)-1], "b3")
	shpEq(t, "third", third["reason"], any("one batch per conversation"))
}

func TestShapeBatchWorkerFailuresAreResultsNotErrors(t *testing.T) {
	parallel(t)
	for _, tc := range []struct {
		name  string
		step  func(f *shpFx) shpStep
		check func(t *testing.T, job map[string]any)
	}{
		{"a provider error", func(f *shpFx) shpStep { return shpStep{status: 429, code: "subscription_sharing_usage_limit_exceeded"} }, func(t *testing.T, job map[string]any) {
			e := job["error"].(map[string]any)
			shpEq(t, "class", e["class"], any("provider"))
			shpEq(t, "reason", e["reason"], any("usage_limit"))
		}},
		{"no result and no tools", func(f *shpFx) shpStep {
			return shpAnswer(map[string]any{"type": "message", "id": "m", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "I am done"}}})
		}, func(t *testing.T, job map[string]any) {
			shpEq(t, "error", job["error"], any("worker returned no result or tools"))
		}},
		{"a file the job does not own", func(f *shpFx) shpStep {
			return shpWorkerResult("w1", "x", map[string]any{"path": "features/steps/other.js", "content": "x"})
		}, func(t *testing.T, job map[string]any) {
			shpEq(t, "error", job["error"], any("unauthorized worker result or revision drift"))
		}},
		{"an empty evidence", func(f *shpFx) shpStep { return shpWorkerResult("w1", " ") }, func(t *testing.T, job map[string]any) {
			shpEq(t, "error", job["error"], any("unauthorized worker result or revision drift"))
		}},
		{"a checkout that moved meanwhile", func(f *shpFx) shpStep {
			return shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
				os.WriteFile(filepath.Join(f.Root, "drift.txt"), []byte("drift"), 0o644)
				shpFrame(w, map[string]any{"type": "response.output_item.done", "output_index": 0, "item": shpCall("w1", "worker_result", map[string]any{"evidence": "x", "files": []any{}})})
				shpFrame(w, map[string]any{"type": "response.completed", "response": map[string]any{"usage": map[string]any{"input_tokens": 1, "output_tokens": 1}}})
			}}
		}, func(t *testing.T, job map[string]any) {
			shpEq(t, "error", job["error"], any("unauthorized worker result or revision drift"))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			parallel(t)
			f := newShpFx(t)
			f.withWorkers()
			f.Prov.seq = []shpStep{
				shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": f.brief(), "jobs": []any{shpJob("inspect", "read", []any{})}})),
				tc.step(f),
				shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}),
			}
			if exit, err := f.shape("Inspect."); err != nil || exit != 5 {
				t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
			}
			reqs := f.Prov.requests()
			result := batchResult(t, reqs[len(reqs)-1], "b1")
			shpEq(t, "status", result["status"], any("failed"))
			job := result["jobs"].([]any)[0].(map[string]any)
			shpEq(t, "job status", job["status"], any("failed"))
			shpEq(t, "evidence", job["evidence"], any(""))
			shpEq(t, "files", len(job["files"].([]any)), 0)
			tc.check(t, job)
			if len(shpNamed(f.events(), "job_result")) == 0 {
				t.Fatal("the job result is recorded")
			}
		})
	}
}

func TestShapeBatchPartialWhenOneJobFails(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.withWorkers()
	f.Prov.route = func(req map[string]any) *shpStep {
		switch workerJobID(req) {
		case "good":
			st := shpWorkerResult("w1", "fine")
			return &st
		case "bad":
			st := shpAnswer(map[string]any{"type": "message", "id": "m", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "I am done"}}})
			return &st
		}
		return nil
	}
	f.Prov.seq = []shpStep{
		shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": f.brief(), "jobs": []any{shpJob("good", "read", []any{}), shpJob("bad", "read", []any{})}})),
		shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}),
	}
	if exit, err := f.shape("Inspect."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	reqs := f.Prov.requests()
	result := batchResult(t, reqs[len(reqs)-1], "b1")
	shpEq(t, "status", result["status"], any("partial"))
	batch := shpNamed(f.events(), "batch_result")
	shpEq(t, "recorded status", batch[0]["status"], any("partial"))
}

func TestShapeBatchInterruptCancelsEveryJob(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.withWorkers()
	opened := make(chan struct{}, 4)
	f.Prov.route = func(req map[string]any) *shpStep {
		if workerJobID(req) != "" {
			st := shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
				opened <- struct{}{}
				<-r.Context().Done()
			}}
			return &st
		}
		return nil
	}
	f.Prov.seq = []shpStep{shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": f.brief(), "jobs": []any{shpJob("one", "read", []any{}), shpJob("two", "read", []any{})}}))}
	f.newSession()
	go func() {
		<-opened
		<-opened
		f.S.Interrupt("SIGTERM")
	}()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Inspect.", Client: f.Client})
	var i *sys.Interrupted
	if !shpAsInterrupted(err, &i) || i.Signal != "SIGTERM" || exit != 143 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	events := f.events()
	cancelled := 0
	for _, e := range shpNamed(events, "job_result") {
		if e["status"] == "cancelled" {
			cancelled++
		}
	}
	shpEq(t, "cancelled jobs", cancelled, 2)
	batch := shpNamed(events, "batch_result")
	if len(batch) != 1 || batch[0]["status"] != "cancelled" {
		t.Fatalf("batch results = %v", batch)
	}
	for _, c := range shpNamed(events, "provider_call") {
		if c["job"] != nil && c["status"] == "completed" {
			t.Fatalf("no worker call completed: %v", c)
		}
	}
}

// ---- validation of a batch (ported from the dispatch tests) ----

func newBatchValidation(t *testing.T) (*shpFx, *shaping, map[string]any, map[string]any) {
	t.Helper()
	f := newShpFx(t)
	f.withWorkers()
	f.write("features/steps/.keep", "")
	f.git("add", "-A")
	f.git("commit", "-qm", "steps folder")
	brief := f.brief("features/steps/draft.js")
	job := shpJob("one", "draft", []any{}, "features/steps/draft.js")
	return f, f.shaping(), brief, job
}

func (sh *shaping) validates(brief map[string]any, jobs ...any) bool {
	_, _, ok := sh.validateBatch(map[string]any{"brief": brief, "jobs": jobs})
	return ok
}

func TestBatchOwnershipAndBoundaryRefusalPrecedesCallsAndNeverAltersTheRawIndex(t *testing.T) {
	parallel(t)
	f, sh, brief, job := newBatchValidation(t)
	index, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	if !sh.validates(brief, job) {
		t.Fatal("the valid draft job is accepted")
	}
	with := func(owns ...string) map[string]any { return shpJob("one", "draft", []any{}, owns...) }
	for _, owns := range [][]string{
		{"../escape"}, {"guard.txt"}, {"features/steps"},
		{"features/steps/a.js", "features/steps/a.js"}, {"features/steps/a", "features/steps/a/b.js"},
	} {
		wide := f.brief(owns...)
		if sh.validates(wide, with(owns...)) {
			t.Errorf("owns %v must be refused", owns)
		}
		args := map[string]any{"brief": wide, "jobs": []any{with(owns...)}}
		got, err := sh.runBatch(context.Background(), args)
		if err != nil || got["status"] != "refused" || len(got["jobs"].([]any)) != 0 {
			t.Errorf("owns %v: %v, %v", owns, got, err)
		}
	}
	if err := os.Symlink(os.TempDir(), filepath.Join(f.Root, "features/steps/link")); err != nil {
		t.Fatal(err)
	}
	if sh.validates(f.brief("features/steps/link/out.js"), with("features/steps/link/out.js")) {
		t.Error("a symbolic link on the way is refused")
	}
	if sh.validates(brief, job, job) {
		t.Error("duplicate job ids are refused")
	}
	second := shpJob("two", "draft", []any{}, "features/steps/../steps/draft.js")
	if sh.validates(brief, job, second) {
		t.Error("an owned path with .. is refused")
	}
	after, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	if string(after) != string(index) {
		t.Fatal("validation never alters the raw index")
	}
}

func TestBatchDraftBoundariesRejectUnsupportedArtifacts(t *testing.T) {
	parallel(t)
	f, sh, brief, job := newBatchValidation(t)
	for _, target := range []string{".kogen/intents/is-even/extra.txt", "features/steps/../steps/draft.js"} {
		b := f.brief(target)
		j := shpJob("one", "draft", []any{}, target)
		if sh.validates(b, j) {
			t.Errorf("target %s must be refused", target)
		}
	}
	if sh.validates(f.brief(), job) {
		t.Error("a draft that owns a path outside the brief's artifacts is refused")
	}
	_ = brief
}

func TestBatchAnExistingEditableStepIsAValidDraftTarget(t *testing.T) {
	parallel(t)
	f, sh, _, job := newBatchValidation(t)
	f.write("features/steps/draft.js", "// existing shared step\n")
	if !sh.validates(f.brief("features/steps/draft.js"), job) {
		t.Fatal("an existing editable step is a valid draft target, with current boundaries")
	}
}

func TestBatchRevisionNoticesNonignoredUntrackedDriftWithoutRealIndexWrites(t *testing.T) {
	parallel(t)
	f, sh, brief, job := newBatchValidation(t)
	index, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	f.write("new.txt", "drift")
	now, err := CurrentRevision(f.Repo)
	if err != nil {
		t.Fatal(err)
	}
	if now.Tree == brief["revision"].(map[string]any)["tree"] {
		t.Fatal("an untracked file changes the revision")
	}
	if sh.validates(brief, job) {
		t.Error("a stale revision is refused")
	}
	after, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	if string(after) != string(index) {
		t.Fatal("the raw index stays as it was")
	}
}

func TestBatchBriefMustBeCompleteAndProtectEverythingProtected(t *testing.T) {
	parallel(t)
	f, sh, brief, job := newBatchValidation(t)
	for _, key := range []string{"outcomes", "interfaces", "transitions", "fixtures", "exclusions"} {
		b := f.brief("features/steps/draft.js")
		b[key] = " "
		if sh.validates(b, job) {
			t.Errorf("a blank %s is refused", key)
		}
	}
	missingProtected := f.brief("features/steps/draft.js")
	missingProtected["protected_paths"] = []any{".kogen/project.yaml"}
	if sh.validates(missingProtected, job) {
		t.Error("the brief must list every protected path")
	}
	if sh.validates(brief, job, job, job, job) {
		t.Error("at most three jobs")
	}
	if _, _, ok := sh.validateBatch(map[string]any{"brief": brief, "jobs": []any{job}, "extra": true}); ok {
		t.Error("exactly brief and jobs")
	}
	readJob := shpJob("r", "read", []any{}, "features/steps/draft.js")
	if sh.validates(brief, readJob) {
		t.Error("read jobs own nothing")
	}
	unknown := shpJob("r", "other", []any{})
	if sh.validates(brief, unknown) {
		t.Error("only read, probe and draft roles exist")
	}
	_ = project.ConfigPath
}

// Ports test/integration/shape_worker_bounds_test.exs "workers receive bounded long-line reads
// and replay the delivered display exactly".
func TestWorkersReceiveBoundedLongLineReadsAndReplayTheDeliveredDisplayExactly(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.withWorkers()
	original := `{"input":"` + strings.Repeat("x", 514_428) + `"}`
	if len(original) != 514_440 {
		t.Fatalf("fixture is %d bytes", len(original))
	}
	f.write("large.json", original)
	brief := f.brief()
	job := shpJob("inspect", "read", []any{"large.json", "app.txt"})
	f.Prov.route = func(req map[string]any) *shpStep {
		if workerJobID(req) != "inspect" {
			return nil
		}
		var st shpStep
		switch outputs := shpOutputs(req); {
		case len(outputs) == 0:
			st = shpAnswer(shpCall("large", "read_file", map[string]any{"path": "large.json", "start_line": 1, "end_line": 35}))
		case len(outputs) == 1:
			st = shpAnswer(shpCall("ordinary", "read_file", map[string]any{"path": "app.txt"}))
		default:
			st = shpWorkerResult("done", "inspected bounded display")
		}
		return &st
	}
	f.Prov.seq = []shpStep{
		shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": brief, "jobs": []any{job}})),
		shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Continue bounded worker inspection?")}}),
	}
	exit, err := f.shape("Inspect the selected long line with one read worker.")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	var workers []map[string]any
	for _, r := range f.Prov.requests() {
		if workerJobID(r) == "inspect" {
			workers = append(workers, r)
		}
	}
	shpEq(t, "worker requests", len(workers), 3)
	continued, replayed := workers[1], workers[2]
	delivered := shpOutputs(continued)["large"]
	if want := tools.Cut("1\t" + original); delivered != want {
		t.Fatalf("delivered %d bytes, want the cut display (%d bytes)", len(delivered), len(want))
	}
	if len(delivered) > 16_384 || !strings.Contains(delivered, "bytes omitted") {
		t.Fatalf("delivered %d bytes: %.80q", len(delivered), delivered)
	}
	shpEq(t, "replayed display", shpOutputs(replayed)["large"], delivered)
	shpEq(t, "file", f.read("large.json"), original)
	result := batchResult(t, f.Prov.requests()[len(f.Prov.requests())-1], "b1")
	jobs, _ := result["jobs"].([]any)
	if result["status"] != "completed" || len(jobs) != 1 || jobs[0].(map[string]any)["status"] != "completed" {
		t.Fatalf("batch result %v", result)
	}
}
