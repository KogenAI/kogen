package claudecode

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"kogen/executor"
)

// guardedTools are the tools whose every call must have run the PreToolUse hook.
var guardedTools = map[string]bool{"Write": true, "Edit": true, "MultiEdit": true, "NotebookEdit": true}

// roundRun is the state of one round's event stream.
type roundRun struct {
	s *session
	n int

	init      bool
	model     string
	ccVersion string

	toolNames map[string]string // tool_use_id -> tool name
	guarded   map[string]string // tool_use_id -> tool name, guarded tools only
	targets   map[string]target // tool_use_id -> the guarded call's target as of its tool_use line

	lines  int
	result map[string]any // the result event, once seen

	authFailed bool // an assistant event carried error authentication_failed
}

// line handles one stream-json line: malformed JSON, a failed gate or a broken hook protocol
// is a typed error and the caller stops the process group.
func (r *roundRun) line(b []byte) error {
	r.lines++
	ev, err := decodeObject(b)
	if err != nil {
		return executor.Fail(executor.ReasonProtocol, "line "+strconv.Itoa(r.lines)+" of the event stream is not a JSON object")
	}
	if r.result != nil {
		return executor.Fail(executor.ReasonProtocol, "the event stream continued after its result")
	}
	typ, _ := ev["type"].(string)
	sub, _ := ev["subtype"].(string)
	if !r.init {
		switch {
		case typ == "system" && sub == "init":
		case typ == "system" && (sub == "hook_started" || sub == "hook_response" || sub == "plugin_install"):
			return nil // the documented startup events that may precede init
		default:
			return executor.Fail(executor.ReasonProtocol, "the first event was "+quoteBound(typ+"/"+sub)+", not system/init")
		}
	}
	switch typ {
	case "system":
		if sub == "init" {
			return r.gate(ev)
		}
	case "assistant":
		if e, _ := ev["error"].(string); e == "authentication_failed" {
			r.authFailed = true
		}
		r.toolUses(ev)
	case "user":
		return r.toolResults(ev)
	case "result":
		r.result = ev
	}
	return nil
}

// gate is the per-round acceptance gate on the init event (audit section B).
func (r *roundRun) gate(ev map[string]any) error {
	if src, _ := ev["apiKeySource"].(string); src != "none" {
		return executor.Fail(executor.ReasonAuthRefused, "Claude Code reports its credential source as "+quoteBound(src)+", not the subscription sign-in (\"none\" API key); the round was stopped")
	}
	if sid, _ := ev["session_id"].(string); sid != r.s.sessionID {
		return executor.Fail(executor.ReasonProtocol, "Claude Code runs session "+quoteBound(sid)+", not the requested "+r.s.sessionID)
	}
	if mode, _ := ev["permissionMode"].(string); mode != "acceptEdits" {
		return executor.Fail(executor.ReasonProtocol, "Claude Code reports permission mode "+quoteBound(mode)+", not acceptEdits")
	}
	if servers, ok := ev["mcp_servers"].([]any); !ok || len(servers) != 0 {
		return executor.Fail(executor.ReasonProtocol, "Claude Code started with MCP servers or did not report them")
	}
	cwd, _ := ev["cwd"].(string)
	real, err := filepath.EvalSymlinks(cwd)
	if err != nil || cwd == "" || real != r.s.root {
		return executor.Fail(executor.ReasonProtocol, "Claude Code runs in "+quoteBound(cwd)+", not the checkout")
	}
	r.init = true
	r.model, _ = ev["model"].(string)
	r.ccVersion, _ = ev["claude_code_version"].(string)
	if r.ccVersion == "" {
		r.ccVersion = r.s.version
	}
	return nil
}

func (r *roundRun) toolUses(ev map[string]any) {
	for _, c := range contentItems(ev) {
		if t, _ := c["type"].(string); t != "tool_use" {
			continue
		}
		id, _ := c["id"].(string)
		name, _ := c["name"].(string)
		if id == "" {
			continue
		}
		if r.toolNames == nil {
			r.toolNames, r.guarded, r.targets = map[string]string{}, map[string]string{}, map[string]target{}
		}
		r.toolNames[id] = name
		if guardedTools[name] {
			r.guarded[id] = name
			if _, seen := r.targets[id]; !seen {
				input, _ := c["input"].(map[string]any)
				r.targets[id] = observeTarget(r.s.root, input)
			}
		}
	}
}

