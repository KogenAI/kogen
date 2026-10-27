package build

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
)

// localFacts publishes the integration records of one Build under `.kogen/local`
// (`facts/<run>.json`, `context.json`, `catalog.json`, `completion.json`) and the package
// facts of its Intent. They are read by `kogen context`, `intent list` and `intent inspect`;
// they are never approval or continuation authority.
type localFacts struct {
	root    string
	record  map[string]any
	failure *sys.Error
	clock   *phaseClock
}

// phaseClock times the phase a Build is in; a change of phase logs its duration.
type phaseClock struct {
	phase   string
	started time.Time
	at      string
}

// lockOwner is this process as the holder of the Build lock: pid, start time as `ps` prints
// it, and the lock's owner token (nil when no lock is held).
func lockOwner(root string) map[string]any {
	pid := strconv.Itoa(os.Getpid())
	birth := ""
	if out, err := exec.Command("ps", "-p", pid, "-o", "lstart=").Output(); err == nil {
		birth = strings.TrimSpace(string(out))
	}
	var token any
	if lockPID, t, held := git.LockOwner(git.BuildLockPath(root)); held && lockPID == pid && t != "" {
		token = t
	}
	return map[string]any{"pid": pid, "birth": birth, "token": token}
}

// startFacts records a new run: `parent` and `rootRun` are empty for a first run.
func startFacts(root, slug string, run *Run, cfg *project.Config, parent, rootRun string) (*localFacts, error) {
	c, err := project.Checkout(root)
	if err != nil {
		return nil, err
	}
	var resumedFrom any
	if parent != "" {
		resumedFrom = parent
	}
	if rootRun == "" {
		rootRun = run.ID
	}
	now := time.Now()
	f := &localFacts{root: root, clock: &phaseClock{phase: "startup", started: now, at: isoTime(now)}}
	f.record = map[string]any{
		"checkout_id":        c.ID,
		"slug":               slug,
		"run_id":             run.ID,
		"resumed_from":       resumedFrom,
		"root_run":           rootRun,
		"started_at":         isoTime(now),
		"state":              "active",
		"phase":              "startup",
		"verification_pass":  nil,
		"verification":       []any{},
		"reviews":            []any{},
		"reason":             nil,
		"blockers":           []any{},
		"commit":             nil,
		"resume_status":      "requires_validation",
		"owner":              lockOwner(root),
		"evidence_truncated": false,
		"locations": map[string]any{
			"candidate":  root,
			"run_dir":    run.Dir,
			"log":        run.LogPath,
			"checkpoint": filepath.Join(run.Dir, "checkpoint.json"),
		},
		"evidence_locations": map[string]any{"run_dir": run.Dir, "log": run.LogPath},
	}
	if err := f.publish(c); err != nil {
		return nil, err
	}
	if err := project.WritePackageFacts(root, slug, cfg); err != nil {
		return nil, err
	}
	return f, nil
}

// inherit carries the verification and review summaries of the previous run (the last 20
// entries recorded) into this run's record, then adds the checkpointed last pass and review.
func (f *localFacts) inherit(b *Attempt, previous *Run) {
	if bytes, err := os.ReadFile(filepath.Join(b.Root, ".kogen/local/facts", previous.ID+".json")); err == nil {
		var old map[string]any
		if json.Unmarshal(bytes, &old) == nil && old != nil {
			for _, key := range []string{"verification", "reviews"} {
				var entries []any
				if list, ok := old[key].([]any); ok {
					list = list[max(0, len(list)-20):]
					for _, e := range list {
						m, ok := e.(map[string]any)
						if !ok {
							continue
						}
						kept := map[string]any{}
						for _, k := range []string{"n", "green", "tree", "failing", "not_run", "verdict", "findings", "path"} {
							if v, ok := m[k]; ok && v != nil {
								kept[k] = v
							}
						}
						entries = append(entries, kept)
					}
				}
				if entries == nil {
					entries = []any{}
				}
				f.record[key] = entries[max(0, len(entries)-20):]
			}
		}
	}
	if b.LastPass != nil {
		f.evidence("verification", passSummary(b), b.LastPass.N, previous.Dir)
	}
	if b.LastReview != nil && b.LastReview.Verdict != "pending" {
		f.evidence("reviews", reviewSummary(b), b.LastReview.N, previous.Dir)
	}
}

func (f *localFacts) fail(e *sys.Error) { f.failure = e }

func passSummary(b *Attempt) map[string]any {
	p := b.LastPass
	m := map[string]any{"n": p.N, "green": p.Green, "tree": p.Tree, "failing": nonNil(p.Failing)}
	if !p.Legacy {
		m["not_run"] = nonNil(p.NotRun)
	}
	return m
}

