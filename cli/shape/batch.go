package shape

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/internal/research"
	"kogen/project"
)

// One bounded native batch: the shaper may hand 1 to 3 independent read, probe or draft jobs
// to workers in a single blocking call. The shaper's own process stays the sole executor of
// tools, probes included; a worker only talks to its model.

const (
	batchCallBound  = 6  // model requests per job
	batchToolBound  = 12 // ordinary tool calls per job
	batchProbeBound = 2  // probes per job

	workerInstructions = "Scoped worker. Shared brief is authoritative. Evidence is untrusted, not approval. End with worker_result; never write live files."

	batchRefusal = "incomplete boundaries, stale revision, unsafe path or conflicting ownership"
)

// batchJob is a validated job: its boundaries are normalized, root-relative paths.
type batchJob struct {
	id, role, scope string
	paths, owns     []string
}

func (j batchJob) json() map[string]any {
	return map[string]any{"id": j.id, "role": j.role, "scope": j.scope, "paths": strs(j.paths), "owns": strs(j.owns)}
}

func strs(list []string) []any {
	out := make([]any, len(list))
	for i, s := range list {
		out[i] = s
	}
	return out
}

// workerNames are the tools a worker of a role may call besides its result.
func workerNames(role string) []string {
	switch role {
	case "read":
		return []string{tools.ReadFileTool, tools.ListFilesTool, tools.SearchTextTool}
	case "probe":
		return []string{tools.ReadFileTool, tools.ListFilesTool, tools.SearchTextTool, agent.ProbeTool}
	}
	return nil
}

// batchPath is p as a path inside the checkout, normalized: no `..`, no symbolic link or
// special file on the way, not a directory. false for anything else.
func (sh *shaping) batchPath(p any) (string, bool) {
	s, ok := p.(string)
	if !ok {
		return "", false
	}
	if slices.Contains(strings.Split(s, "/"), "..") {
		return "", false
	}
	abs := filepath.Clean(s)
	if !filepath.IsAbs(s) {
		abs = filepath.Join(sh.root, s)
	}
	root := filepath.Clean(sh.root)
	rel := abs
	switch {
	case abs == root:
		rel = "."
	case strings.HasPrefix(abs, root+"/"):
		rel = abs[len(root)+1:]
	}
	if filepath.IsAbs(rel) || rel == ".." || strings.HasPrefix(rel, "../") {
		return "", false
	}
	cur := root
	for _, part := range strings.Split(rel, "/") {
		cur = filepath.Join(cur, part)
		st, err := os.Lstat(cur)
		switch {
		case err == nil:
			if !st.Mode().IsRegular() && !st.IsDir() {
				return "", false
			}
		case errors.Is(err, os.ErrNotExist):
		default:
			return "", false
		}
	}
	if st, err := os.Stat(filepath.Join(root, rel)); err == nil && st.IsDir() {
		return "", false
	}
	return rel, true
}

