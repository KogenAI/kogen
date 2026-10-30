package shape

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"kogen-loop/sys"
	"kogen/agent"
	"kogen/executor"
	"kogen/git"
	"kogen/project"
)

// External is how the program provides the executor of an external role (`executor:
// claude-code`); nil means none is available.
type External func(role project.Role) (executor.Executor, error)

// externalNote tells an external shaper what its session has instead of the native tools. It
// claims no Kogen capability for the harness's own tools.
const externalNote = "# This session\n\n" +
	"You are a read-only external session. You may inspect the checkout with your own tools, but you must not change any file, the Git index or HEAD, including the files you propose: they are submitted in your final structured result and Kogen checks and publishes them.\n" +
	"The native tools named in the rules above (probe, view_image, documentation records, shape_batch) are not available here. Kogen's own scratch checking, readiness, Feasibility checks and documentation records are not produced by your research; what you fetch or run with your tools is observed by the harness only, not retained by Kogen as a documentation event.\n" +
	"The final structured result is the arguments of the submission described above (for Shape `submit`; for Refine `submit_refinement`). Kogen returns its actual feedback to this same session."

// selectExternal is the executor a Shape or Refine role selects, validated for the shape role.
func selectExternal(ext External, role project.Role) (executor.Executor, int, error) {
	unavailable := executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" is not available for the shape role in this program; Kogen does not shape with the native shaper instead")
	if ext == nil {
		return nil, 0, unavailable
	}
	ex, err := ext(role)
	if err != nil {
		return nil, 0, err
	}
	if ex == nil {
		return nil, 0, unavailable
	}
	desc := ex.Describe()
	if err := desc.ValidateRole(executor.RoleShape); err != nil {
		return nil, 0, err
	}
	if desc.Name != role.Executor {
		return nil, 0, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" was configured, but the program provided "+desc.Name)
	}
	caps, _ := desc.For(executor.RoleShape)
	max := role.MaxRounds
	if max == 0 {
		max = caps.MaxRounds
	}
	if max == 0 {
		max = project.DefaultExternalRounds
	}
	return ex, max, nil
}

// extSession is one external Shape or Refine invocation's session: a fresh Claude Code session
// whose startup and every round are bracketed by Kogen's own comparison of the Git execution
// state (hooks and executable-selecting configuration) and of the checkout, the raw index and HEAD.
type extSession struct {
	repo      *git.Repo
	pin       *git.Pin
	root      string
	home      string
	model     project.Role
	max       int
	rounds    int
	sess      executor.Session
	record    func(map[string]any)
	usage     executor.Usage
	usageSeen bool
}

// startExternal starts the role's fresh session on the stable task text.
func startExternal(ctx context.Context, ex executor.Executor, max int, repo *git.Repo, root, home, dir, run string, role project.Role, stable, dynamic string, schema json.RawMessage, record func(map[string]any), observe func(map[string]any)) (*extSession, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	pin, err := repo.TakePin()
	if err != nil {
		return nil, pinUnreadable(err)
	}
	task := executor.Task{
		Role: executor.RoleShape, Root: root, Brief: executor.Brief{Stable: stable, Dynamic: dynamic},
		Model: role.Model, Effort: role.Effort, RunID: run, Home: home, MaxRounds: max, Schema: schema, Dir: dir,
	}
	rec := func(e map[string]any) {
		record(e)
		if observe != nil {
			observe(e)
		}
	}
	sess, err := ex.Start(ctx, task, rec)
	x := &extSession{repo: repo, pin: pin, root: root, home: home, model: role, max: max, sess: sess, record: rec}
	// Startup runs the executor too: its changes are refused before any trusted Git command, and
	// before a startup failure is reported.
	if perr := x.comparePin(); perr != nil {
		x.close()
		return nil, perr
	}
	if err != nil {
		return nil, err
	}
	return x, nil
}

// pinUnreadable is the refusal for Git execution state that cannot be read: never accepted as
// unchanged.
func pinUnreadable(err error) error {
	return sys.Fail("candidate", "execution_state_unreadable",
		"the Git hooks and executable-selecting configuration could not be pinned or compared, so nothing was published: "+err.Error(), 1)
}