// toolResults emits tool events and enforces hook liveness: a guarded tool call that completed
// (or was denied) must have a sentinel record from the hook, and a hook denial must have
// actually blocked the call.
func (r *roundRun) toolResults(ev map[string]any) error {
	metas := map[string]string{} // tool_use_id -> permission decision
	if list, ok := ev["tool_result_meta"].([]any); ok {
		for _, m := range list {
			mm, _ := m.(map[string]any)
			id, _ := mm["id"].(string)
			pd, _ := mm["permission_decision"].(map[string]any)
			metas[id], _ = pd["decision"].(string)
		}
	}
	for _, c := range contentItems(ev) {
		if t, _ := c["type"].(string); t != "tool_result" {
			continue
		}
		id, _ := c["tool_use_id"].(string)
		isErr, _ := c["is_error"].(bool)
		name, known := r.toolNames[id]
		if !known {
			continue
		}
		denied := metas[id] == "reject"
		if _, ok := r.guarded[id]; ok {
			recs, err := readSentinels(r.s.pol.Log, r.s.pol.Nonce)
			if err != nil {
				return executor.Fail(executor.ReasonProtocol, "cannot read the hook log: "+bound(err.Error(), 100))
			}
			rec, ok := recs[id]
			if !ok && r.s.role == "shape" {
				r.s.emit(map[string]any{"event": "executor_hook", "round": r.n, "tool_use_id": id, "tool_name": name, "decision": "deny", "hook": "configuration", "message": "write tools are not available during Shape"})
				r.s.emit(map[string]any{"event": "executor_tool", "round": r.n, "name": name, "tool_use_id": id, "denied": true})
				continue
			}
			if !ok && isErr && r.targets[id].unchanged() {
				// Claude Code refused the call before the hook and nothing was written.
				r.s.emit(map[string]any{"event": "executor_tool", "round": r.n, "name": name, "tool_use_id": id, "denied": false, "rejected_before_hook": true})
				continue
			}
			if !ok {
				return executor.Fail(executor.ReasonProtocol, "hook did not run for the "+name+" call "+quoteBound(id)+"; the round was stopped")
			}
			r.s.emit(map[string]any{"event": "executor_hook", "round": r.n, "tool_use_id": id, "tool_name": name, "decision": rec.Decision, "hook": "pretool"})
			if rec.Decision == "deny" {
				denied = true
				if !isErr {
					return executor.Fail(executor.ReasonProtocol, "the "+name+" call "+quoteBound(id)+" was denied by the hook but ran; the round was stopped")
				}
			}
		}
		r.s.emit(map[string]any{"event": "executor_tool", "round": r.n, "name": name, "tool_use_id": id, "denied": denied})
	}
	return nil
}

// target is the file-system state of a guarded call's target path: observable (absent, or a
// regular file with its mode, size, modification time and content digest) or not.
type target struct {
	path       string // absolute; empty when the call named no path
	observable bool
	absent     bool
	mode       fs.FileMode
	size       int64
	mtime      time.Time
	sum        [sha256.Size]byte
}

// observeTarget records the state of the input's file_path, else notebook_path (the keys the
// hook reads); a relative path is resolved against the checkout root.
func observeTarget(root string, input map[string]any) target {
	for _, k := range []string{"file_path", "notebook_path"} {
		if p, ok := input[k].(string); ok && p != "" {
			if !filepath.IsAbs(p) {
				p = filepath.Join(root, p)
			}
			return observePath(p)
		}
	}
	return target{}
}

func observePath(p string) target {
	t := target{path: p}
	fi, err := os.Stat(p) // follows symlinks, as a write does
	if errors.Is(err, fs.ErrNotExist) {
		t.observable, t.absent = true, true
		return t
	}
	if err != nil || !fi.Mode().IsRegular() {
		return target{path: p}
	}
	f, err := os.Open(p)
	if err != nil {
		return target{path: p}
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return target{path: p}
	}
	t.observable, t.mode, t.size, t.mtime = true, fi.Mode(), fi.Size(), fi.ModTime()
	copy(t.sum[:], h.Sum(nil))
	return t
}

// unchanged reports whether the recorded state was observable and a fresh observation of the
// same path is identical.
func (t target) unchanged() bool {
	if !t.observable {
		return false
	}
	now := observePath(t.path)
	if !now.observable || now.absent != t.absent {
		return false
	}
	return t.absent || (now.mode == t.mode && now.size == t.size && now.mtime.Equal(t.mtime) && now.sum == t.sum)
}