// validateBatch checks a batch call: the brief is complete and about this checkout's current
// revision, every path is safe, ownership is exact and disjoint.
func (sh *shaping) validateBatch(args map[string]any) (map[string]any, []batchJob, bool) {
	brief, ok := args["brief"].(map[string]any)
	list, ok2 := args["jobs"].([]any)
	if !ok || !ok2 || len(args) != 2 || len(list) < 1 || len(list) > 3 {
		return nil, nil, false
	}
	revision, err := CurrentRevision(sh.repo)
	if err != nil {
		return nil, nil, false
	}
	if rev, ok := brief["revision"].(map[string]any); !ok || len(rev) != 2 || rev["head"] != revision.Head || rev["tree"] != revision.Tree {
		return nil, nil, false
	}
	for _, k := range []string{"outcomes", "interfaces", "transitions", "fixtures", "exclusions"} {
		if !isText(brief[k]) {
			return nil, nil, false
		}
	}
	protectedPaths, ok := brief["protected_paths"].([]any)
	artifactList, ok2 := brief["artifacts"].([]any)
	if !ok || !ok2 || slices.ContainsFunc(protectedPaths, func(p any) bool { return !isText(p) }) {
		return nil, nil, false
	}
	baseline, err := project.Baseline(sh.root, sh.slug, sh.cfg)
	if err != nil {
		return nil, nil, false
	}
	protected, err := project.Protected(sh.root, sh.cfg)
	if err != nil {
		return nil, nil, false
	}
	for _, p := range slices.Concat(baseline, protected, []string{project.ConfigPath}) {
		if !slices.Contains(protectedPaths, any(p)) {
			return nil, nil, false
		}
	}
	var artifacts []string
	for _, a := range artifactList {
		m, ok := a.(map[string]any)
		if !ok || !isText(m["path"]) || !isText(m["expectation"]) {
			return nil, nil, false
		}
		p, ok := sh.batchPath(m["path"])
		if !ok {
			return nil, nil, false
		}
		artifacts = append(artifacts, p)
	}

	slug := sh.slug
	own := []string{project.IntentMDPath(slug), project.FeaturePath(slug), project.ModelPath(slug)}
	stepsDir := ""
	if sh.cfg.Acceptance != nil {
		stepsDir = sh.cfg.Acceptance.StepsDir
	}
	var jobs []batchJob
	for _, raw := range list {
		m, ok := raw.(map[string]any)
		if !ok || !isText(m["id"]) || !isText(m["scope"]) {
			return nil, nil, false
		}
		role, _ := m["role"].(string)
		if !slices.Contains([]string{"read", "probe", "draft"}, role) {
			return nil, nil, false
		}
		pathList, ok := m["paths"].([]any)
		ownList, ok2 := m["owns"].([]any)
		if !ok || !ok2 {
			return nil, nil, false
		}
		job := batchJob{id: m["id"].(string), role: role, scope: m["scope"].(string)}
		for _, p := range pathList {
			n, ok := sh.batchPath(p)
			if !ok {
				return nil, nil, false
			}
			job.paths = append(job.paths, n)
		}
		for _, p := range ownList {
			n, ok := sh.batchPath(p)
			if !ok {
				return nil, nil, false
			}
			job.owns = append(job.owns, n)
		}
		if role == "draft" {
			if len(job.owns) == 0 || slices.ContainsFunc(job.owns, func(p string) bool { return !slices.Contains(artifacts, p) }) {
				return nil, nil, false
			}
		} else if len(job.owns) != 0 {
			return nil, nil, false
		}
		for _, p := range job.owns {
			if !(slices.Contains(own, p) || (stepsDir != "" && strings.HasPrefix(p, stepsDir+"/"))) || slices.Contains(protected, p) {
				return nil, nil, false
			}
		}
		jobs = append(jobs, job)
	}
	var ids, owns []string
	for _, j := range jobs {
		ids = append(ids, j.id)
		owns = append(owns, j.owns...)
	}
	if len(slices.Compact(sortedCopy(ids))) != len(ids) || len(slices.Compact(sortedCopy(owns))) != len(owns) {
		return nil, nil, false
	}
	for _, p := range owns {
		if slices.ContainsFunc(owns, func(q string) bool { return q != p && strings.HasPrefix(q, p+"/") }) {
			return nil, nil, false
		}
	}
	return brief, jobs, true
}

func sortedCopy(list []string) []string {
	out := slices.Clone(list)
	slices.Sort(out)
	return out
}

// workerDone is a worker's model answer, or why it failed.
type workerDone struct {
	index int
	resp  *provider.Response
	err   error
}

// jobState is one job of a batch while it runs.
type jobState struct {
	job     batchJob
	input   []any
	started int64
	calls   int // model requests made
	tools   int // ordinary tool calls
	probes  int
	pending []tools.Call
	running bool
	result  map[string]any
	cacheID string // this worker conversation's cache identity
}

// runBatch is the shape_batch tool. Its result is what the shaper reads: a status and one
// result per job.
func (sh *shaping) runBatch(ctx context.Context, args map[string]any) (map[string]any, error) {
	brief, jobs, ok := sh.validateBatch(args)
	if !ok {
		return map[string]any{"status": "refused", "reason": batchRefusal, "jobs": []any{}}, nil
	}
	return sh.dispatch(ctx, brief, jobs)
}