// comparePin is nil while the Git execution state equals the pin taken before the executor was
// started; otherwise the refusal naming each changed hook path or configuration key (never a value).
// It runs no hook and no configured program, and precedes every other Git command after the executor.
func (x *extSession) comparePin() error {
	now, err := x.repo.TakePin()
	if err != nil {
		return pinUnreadable(err)
	}
	changed := x.pin.Changes(now)
	if len(changed) == 0 {
		return nil
	}
	shown := changed[:min(len(changed), 20)]
	e := sys.Fail("candidate", "execution_state_changed",
		"the external session changed Git execution state (hooks or executable-selecting configuration), which it may only inspect; nothing was published and the change is left as it is: "+strings.Join(shown, ", "), 1)
	if len(changed) > len(shown) {
		e.Detail += fmt.Sprintf(" (and %d more)", len(changed)-len(shown))
	}
	for _, c := range changed[:min(len(changed), 20)] {
		e.Lines = append(e.Lines, "changed: "+c)
	}
	return e
}

func (x *extSession) close() {
	if x.sess != nil {
		x.sess.Close()
	}
}

// round runs one round. The Git execution state is compared with its pin, then the checkout, raw
// index and HEAD with their identity, before and after the round, whether or not the round
// succeeded; a difference is an
// unauthorized mutation, reported with the existing custody reasons and never reverted.
func (x *extSession) round(ctx context.Context, feedback string) (executor.RoundResult, error) {
	if x.rounds >= x.max {
		return executor.RoundResult{}, executor.RoundLimit(x.max)
	}
	if err := x.comparePin(); err != nil {
		return executor.RoundResult{}, err
	}
	before, err := checkoutIdentity(x.repo, x.root)
	if err != nil {
		return executor.RoundResult{}, err
	}
	x.rounds++
	res, rerr := x.sess.Round(ctx, executor.Input{Feedback: feedback})
	// Before any Git command that could obey a newly selected hook, filter or monitor.
	if err := x.comparePin(); err != nil {
		return res, err
	}
	after, err := checkoutIdentity(x.repo, x.root)
	if err != nil {
		return res, err
	}
	var created []string
	for p := range after.untracked {
		// A path the checkout had before the round, tracked or untracked, was not created by it
		// (for example a tracked file the session removed from the index).
		if _, existed := before.files[p]; !existed {
			created = append(created, p)
		}
	}
	sort.Strings(created)
	var failed []string
	for _, p := range created {
		if err := os.Remove(filepath.Join(x.root, p)); err != nil {
			failed = append(failed, p)
		}
		delete(after.files, p)
	}
	if len(failed) > 0 {
		return res, sys.Fail("candidate", "shape_untracked_remove_failed",
			"the Shape round created untracked files that could not be removed; nothing was published: "+strings.Join(failed, ", "), 1)
	}
	if len(created) > 0 {
		x.record(map[string]any{"event": "shape_untracked_removed", "paths": created})
	}
	if err := before.changedTo(after); err != nil {
		return res, err
	}
	if rerr != nil {
		return res, rerr
	}
	h := res.Handle
	x.record(map[string]any{
		"event": "executor_round", "role": executor.RoleShape, "round": x.rounds, "executor": h.Executor,
		"session_id": h.SessionID, "version": h.Version, "ending": string(res.Ending), "usage": res.Usage,
	})
	x.usage = sumUsage(x.usage, res.Usage, !x.usageSeen)
	x.usageSeen = true
	return res, nil
}

// summary is the role's identity and totals, retained once with the Shape/Refine evidence.
func (x *extSession) summary() map[string]any {
	h := x.sess.Handle()
	return map[string]any{
		"event": "executor_summary", "role": executor.RoleShape, "executor": h.Executor, "version": h.Version,
		"session_id": h.SessionID, "model": x.model.Model, "effort": x.model.Effort, "rounds": x.rounds, "usage": x.usage,
	}
}

func sumUsage(u, r executor.Usage, first bool) executor.Usage {
	add := func(a, b *int) *int {
		if a == nil || b == nil {
			return nil
		}
		s := *a + *b
		return &s
	}
	out := executor.Usage{Input: add(u.Input, r.Input), Cached: add(u.Cached, r.Cached), Output: add(u.Output, r.Output),
		Reasoning: add(u.Reasoning, r.Reasoning), State: r.State, Source: r.Source, Model: r.Model}
	if first {
		out = r
	} else {
		if u.CostUSD != nil && r.CostUSD != nil {
			c := *u.CostUSD + *r.CostUSD
			out.CostUSD = &c
		}
		if u.State != r.State {
			out.State = executor.UsagePartial
		}
	}
	return out
}

// submission decodes the structured result into the submission arguments.
func submissionArgs(raw json.RawMessage) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var args map[string]any
	if err := dec.Decode(&args); err != nil || args == nil {
		return nil, executor.Fail(executor.ReasonProtocol, "the shaper's structured output is not a JSON object")
	}
	return args, nil
}