func reviewSummary(b *Attempt) map[string]any {
	r := b.LastReview
	findings := r.Findings
	if findings == nil {
		findings = []map[string]any{}
	}
	return map[string]any{"n": r.N, "verdict": r.Verdict, "findings": findings}
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// blockers are the reasons a Build cannot simply continue.
func (f *localFacts) blockers(b *Attempt, outcome string) []any {
	switch {
	case b.Blocker != nil:
		return []any{b.Blocker}
	case b.LastReview != nil && b.LastReview.Verdict == "changes":
		var out []any
		for _, finding := range b.LastReview.Findings {
			if finding["severity"] == "blocking" {
				m := map[string]any{}
				for k, v := range finding {
					m[k] = v
				}
				m["paths"] = []any{finding["path"]}
				out = append(out, m)
			}
		}
		if out == nil {
			out = []any{}
		}
		return out
	case outcome != "" && slices.Contains([]string{StageStartup, StageTool, StageCommit}, b.Continuation.Stage):
		return []any{map[string]any{
			"reason": "unsafe_boundary",
			"detail": "uncertain " + b.Continuation.Stage + " boundary; inspect effects and obtain fresh exact approval for a new Build",
			"paths":  []any{filepath.Join(b.Run.Dir, "checkpoint.json")},
		}}
	case outcome != "" && f.failure != nil:
		lines := make([]any, len(f.failure.Lines))
		for i, l := range f.failure.Lines {
			lines[i] = l
		}
		return []any{map[string]any{"class": f.failure.Class, "reason": f.failure.Reason, "detail": f.failure.Detail, "paths": lines}}
	}
	return []any{}
}

// update publishes the record after a change of phase or outcome (an empty argument keeps
// the current phase; no outcome means the Build is active).
func (f *localFacts) update(b *Attempt, phase, outcome string) error {
	r := f.record
	if r == nil || r["run_id"] != b.Run.ID {
		return nil
	}
	if b.StageProgress != nil {
		r["stage_progress"] = b.StageProgress.value()
	}
	// External roles only: each role's own identity, rounds and harness-reported usage. Native
	// records carry no executor fields.
	if b.Executor != nil || b.ReviewExecutor != nil {
		roles := map[string]any{}
		if b.Executor != nil {
			roles["build"] = b.Executor
		}
		if b.ReviewExecutor != nil {
			roles["review"] = b.ReviewExecutor
		}
		r["executors"] = roles
	}
	if phase == "" {
		phase, _ = r["phase"].(string)
	}
	if c := f.clock; c != nil && (c.phase != phase || outcome != "") {
		now := time.Now()
		name := map[string]string{"building": "build", "reviewing": "review"}[c.phase]
		if name == "" {
			name = c.phase
		}
		b.Run.Event(map[string]any{"event": "phase_duration", "phase": name, "timestamp": c.at, "wall_ms": now.Sub(c.started).Milliseconds()})
		if outcome == "" {
			f.clock = &phaseClock{phase: phase, started: now, at: isoTime(now)}
		} else {
			f.clock = nil
		}
	}
	var status string
	switch {
	case b.Blocker != nil:
		status = "unsupported"
	case outcome == "baseline_changed" || outcome == "head_moved":
		status = "unsupported"
	case slices.Contains([]string{StageStartup, StageTool, StageCommit}, b.Continuation.Stage):
		status = "unsupported"
	case outcome == "":
		status = "requires_validation"
	default:
		status = "potentially_available"
	}
	var pass, reason, commit any
	if phase == "verifying" {
		pass = b.Pass
	}
	state := "active"
	if outcome != "" {
		state, reason = outcome, outcome
	}
	if b.Continuation.Commit != "" {
		commit = b.Continuation.Commit
	}
	r["phase"] = phase
	r["verification_pass"] = pass
	r["state"] = state
	r["reason"] = reason
	r["resume_status"] = status
	r["blockers"] = f.blockers(b, outcome)
	r["commit"] = commit
	if b.LastPass != nil {
		f.evidence("verification", passSummary(b), b.LastPass.N, "")
	}
	if b.LastReview != nil && b.LastReview.Verdict != "pending" {
		f.evidence("reviews", reviewSummary(b), b.LastReview.N, "")
	}
	c, err := project.Checkout(b.Root)
	if err != nil {
		return err
	}
	return f.publish(c)
}

// evidence adds or replaces the summary of one pass or review in the record's list of the
// last 20, pointing at the artifact the summary came from.
func (f *localFacts) evidence(key string, summary map[string]any, n int, artifactDir string) {
	r := f.record
	if artifactDir == "" {
		locations, _ := r["locations"].(map[string]any)
		artifactDir, _ = locations["run_dir"].(string)
	}
	list, _ := r[key].([]any)
	var previous map[string]any
	for _, e := range list {
		if m, ok := e.(map[string]any); ok && sameNumber(m["n"], n) {
			previous = m
			break
		}
	}
	if previous != nil {
		without := map[string]any{}
		for k, v := range previous {
			if k != "path" {
				without[k] = v
			}
		}
		if canonical(without) == canonical(summary) {
			if p, ok := previous["path"].(string); ok {
				artifactDir = filepath.Dir(p)
			}
		}
	}
	var entries []any
	for _, e := range list {
		if m, ok := e.(map[string]any); ok && sameNumber(m["n"], n) {
			continue
		}
		entries = append(entries, e)
	}
	file := fmt.Sprintf("review-%d.json", n)
	if key == "verification" {
		file = fmt.Sprintf("acceptance-%d.ndjson", n)
	}
	path := filepath.Join(artifactDir, file)
	if st, err := os.Stat(path); err != nil || !st.Mode().IsRegular() {
		path = filepath.Join(artifactDir, "log.jsonl")
	}
	entry := map[string]any{"path": path}
	for k, v := range summary {
		entry[k] = v
	}
	entries = append(entries, entry)
	truncated, _ := r["evidence_truncated"].(bool)
	r["evidence_truncated"] = truncated || len(entries) > 20
	r[key] = entries[max(0, len(entries)-20):]
}

func sameNumber(v any, n int) bool {
	switch x := v.(type) {
	case int:
		return x == n
	case float64:
		return x == float64(n)
	case json.Number:
		return x.String() == strconv.Itoa(n)
	}
	return false
}

func canonical(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}

// publish writes the record and the files derived from it.
func (f *localFacts) publish(c project.CheckoutFacts) error {
	dir := filepath.Join(f.root, ".kogen/local")
	if err := os.MkdirAll(filepath.Join(dir, "facts"), 0o777); err != nil {
		return err
	}
	runID, _ := f.record["run_id"].(string)
	if err := atomicJSON(filepath.Join(dir, "facts", runID+".json"), f.record); err != nil {
		return err
	}
	var active any
	if f.record["state"] == "active" {
		active = pick(f.record, "slug", "run_id", "phase", "verification_pass")
	}
	err := atomicJSON(filepath.Join(dir, "context.json"), map[string]any{
		"schema_version": 1,
		"checkout":       c,
		"active":         active,
		"last_built":     pick(f.record, "slug", "run_id"),
		"owner":          f.record["owner"],
	})
	if err != nil {
		return err
	}
	catalog := map[string]any{}
	if bytes, err := os.ReadFile(filepath.Join(dir, "catalog.json")); err == nil {
		var old map[string]any
		if json.Unmarshal(bytes, &old) == nil {
			for id, r := range old {
				if m, ok := r.(map[string]any); ok && m["checkout_id"] == c.ID {
					catalog[id] = m
				}
			}
		}
	}
	catalog[runID] = pick(f.record, "checkout_id", "slug", "run_id", "started_at", "state", "phase", "resumed_from", "root_run", "resume_status", "owner")
	if err := atomicJSON(filepath.Join(dir, "catalog.json"), catalog); err != nil {
		return err
	}
	var runs []map[string]any
	for _, r := range catalog {
		runs = append(runs, r.(map[string]any))
	}
	slices.SortFunc(runs, func(a, b map[string]any) int {
		return strings.Compare(fmt.Sprint(a["run_id"]), fmt.Sprint(b["run_id"]))
	})
	var resume []map[string]any
	for _, r := range runs {
		if r["resume_status"] != "unsupported" && r["state"] != "landed" {
			resume = append(resume, r)
		}
	}
	return atomicJSON(filepath.Join(dir, "completion.json"), map[string]any{
		"inspect": runs[:min(100, len(runs))],
		"resume":  nonNil(resume[:min(100, len(resume))]),
	})
}

func pick(m map[string]any, keys ...string) map[string]any {
	out := map[string]any{}
	for _, k := range keys {
		if v, ok := m[k]; ok {
			out[k] = v
		} else {
			out[k] = nil
		}
	}
	return out
}

// atomicJSON writes the JSON of v and a newline to path.tmp and renames it over path.
func atomicJSON(path string, v any) error {
	b, err := encodeJSON(v)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o666); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