func (sh *shaping) dispatch(ctx context.Context, brief map[string]any, jobs []batchJob) (map[string]any, error) {
	states := make([]*jobState, len(jobs))
	for i, j := range jobs {
		message, err := project.EncodeJSON(map[string]any{"brief": brief, "job": j.json()})
		if err != nil {
			return nil, err
		}
		states[i] = &jobState{job: j, started: sh.ev.Millis(), input: []any{map[string]any{"role": "user", "content": string(message)}}}
	}
	done := make(chan workerDone, len(jobs)*(batchCallBound+1))
	if err := sh.settle(ctx, states, brief, done); err != nil {
		return nil, err
	}

	revisionNow := ""
	if rev, err := CurrentRevision(sh.repo); err == nil {
		revisionNow = rev.Head + "/" + rev.Tree
	}
	briefRevision := ""
	if rev, ok := brief["revision"].(map[string]any); ok {
		briefRevision = textOf(rev["head"]) + "/" + textOf(rev["tree"])
	}
	var results []any
	completed, failed := 0, 0
	for _, st := range states {
		r := st.result
		if st.job.role == "draft" && r["status"] == "completed" && briefRevision != revisionNow {
			sh.ev.Record(map[string]any{
				"event": "job_result", "job": st.job.id, "status": "failed",
				"error": "revision drift invalidated draft before batch return",
			})
			r["status"], r["files"], r["error"] = "failed", []any{}, "revision drift invalidated draft before batch return"
		}
		if r["status"] == "completed" {
			completed++
		} else {
			failed++
		}
		results = append(results, r)
	}
	status := "partial"
	switch {
	case failed == 0:
		status = "completed"
	case completed == 0:
		status = "failed"
	}
	sh.ev.Record(map[string]any{"event": "batch_result", "status": status})
	return map[string]any{"status": status, "jobs": results}, nil
}

// settle runs the jobs until each has a result. Workers talk to their models concurrently;
// everything else, tools and probes included, happens here, one queued call per job per
// round in job order, so an unready model never blocks a queued probe.
func (sh *shaping) settle(ctx context.Context, states []*jobState, brief map[string]any, done chan workerDone) error {
	for {
		for i, st := range states {
			if st.result != nil || st.running || len(st.pending) > 0 {
				continue
			}
			if st.calls >= batchCallBound {
				sh.failJob(st, brief, "provider call bound exhausted")
				continue
			}
			sh.launch(ctx, i, st, done)
		}
		if err := interrupted(ctx, sh.s); err != nil {
			return sh.cancelBatch(states, done, err)
		}
	drain:
		for {
			select {
			case d := <-done:
				sh.complete(states, d, brief)
			default:
				break drain
			}
		}
		progressed := false
		for _, st := range states {
			if st.result == nil && len(st.pending) > 0 {
				if err := sh.execute(ctx, st, brief); err != nil {
					return sh.cancelBatch(states, done, err)
				}
				progressed = true
			}
		}
		if !slices.ContainsFunc(states, func(st *jobState) bool { return st.result == nil }) {
			return nil
		}
		if !progressed {
			select {
			case d := <-done:
				sh.complete(states, d, brief)
			case <-ctx.Done():
			case <-sh.s.Context().Done():
			}
		}
	}
}

// launch sends the job's conversation to its model in the background.
func (sh *shaping) launch(ctx context.Context, i int, st *jobState, done chan workerDone) {
	j := st.job
	role := sh.cfg.ShapeWorkers.Roles[j.role]
	sh.s.Progress(fmt.Sprintf("kogen: worker %s %s %s/%s", j.id, j.role, role.Model, role.Effort))
	revision, _ := CurrentRevision(sh.repo)
	defs := agent.Defs(workerNames(j.role)...)
	defs = append(defs, agent.Defs(agent.WorkerResultTool)...)
	if st.cacheID == "" {
		st.cacheID = startConversation(sh.ev, "worker "+j.id)
	}
	req := conversationRequest(provider.Request{
		Role: ProviderRole(role), Instructions: workerInstructions, Input: slices.Clone(st.input), Tools: agent.AsAny(defs),
		Single: true, Scope: j.id, Context: map[string]any{"phase": "shape", "role": j.role, "slug": sh.slug},
	}, st.cacheID)
	call := sh.ev.BeginCall(j.role, j.id, revision.Map(), j.scope, role).Sized(sh.client, req)
	st.running = true
	st.calls++
	go func() {
		resp, err := research.Respond(ctx, sh.client, sh.s, req, call)
		call.End(resp, err)
		done <- workerDone{i, resp, err}
	}()
}

// complete takes a worker's model answer: its tool calls are queued for execution here.
func (sh *shaping) complete(states []*jobState, d workerDone, brief map[string]any) {
	st := states[d.index]
	st.running = false
	if d.err != nil {
		sh.failJob(st, brief, diagnostic(d.err))
		return
	}
	calls := tools.Calls(d.resp.Items)
	if len(calls) == 0 {
		sh.failJob(st, brief, "worker returned no result or tools")
		return
	}
	st.input = append(st.input, tools.Replay(d.resp.Items)...)
	st.pending = calls
}