// schemaOf is the parameter schema of an existing submission tool; no wrapper is added.
func schemaOf(tool string) json.RawMessage {
	b, _ := json.Marshal(agent.Defs(tool)[0]["parameters"])
	return b
}

// blocksText renders context blocks (text) as the task text.
func blocksText(blocks []any) string {
	var parts []string
	for _, b := range blocks {
		if m, ok := b.(map[string]any); ok {
			if t, ok := m["text"].(string); ok {
				parts = append(parts, t)
			}
		}
	}
	return strings.Join(parts, "\n\n")
}

// ---- the checkout identity ----

// identity is the state of the checkout the external session may not change: HEAD, the raw
// index bytes and every tracked file (including tracked ignored ones) and nonignored addition
// with its mode. Kogen-owned run evidence under .kogen/local is not part of it.
type identity struct {
	head, index string
	files       map[string]string
	untracked   map[string]bool // untracked, not ignored paths
}

func checkoutIdentity(repo *git.Repo, root string) (identity, error) {
	repo = repo.Observing() // no configured fsmonitor runs while observing
	id := identity{head: repo.Head(), files: map[string]string{}, untracked: map[string]bool{}}
	listing, err := repo.OK("ls-files", "-s", "-z")
	if err != nil {
		return id, err
	}
	sum := sha256.Sum256([]byte(listing))
	id.index = hex.EncodeToString(sum[:])
	others, err := repo.OK("ls-files", "-z", "--others", "--exclude-standard")
	if err != nil {
		return id, err
	}
	for _, rel := range strings.Split(others, "\x00") {
		if rel != "" && rel != ".kogen/local" && !strings.HasPrefix(rel, ".kogen/local/") {
			id.untracked[rel] = true
		}
	}
	out, err := repo.OK("ls-files", "-z", "--cached", "--others", "--exclude-standard")
	if err != nil {
		return id, err
	}
	for _, rel := range strings.Split(out, "\x00") {
		if rel == "" || rel == ".kogen/local" || strings.HasPrefix(rel, ".kogen/local/") {
			continue
		}
		full := filepath.Join(root, rel)
		st, err := os.Lstat(full)
		if err != nil {
			id.files[rel] = "absent"
			continue
		}
		h := sha256.New()
		fmt.Fprintf(h, "%o\x00", st.Mode())
		switch {
		case st.Mode()&fs.ModeSymlink != 0:
			t, _ := os.Readlink(full)
			h.Write([]byte(t))
		case st.Mode().IsRegular():
			data, err := os.ReadFile(full)
			if err != nil {
				return id, err
			}
			h.Write(data)
		}
		id.files[rel] = hex.EncodeToString(h.Sum(nil))
	}
	return id, nil
}

// changedTo is nil when nothing changed, otherwise the existing custody stop: candidate/head_moved
// for HEAD, candidate/baseline_changed for the checkout or the raw index.
func (a identity) changedTo(b identity) error {
	if a.head != b.head {
		return sys.Fail("candidate", "head_moved",
			fmt.Sprintf("HEAD moved from %s to %s during an external session; nothing was published", shortRev(a.head), shortRev(b.head)), 1)
	}
	var changed []string
	for p, h := range b.files {
		if a.files[p] != h {
			changed = append(changed, p)
		}
	}
	for p := range a.files {
		if _, ok := b.files[p]; !ok {
			changed = append(changed, p)
		}
	}
	if a.index != b.index && len(changed) == 0 {
		changed = append(changed, "(the Git index)")
	}
	if len(changed) == 0 {
		return nil
	}
	sort.Strings(changed)
	e := sys.Fail("candidate", "baseline_changed",
		"the external session changed the checkout or the Git index, which it may only inspect; nothing was published and the change is left as it is", 1)
	for _, p := range changed[:min(len(changed), 20)] {
		e.Lines = append(e.Lines, "changed: "+p)
	}
	return e
}

func shortRev(s string) string {
	if len(s) > 8 {
		return s[:8]
	}
	if s == "" {
		return "(none)"
	}
	return s
}

// inspectedBy reports whether an executor event shows a completed, not denied read-only
// inspection tool call of the harness: only that, never the session's own statement, establishes
// that the checkout was inspected.
func inspectedBy(e map[string]any) bool {
	if e["event"] != "executor_tool" {
		return false
	}
	name, _ := e["name"].(string)
	denied, _ := e["denied"].(bool)
	switch name {
	case "Read", "Glob", "Grep", "LS", "Bash":
		return !denied
	}
	return false
}