// finish turns the seen result event and the process exit into the round's claim or error.
// exit is the process exit code (-1: signalled); killed means the adapter ended the process.
func (r *roundRun) finish(exit int, killed bool, stderrPath string) (executor.RoundResult, error) {
	s := r.s
	if !r.init {
		if exit != 0 {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code exited with status "+strconv.Itoa(exit)+" before starting"+stderrTail(stderrPath, s.a.redact))
		}
		return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "Claude Code ended without any event stream")
	}
	if r.result == nil {
		if exit != 0 {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code exited with status "+strconv.Itoa(exit)+" without a result"+stderrTail(stderrPath, s.a.redact))
		}
		return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the event stream ended without a result event")
	}
	res := r.result
	if sid, _ := res["session_id"].(string); sid != s.sessionID {
		return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the result belongs to session "+quoteBound(sid))
	}
	subtype, _ := res["subtype"].(string)
	isErr, ok := res["is_error"].(bool)
	if !ok {
		return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the result has no boolean is_error flag")
	}
	terminal, _ := res["terminal_reason"].(string)
	// `claude auth status` does not check a token against the server: an expired or revoked one
	// only shows up here, as an assistant authentication_failed error or a 401 error result.
	if s.a.opts.Token != "" && (r.authFailed || isErr && authFailedText(res["result"])) {
		return executor.RoundResult{}, executor.Fail(executor.ReasonAuthRefused, tokenRefusedHint)
	}

	var ending executor.Ending
	var claim string
	var structured json.RawMessage
	var blocker *executor.BlockerClaim
	turns := countOf(res["num_turns"])
	switch {
	case subtype == "error_max_turns":
		ending = executor.EndNoCall
		claim = "Claude Code stopped because it reached the turn limit of " + strconv.Itoa(s.a.opts.MaxTurns) + " turns for this round."
	case subtype == "success" && !isErr:
		if exit != 0 && !killed {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code exited with status "+strconv.Itoa(exit)+" after a success result"+stderrTail(stderrPath, s.a.redact))
		}
		ending = executor.EndFinish
		text, ok := res["result"].(string)
		if s.role == executor.RoleBuild {
			if !ok {
				return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the success result has no result text")
			}
			claim = boundBytes(text, claimBytes)
			if obj, isObj := res["structured_output"].(map[string]any); isObj {
				if raw, has := obj["blocker"]; has && raw != nil {
					ending = executor.EndBlocker
					blocker = decodeBlocker(raw)
				}
			}
		} else {
			// The submission is the final result's structured_output object, never the text.
			obj, isObj := res["structured_output"].(map[string]any)
			if !isObj || obj == nil {
				return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the final success result of the "+s.role+" role has no structured_output object")
			}
			raw, merr := json.Marshal(obj)
			if merr != nil {
				return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the structured_output of the "+s.role+" role is not encodable: "+bound(merr.Error(), 100))
			}
			structured = raw
			claim = boundBytes(text, claimBytes)
		}
	default:
		d := "Claude Code reported an error result: subtype " + quoteBound(subtype)
		if terminal != "" {
			d += ", terminal reason " + quoteBound(terminal)
		}
		if errs, ok := res["errors"].([]any); ok && len(errs) > 0 {
			if first, ok := errs[0].(string); ok {
				d += ": " + bound(first, 200)
			}
		}
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, d)
	}

	usage := s.mapUsage(res, r.model)
	denials := 0
	if d, ok := res["permission_denials"].([]any); ok {
		denials = len(d)
	}
	if r.model != "" {
		s.model = r.model
	}
	h := s.Handle()
	out := executor.RoundResult{Ending: ending, Claim: claim, Structured: structured, Blocker: blocker, Usage: usage, Handle: h}
	s.emit(map[string]any{
		"event": "executor_round_ended", "role": s.role, "round": r.n, "ending": string(ending),
		"usage": usageEvent(usage), "num_turns": turns, "permission_denials": denials,
		"session_id": s.sessionID, "model": r.model, "claude_code_version": r.ccVersion,
		"terminal_reason": terminal,
	})
	return out, nil
}