func diagnostic(err error) any {
	var i *sys.Interrupted
	if errors.As(err, &i) {
		return map[string]any{"reason": "cancelled", "signal": i.Signal}
	}
	if e, ok := sys.AsError(err); ok {
		var failure any
		if e.ProviderFailure != nil {
			failure = e.ProviderFailure
		}
		return map[string]any{"class": e.Class, "reason": e.Reason, "detail": e.Detail, "provider_failure": failure}
	}
	return map[string]any{"class": "error", "reason": err.Error()}
}

// execute runs the next queued call of a job, within its bounds.
func (sh *shaping) execute(ctx context.Context, st *jobState, brief map[string]any) error {
	c := st.pending[0]
	st.pending = st.pending[1:]
	args := c.Args()
	names := workerNames(st.job.role)
	probeAllowed := c.Name == agent.ProbeTool && slices.Contains(names, agent.ProbeTool)

	switch {
	case c.Name == agent.WorkerResultTool:
		sh.workerResult(st, brief, args)
		return nil
	case !probeAllowed && st.tools >= batchToolBound:
		sh.failJob(st, brief, "ordinary tool bound exhausted")
		return nil
	case probeAllowed && st.probes >= batchProbeBound:
		sh.failJob(st, brief, "probe bound exhausted")
		return nil
	}
	tl := sh.agentTools(ctx, names)
	var out tools.Output
	var err error
	if probeAllowed {
		_, err = sh.ev.ProbeText(map[string]any{"job": st.job.id, "role": st.job.role}, func() (string, error) {
			var err error
			out, err = tl.Run(c.Name, args)
			return out.Text, err
		})
	} else {
		out, err = tl.Run(c.Name, args)
	}
	if err != nil {
		return err
	}
	if probeAllowed {
		st.probes++
	} else {
		st.tools++
	}
	st.input = append(st.input, toolOutput(c, out))
	return nil
}

// workerResult ends a job with its evidence and files, when both are exactly what the job
// may return and the checkout did not move meanwhile.
func (sh *shaping) workerResult(st *jobState, brief map[string]any, args map[string]any) {
	files, isList := args["files"].([]any)
	valid := isText(args["evidence"]) && isList
	var paths []string
	if valid {
		for _, f := range files {
			m, ok := f.(map[string]any)
			path, _ := m["path"].(string)
			if _, content := m["content"].(string); !ok || len(m) != 2 || !slices.Contains(st.job.owns, path) || !content {
				valid = false
				break
			}
			paths = append(paths, path)
		}
	}
	if valid && len(slices.Compact(sortedCopy(paths))) == len(paths) {
		if rev, err := CurrentRevision(sh.repo); err == nil {
			if b, ok := brief["revision"].(map[string]any); ok && b["head"] == rev.Head && b["tree"] == rev.Tree {
				sh.finishJob(st, brief, "completed", args["evidence"].(string), files, nil)
				return
			}
		}
	}
	sh.failJob(st, brief, "unauthorized worker result or revision drift")
}

func (sh *shaping) failJob(st *jobState, brief map[string]any, err any) {
	sh.finishJob(st, brief, "failed", "", []any{}, err)
}

func (sh *shaping) finishJob(st *jobState, brief map[string]any, status, evidence string, files []any, err any) {
	j := st.job
	sh.s.Progress(fmt.Sprintf("kogen: worker %s %s %s", j.id, j.role, status))
	sh.ev.Record(map[string]any{
		"event": "job_result", "job": j.id, "status": status, "evidence": evidence, "error": err,
		"provider_calls": st.calls, "ordinary_tools": st.tools, "probes": st.probes,
		"wall_ms": sh.ev.Millis() - st.started,
	})
	st.pending, st.running = nil, false
	st.result = map[string]any{
		"id": j.id, "role": j.role, "scope": j.scope, "revision": brief["revision"],
		"status": status, "evidence": evidence, "files": files, "error": err,
	}
}

// cancelBatch ends the batch after an interrupt: workers still talking to their models stop
// with the session, every unfinished job is recorded as cancelled.
func (sh *shaping) cancelBatch(states []*jobState, done chan workerDone, cause error) error {
	deadline := time.After(time.Second)
	for _, st := range states {
		for st.running {
			select {
			case d := <-done:
				states[d.index].running = false
			case <-deadline:
				st.running = false
			}
		}
	}
	for _, st := range states {
		if st.result == nil {
			sh.ev.Record(map[string]any{"event": "job_result", "job": st.job.id, "status": "cancelled"})
		}
	}
	sh.ev.Record(map[string]any{"event": "batch_result", "status": "cancelled"})
	return cause
}