// mapUsage maps the result's per-invocation usage the way Kogen maps Anthropic usage
// (provider.anthropicUsage): Input = input_tokens + cache_read_input_tokens +
// cache_creation_input_tokens, only when all three are reported; Cached = cache reads;
// Output = output_tokens; Reasoning is not reported (nil). State is complete when Input,
// Cached and Output are all known, unknown when none is, otherwise partial (unknown fields stay
// nil, never zero). CostUSD is the delta of the cumulative total_cost_usd since the previous
// round of this session: Claude Code's API-equivalent estimate, not a bill.
func (s *session) mapUsage(res map[string]any, model string) executor.Usage {
	u := executor.Usage{State: executor.UsageUnknown, Source: executor.UsageHarness, Model: model}
	if usage, ok := res["usage"].(map[string]any); ok {
		in, cr, cw := countPtr(usage["input_tokens"]), countPtr(usage["cache_read_input_tokens"]), countPtr(usage["cache_creation_input_tokens"])
		u.Cached, u.Output = cr, countPtr(usage["output_tokens"])
		if in != nil && cr != nil && cw != nil {
			total := *in + *cr + *cw
			u.Input = &total
		}
	}
	switch {
	case u.Input != nil && u.Cached != nil && u.Output != nil:
		u.State = executor.UsageComplete
	case u.Input != nil || u.Cached != nil || u.Output != nil:
		u.State = executor.UsagePartial
	}
	if total, ok := number(res["total_cost_usd"]); ok && total >= s.prevCost {
		d := math.Round((total-s.prevCost)*1e9) / 1e9
		u.CostUSD = &d
		s.prevCost = total
	}
	return u
}

func usageEvent(u executor.Usage) map[string]any {
	m := map[string]any{"state": u.State, "source": u.Source, "input": nil, "cached": nil, "output": nil, "reasoning": nil, "cost_usd": nil, "model": u.Model}
	for k, p := range map[string]*int{"input": u.Input, "cached": u.Cached, "output": u.Output, "reasoning": u.Reasoning} {
		if p != nil {
			m[k] = *p
		}
	}
	if u.CostUSD != nil {
		m["cost_usd"] = *u.CostUSD
	}
	return m
}

// decodeObject decodes one JSON object keeping numbers exact.
func decodeObject(b []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var m map[string]any
	if err := dec.Decode(&m); err != nil || m == nil {
		return nil, errNotObject
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errNotObject
	}
	return m, nil
}

type notObject struct{}

func (notObject) Error() string { return "not a JSON object" }

var errNotObject error = notObject{}

func contentItems(ev map[string]any) []map[string]any {
	msg, _ := ev["message"].(map[string]any)
	list, _ := msg["content"].([]any)
	var out []map[string]any
	for _, c := range list {
		if m, ok := c.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

// countPtr is a nonnegative integer count, nil when absent or not one.
func countPtr(v any) *int {
	n, ok := v.(json.Number)
	if !ok {
		return nil
	}
	i, err := strconv.ParseInt(string(n), 10, 64)
	if err != nil || i < 0 || i > math.MaxInt32*1000 {
		return nil
	}
	c := int(i)
	return &c
}

func countOf(v any) int {
	if p := countPtr(v); p != nil {
		return *p
	}
	return 0
}

func number(v any) (float64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) || f < 0 {
		return 0, false
	}
	return f, true
}

// boundBytes keeps at most n bytes of s on a rune boundary, marking a truncation within n.
func boundBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	const mark = "\n[truncated]"
	cut := n - len(mark)
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + mark
}

// stderrTail is a short bounded excerpt of the round's stderr for an error message.
func stderrTail(path string, redact func(string) string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.Size() == 0 {
		return ""
	}
	const n = 400
	off := max(0, fi.Size()-n)
	buf := make([]byte, fi.Size()-off)
	k, _ := f.ReadAt(buf, off)
	s := strings.TrimSpace(redact(string(buf[:k])))
	if s == "" {
		return ""
	}
	return "; stderr: " + strings.ReplaceAll(bound(s, n), "\n", " | ")
}

// authFailedText reports whether a result text is Claude Code's 401 authentication failure.
func authFailedText(v any) bool {
	t, _ := v.(string)
	return strings.Contains(t, "Failed to authenticate") || strings.Contains(t, "API Error: 401")
}

// decodeBlocker types a Build blocker object. Anything but exactly the three typed fields
// (paths, reason, evidence) is an empty claim, which Kogen refuses.
func decodeBlocker(v any) *executor.BlockerClaim {
	raw, err := json.Marshal(v)
	if err != nil {
		return &executor.BlockerClaim{}
	}
	var keys map[string]json.RawMessage
	if json.Unmarshal(raw, &keys) != nil || len(keys) != 3 {
		return &executor.BlockerClaim{}
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var c executor.BlockerClaim
	if dec.Decode(&c) != nil {
		return &executor.BlockerClaim{}
	}
	for _, k := range []string{"paths", "reason", "evidence"} {
		if _, ok := keys[k]; !ok {
			return &executor.BlockerClaim{}
		}
	}
	return &c
}
