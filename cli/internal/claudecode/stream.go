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
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-loop/sys"
)

// guardedTools are the tools whose every call must have run the PreToolUse hook.
var guardedTools = map[string]bool{"Write": true, "Edit": true, "MultiEdit": true, "NotebookEdit": true}

// roundRun is the state of one round's event stream.
type roundRun struct {
	streamLostBytes, streamLostLines, stderrLostBytes int64
	artifact                                          string
	keptBytes                                         int64
	persistFailed                                     bool           // a retained artifact failed to persist; a successful result must not be reported
	endSignal                                         syscall.Signal // the signal that ended the process; 0 when it exited with a status

	s                 *session
	n                 int
	deadlineRemaining any
	interrupted       bool

	init      bool
	modelSeen bool
	model     string
	ccVersion string

	toolNames map[string]string // tool_use_id -> tool name
	guarded   map[string]string // tool_use_id -> tool name, guarded tools only
	targets   map[string]target // tool_use_id -> the guarded call's target as of its tool_use line
	arguments map[string]any    // tool_use_id -> the call's redacted, bounded input as of its tool_use line

	hookLog sentinelLog

	guardedOrder []string             // guarded tool_use_ids in tool_use order
	hookEvents   map[string]*hookCall // tool_use_id -> the hook events attributed to the call
	hookCause    string               // set when the round stopped for a hook that did not run
	hookStderr   string

	lines       int
	compactions int
	result      map[string]any // the result event, once seen

	authFailed     bool // an assistant event carried error authentication_failed
	overloaded     bool
	rateLimited    bool
	rateLimitCount int
	rateLimitInfo  map[string]any
	pending        map[string]bool

	// Round profile: observation only, reported in the terminal event.
	started           time.Time // the round's run state was created
	procStarted       time.Time // the Claude Code process was started
	received          time.Time // receipt of the line being handled
	lastLine          time.Time // receipt of the previous line, zero before the first
	maxGap            time.Duration
	initAfter         time.Duration // process start to the accepted init line
	initSeen          bool
	ignored           map[string]int // ignored type/subtype key -> count
	eventsAfterResult int
}

const (
	maxIgnoredKeys     = 16
	maxIgnoredKeyBytes = 64
)

// receive notes the receipt of one stdout line, before it is redacted or parsed.
func (r *roundRun) receive(now time.Time) {
	r.received = now
	if !r.lastLine.IsZero() {
		r.maxGap = max(r.maxGap, now.Sub(r.lastLine))
	}
	r.lastLine = now
}

// ignore counts a line the dispatch accepted without interpreting it.
func (r *roundRun) ignore(typ, sub string) {
	key := typ
	if sub != "" {
		key += "/" + sub
	}
	if len(key) > maxIgnoredKeyBytes {
		cut := maxIgnoredKeyBytes
		for cut > 0 && !isRuneStart(key[cut]) {
			cut--
		}
		key = key[:cut]
	}
	if _, ok := r.ignored[key]; !ok {
		if len(r.ignored) >= maxIgnoredKeys {
			return
		}
		if r.ignored == nil {
			r.ignored = map[string]int{}
		}
	}
	r.ignored[key]++
}

// addProfile adds the round's profile fields to a terminal event.
func (r *roundRun) addProfile(event map[string]any) {
	event["wall_ms"] = time.Since(r.started).Milliseconds()
	if r.initSeen {
		event["init_ms"] = r.initAfter.Milliseconds()
	}
	event["max_line_gap_ms"] = r.maxGap.Milliseconds()
	if r.eventsAfterResult != 0 {
		event["events_after_result"] = r.eventsAfterResult
	}
	if len(r.ignored) != 0 {
		event["ignored_events"] = r.ignored
	}
}

// line handles one stream-json line: malformed JSON, a failed gate or a broken hook protocol
// is a typed error and the caller stops the process group.
func (r *roundRun) line(b []byte) error {
	return r.lineReceived(b, b)
}

func (r *roundRun) lineReceived(b, received []byte) error {
	r.lines++
	ev, err := decodeObject(b)
	if r.result != nil {
		typ, _ := ev["type"].(string)
		sub, _ := ev["subtype"].(string)
		if err != nil || !(typ == "rate_limit_event" || typ == "system" && (sub == "hook_started" || sub == "hook_response" || sub == "plugin_install")) {
			return executor.Fail(executor.ReasonProtocol, "the event stream continued after its result")
		}
		if r.eventsAfterResult < math.MaxInt32 {
			r.eventsAfterResult++
		}
	} else if err != nil {
		return executor.Fail(executor.ReasonProtocol, "line "+strconv.Itoa(r.lines)+" of the event stream is not a JSON object")
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
		switch sub {
		case "init":
			return r.gate(ev)
		case "hook_started":
			r.hookStarted(ev)
		case "hook_response":
			r.hookResponse(ev)
		case "plugin_install":
		case "compact_boundary":
			metadata, _ := ev["compact_metadata"].(map[string]any)
			trigger, _ := metadata["trigger"].(string)
			if trigger != "" {
				var preTokens any
				if n := countPtr(metadata["pre_tokens"]); n != nil {
					preTokens = *n
				}
				r.compactions++
				r.s.emit(map[string]any{"event": "executor_context_compacted", "role": r.s.role, "round": r.n, "trigger": trigger, "pre_tokens": preTokens})
			}
		default:
			r.ignore(typ, sub)
		}
	case "assistant":
		if e, _ := ev["error"].(string); e == "authentication_failed" {
			r.authFailed = true
		}
		if e, _ := ev["error"].(string); e == "overloaded" {
			r.overloaded = true
		}
		if e, _ := ev["error"].(string); e == "rate_limit" {
			r.rateLimited = true
		}
		r.toolUses(ev)
	case "user":
		original, _ := decodeObject(received)
		return r.toolResults(ev, original)
	case "rate_limit_event":
		r.rateLimitCount++
		info, _ := ev["rate_limit_info"].(map[string]any)
		if status, ok := info["status"].(string); ok && status != "" {
			snapshot := map[string]any{"status": limitPrefix(status)}
			if typ, ok := info["rateLimitType"].(string); ok {
				snapshot["rateLimitType"] = limitPrefix(typ)
			}
			if reset, ok := info["resetsAt"].(json.Number); ok {
				snapshot["resetsAt"] = reset
			}
			r.rateLimitInfo = snapshot
		}
	case "result":
		r.result = ev
	default:
		r.ignore(typ, sub)
	}
	return nil
}

// limitPrefix bounds telemetry without adding a truncation marker.
func limitPrefix(s string) string {
	if len(s) <= 128 {
		return s
	}
	cut := 128
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return s[:cut]
}

func (r *roundRun) addRateLimit(event map[string]any) {
	if r.rateLimitCount != 0 {
		event["rate_limit_event_count"] = r.rateLimitCount
	}
	if r.rateLimitInfo != nil {
		event["rate_limit_info"] = r.rateLimitInfo
	}
}

// gate is the per-round acceptance gate on the init event (audit section B).
func (r *roundRun) gate(ev map[string]any) error {
	r.model, _ = ev["model"].(string)
	r.modelSeen = r.model != ""
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
	if !r.procStarted.IsZero() {
		r.initSeen, r.initAfter = true, r.received.Sub(r.procStarted)
	}
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
		if r.arguments == nil {
			r.arguments = map[string]any{}
		}
		if _, seen := r.arguments[id]; !seen {
			r.arguments[id] = r.s.toolArguments(c["input"])
		}
		if r.pending == nil {
			r.pending = map[string]bool{}
		}
		r.pending[id] = true
		if guardedTools[name] {
			if _, seen := r.guarded[id]; !seen {
				r.guardedOrder = append(r.guardedOrder, id)
			}
			r.guarded[id] = name
			if _, seen := r.targets[id]; !seen {
				input, _ := c["input"].(map[string]any)
				r.targets[id] = observeTarget(r.s.root, input)
			}
		}
	}
}

// hookCall is the most recent PreToolUse hook start and response attributed to one guarded call.
type hookCall struct {
	started  bool
	hookID   string
	response *hookResponse
}

// hookResponse is what is kept of an attributed hook response.
type hookResponse struct {
	outcome  string
	exitCode *int64
	excerpt  string // bounded and redacted stderr, empty when there is none
}

// hookStarted attributes a PreToolUse hook start to the earliest pending guarded call of the
// tool named by the hook, which has no attributed start yet. Claude Code's hook events carry
// no tool_use_id.
func (r *roundRun) hookStarted(ev map[string]any) {
	if event, _ := ev["hook_event"].(string); event != "PreToolUse" {
		return
	}
	hookName, _ := ev["hook_name"].(string)
	tool, ok := strings.CutPrefix(hookName, "PreToolUse:")
	hookID, idOK := ev["hook_id"].(string)
	if !ok || !idOK {
		return
	}
	for _, id := range r.guardedOrder {
		if !r.pending[id] || r.guarded[id] != tool || r.hookEvents[id] != nil && r.hookEvents[id].started {
			continue
		}
		if r.hookEvents == nil {
			r.hookEvents = map[string]*hookCall{}
		}
		call := r.hookEvents[id]
		if call == nil {
			call = &hookCall{}
			r.hookEvents[id] = call
		}
		call.started, call.hookID = true, hookID
		return
	}
}

// hookResponse attributes a PreToolUse hook response to the call whose attributed start has the
// same hook_id; a later response replaces an earlier one.
func (r *roundRun) hookResponse(ev map[string]any) {
	if event, _ := ev["hook_event"].(string); event != "PreToolUse" {
		return
	}
	hookID, ok := ev["hook_id"].(string)
	if !ok {
		return
	}
	for _, id := range r.guardedOrder {
		call := r.hookEvents[id]
		if call == nil || !call.started || call.hookID != hookID {
			continue
		}
		resp := &hookResponse{}
		resp.outcome, _ = ev["outcome"].(string)
		if n, ok := ev["exit_code"].(json.Number); ok {
			if code, err := strconv.ParseInt(n.String(), 10, 64); err == nil {
				resp.exitCode = &code
			}
		}
		stderr, _ := ev["stderr"].(string)
		if r.s.a != nil {
			stderr = redactEnvValues(stderr, secretEnvValues(r.s.a.opts.Env))
		}
		resp.excerpt = bound(strings.TrimSpace(stderr), 200)
		call.response = resp
		return
	}
}

// redactEnvValues replaces each of the secret-named environment values in s.
func redactEnvValues(s string, values []string) string {
	for _, v := range values {
		s = strings.ReplaceAll(s, v, redactMark)
	}
	return s
}

// hookFailure is the stop for a guarded call whose hook did not run. It names the cause from
// the hook events attributed to the call and keeps it for the round's failure event.
func (r *roundRun) hookFailure(id, name string) error {
	cause, excerpt := "not_started", ""
	if call := r.hookEvents[id]; call != nil && call.started {
		resp := call.response
		switch {
		case resp == nil:
			cause = "no_response"
		case resp.outcome == "timeout" || resp.outcome == "cancelled":
			cause, excerpt = "timeout", resp.excerpt
		case resp.exitCode != nil:
			cause, excerpt = "exit_"+strconv.FormatInt(*resp.exitCode, 10), resp.excerpt
		default:
			cause, excerpt = "exit_unknown", resp.excerpt
		}
	}
	r.hookCause, r.hookStderr = cause, excerpt
	detail := "hook did not run for the " + name + " call " + quoteBound(id) + "; the round was stopped; hook_cause " + cause
	if excerpt != "" {
		detail += "; hook_stderr " + strconv.Quote(excerpt)
	}
	return executor.Fail(executor.ReasonProtocol, detail)
}

// toolResults emits tool events and enforces hook liveness: a guarded tool call that completed
// (or was denied) must have a sentinel record from the hook, and a hook denial must have
// actually blocked the call.
func (r *roundRun) toolResults(ev, original map[string]any) error {
	metas := map[string]string{} // tool_use_id -> permission decision
	if list, ok := ev["tool_result_meta"].([]any); ok {
		for _, m := range list {
			mm, _ := m.(map[string]any)
			id, _ := mm["id"].(string)
			pd, _ := mm["permission_decision"].(map[string]any)
			metas[id], _ = pd["decision"].(string)
		}
	}
	originalItems := contentItems(original)
	for i, c := range contentItems(ev) {
		if t, _ := c["type"].(string); t != "tool_result" {
			continue
		}
		id, _ := c["tool_use_id"].(string)
		isErr, _ := c["is_error"].(bool)
		var result map[string]any
		if i < len(originalItems) {
			result = originalItems[i]
		}
		size, items := resultSize(result["content"])
		resultErr, _ := result["is_error"].(bool)
		delete(r.pending, id)
		name, known := r.toolNames[id]
		if !known {
			continue
		}
		denied := metas[id] == "reject"
		if _, ok := r.guarded[id]; ok {
			recs, err := r.hookLog.read(r.s.pol.Log, r.s.pol.Nonce)
			if err != nil {
				return executor.Fail(executor.ReasonProtocol, "cannot read the hook log: "+bound(err.Error(), 100))
			}
			rec, ok := recs[id]
			if !ok && isErr && r.targets[id].unchanged() {
				if r.s.role == "shape" {
					r.s.emit(map[string]any{"event": "executor_hook", "round": r.n, "tool_use_id": id, "tool_name": name, "decision": "deny", "hook": "configuration", "message": "write tools are not available during Shape"})
					r.s.emit(map[string]any{"event": "executor_tool", "round": r.n, "name": name, "tool_use_id": id, "denied": true, "arguments": r.arguments[id], "result_bytes": size, "result_error": resultErr, "result_items": items})
					continue
				}
				// Claude Code refused the call before the hook and nothing was written.
				r.s.emit(map[string]any{"event": "executor_tool", "round": r.n, "name": name, "tool_use_id": id, "denied": false, "rejected_before_hook": true, "arguments": r.arguments[id], "result_bytes": size, "result_error": resultErr, "result_items": items})
				continue
			}
			if !ok {
				return r.hookFailure(id, name)
			}
			r.s.emit(hookEvent(r.n, id, name, rec))
			if rec.Decision == "deny" {
				denied = true
				if !isErr {
					return executor.Fail(executor.ReasonProtocol, "the "+name+" call "+quoteBound(id)+" was denied by the hook but ran; the round was stopped")
				}
			}
		}
		r.s.emit(map[string]any{"event": "executor_tool", "round": r.n, "name": name, "tool_use_id": id, "denied": denied, "arguments": r.arguments[id], "result_bytes": size, "result_error": resultErr, "result_items": items})
	}
	return nil
}

// hookEvent builds the executor_hook event of one pretool sentinel record. A denial also names its
// reason and, when the record has one, its path, verbatim as the hook log holds them.
func hookEvent(round int, id, name string, rec sentinel) map[string]any {
	e := map[string]any{"event": "executor_hook", "round": round, "tool_use_id": id, "tool_name": name, "decision": rec.Decision, "hook": "pretool"}
	if rec.Decision == "deny" {
		e["reason"] = rec.Reason
		if rec.Path != "" {
			e["path"] = rec.Path
		}
	}
	return e
}

// checkUnanswered validates guarded calls still pending at an accepted result, in tool_use order.
// Every call is validated before any event is emitted, so a rejected round reports none of them.
func (r *roundRun) checkUnanswered() error {
	type unanswered struct {
		id, name string
		rec      *sentinel
		denied   bool
	}
	var calls []unanswered
	for _, id := range r.guardedOrder {
		if !r.pending[id] {
			continue
		}
		name := r.guarded[id]
		recs, err := r.hookLog.read(r.s.pol.Log, r.s.pol.Nonce)
		if err != nil {
			return executor.Fail(executor.ReasonProtocol, "cannot read the hook log: "+bound(err.Error(), 100))
		}
		rec, found := recs[id]
		if !found && !r.targets[id].unchanged() {
			return r.hookFailure(id, name)
		}
		denied := found && rec.Decision == "deny"
		if denied && !r.targets[id].unchanged() {
			return executor.Fail(executor.ReasonProtocol, "the "+name+" call "+quoteBound(id)+" was denied by the hook but ran; the round was stopped")
		}
		c := unanswered{id: id, name: name, denied: denied}
		if found {
			c.rec = &rec
		}
		calls = append(calls, c)
	}
	for _, c := range calls {
		if c.rec != nil {
			r.s.emit(hookEvent(r.n, c.id, c.name, *c.rec))
		}
		r.s.emit(map[string]any{"event": "executor_tool", "round": r.n, "name": c.name, "tool_use_id": c.id, "denied": c.denied, "arguments": r.arguments[c.id], "unanswered": true})
	}
	return nil
}

// resultSize counts decoded text bytes and content items without retaining the content.
func resultSize(content any) (int, int) {
	switch v := content.(type) {
	case string:
		return len(v), 1
	case []any:
		size := 0
		for _, item := range v {
			block, _ := item.(map[string]any)
			if typ, _ := block["type"].(string); typ == "text" {
				text, _ := block["text"].(string)
				size += len(text)
			}
		}
		return size, len(v)
	}
	return 0, 0
}

// target is the file-system state of a guarded call's target path: observable (absent, or a
// regular file at most 1 MiB with its mode, size, modification time and content digest) or not.
// Without hook evidence an oversized target cannot qualify as a rejected-before-hook
// unchanged target, even on error; it causes an executor/protocol stop.
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

const maxTargetDigest = 1 << 20

func observePath(p string) target {
	t := target{path: p}
	fi, err := os.Stat(p) // follows symlinks, as a write does
	if errors.Is(err, fs.ErrNotExist) {
		t.observable, t.absent = true, true
		return t
	}
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > maxTargetDigest {
		return target{path: p}
	}
	f, err := os.Open(p)
	if err != nil {
		return target{path: p}
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(f, maxTargetDigest))
	after, statErr := f.Stat()
	if err != nil || statErr != nil || n != fi.Size() || after.Size() != fi.Size() || after.Mode() != fi.Mode() || !after.ModTime().Equal(fi.ModTime()) {
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

// processEnd words how the process ended: by a signal, or with an exit status.
func (r *roundRun) processEnd(exit int) string {
	return processEnd(r.endSignal, exit)
}

// processEnd words how a process ended: by sig when it is not 0, otherwise with the exit status.
func processEnd(sig syscall.Signal, exit int) string {
	if sig != 0 {
		return "was ended by signal " + strconv.Itoa(int(sig)) + " (" + sig.String() + ")"
	}
	return "exited with status " + strconv.Itoa(exit)
}

// finish turns the seen result event and the process exit into the round's claim or error.
// exit is the process exit code (-1: signalled); killed means the adapter ended the process.
func (r *roundRun) finish(exit int, killed bool, stderrPath string) (executor.RoundResult, error) {
	s := r.s
	if !r.init {
		if exit != 0 {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code "+r.processEnd(exit)+" before starting"+stderrTail(stderrPath, s.a.redact))
		}
		return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "Claude Code ended without any event stream")
	}
	if r.result == nil {
		if exit != 0 {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code "+r.processEnd(exit)+" without a result"+stderrTail(stderrPath, s.a.redact))
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
	// A Cloudflare challenge also reads "Failed to authenticate", but it blocks the network
	// path, not the sign-in: classify it before the auth check.
	if isErr && cloudflareBlocked(res) {
		return executor.RoundResult{}, executor.Fail(executor.ReasonProviderBlocked, "Cloudflare challenge: the provider's network edge answered Claude Code with HTTP 403 "+
			"\"Attention Required! | Cloudflare\" instead of the API; the sign-in was not judged")
	}
	// `claude auth status` checks local state, not whether the server accepts the sign-in.
	if isErr && (r.authFailed || authFailedText(res)) {
		detail := "Claude Code did not accept the sign-in; sign in again with `kogen provider login claude-code`"
		if s.a.opts.Token != "" {
			detail = tokenRefusedHint
		}
		return executor.RoundResult{}, executor.Fail(executor.ReasonAuthRefused, detail)
	}

	var ending executor.Ending
	var claim string
	var structured json.RawMessage
	var blocker *executor.BlockerClaim
	turns := countOf(res["num_turns"])
	switch {
	case subtype == "error_max_turns":
		ending = executor.EndNoCall
		claim = "Claude Code stopped because it reached the turn limit of " + strconv.Itoa(maxTurns) + " turns for this round."
	case subtype == "success" && !isErr:
		if exit != 0 && !killed {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code "+r.processEnd(exit)+" after a success result"+stderrTail(stderrPath, s.a.redact))
		}
		ending = executor.EndFinish
		text, ok := res["result"].(string)
		if s.role == executor.RoleBuild {
			if !ok {
				return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the success result has no result text")
			}
			claim = boundBytes(text, claimBytes)
			// The Build's submission schema is its own (the task's); of its result the adapter
			// reads only the executor contract's blocker claim.
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
		// Claude Code refuses a prompt over the model's context: a context result, not an
		// ordinary failure, and never retried or clipped.
		if isErr && !r.authFailed && !authFailedText(res) && (terminal == "blocking_limit" || promptTooLong(res) != "") {
			text := promptTooLong(res)
			if text == "" {
				text, _ = res["result"].(string)
			}
			return executor.RoundResult{}, sys.Fail("candidate", "context_budget_exceeded", "Claude Code refused the "+s.role+" prompt as too long for the model's context (terminal reason "+
				quoteBound(terminal)+": "+bound(text, 200)+"); the round's prompt was "+strconv.Itoa(s.promptLen)+" bytes; nothing was clipped or retried", 1)
		}
		reason := executor.ReasonFailed
		if isErr && !r.authFailed && !authFailedText(res) && ((subtype == "success" && terminal == "api_error" && r.rateLimited) || usageLimitText(res["result"]) || usageLimitText(res["errors"])) {
			if len(r.pending) != 0 {
				return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "usage-limit result left tool calls unfinished; continuation is unsafe")
			}
			reason = executor.ReasonUsageLimit
		}
		if reason == executor.ReasonFailed && isErr && !r.authFailed && !authFailedText(res) {
			diagnostic := providerDiagnostic(res["result"])
			if diagnostic == "" {
				diagnostic = providerDiagnostic(res["errors"])
			}
			if diagnostic == "" && r.overloaded {
				diagnostic = "overloaded"
			}
			if diagnostic != "" {
				return executor.RoundResult{}, executor.Fail(executor.ReasonProviderUnavailable, "Claude Code provider unavailable: "+diagnostic)
			}
		}
		return executor.RoundResult{}, executor.Fail(reason, d)
	}

	if err := r.checkUnanswered(); err != nil {
		return executor.RoundResult{}, err
	}

	if r.persistFailed {
		return executor.RoundResult{}, errArtifactWrite
	}
	usage := s.mapUsage(res, r.model)
	if r.model != "" {
		s.model = r.model
	}
	h := s.Handle()
	out := executor.RoundResult{Ending: ending, Claim: claim, Structured: structured, Blocker: blocker, Usage: usage, Handle: h}
	event := map[string]any{
		"event": "executor_round_ended", "role": s.role, "round": r.n, "ending": string(ending),
		"usage": usageEvent(usage), "num_turns": turns,
		"session_id": s.sessionID, "claude_code_version": r.ccVersion,
		"terminal_reason": terminal, "deadline_remaining_ms": r.deadlineRemaining, "compactions": r.compactions,
	}
	r.addModels(event)
	addModelUsage(event, res)
	s.addModelRoundUsage(event, res, true)
	r.addDenials(event)
	r.addRateLimit(event)
	r.addProfile(event)
	r.addPersistence(event)
	s.emit(event)
	return out, nil
}

// addModels projects this round's requested and observed models into terminal telemetry.
func (r *roundRun) addModels(event map[string]any) {
	event["requested_model"] = bound(r.s.a.redact(r.s.task.Model), 256)
	if r.modelSeen {
		event["model"] = bound(r.s.a.redact(r.model), 256)
	}
}

// mapUsage maps the result's per-invocation usage the way Kogen maps Anthropic usage
// (provider.anthropicUsage): Input = input_tokens + cache_read_input_tokens +
// cache_creation_input_tokens, only when all three are reported; Cached = cache reads;
// CacheWrite = cache creation; Output = output_tokens; Reasoning is not reported (nil). State is complete when Input,
// Cached and Output are all known, unknown when no counts are known, otherwise partial (unknown fields stay
// nil, never zero). CostUSD is the delta of the cumulative total_cost_usd since the previous
// round of this session: Claude Code's API-equivalent estimate, not a bill.
func (s *session) mapUsage(res map[string]any, model string) executor.Usage {
	u, total, ok := s.usageOf(res, model)
	if ok {
		s.prevCost = total
	}
	s.costGap = !ok
	return u
}

// usageOf is mapUsage without advancing the session's cost baseline: it also returns the
// result's cumulative total and whether it is usable.
func (s *session) usageOf(res map[string]any, model string) (u executor.Usage, cumulative float64, advanced bool) {
	u = executor.Usage{State: executor.UsageUnknown, Source: executor.UsageHarness, Model: model}
	if usage, ok := res["usage"].(map[string]any); ok {
		in, cr, cw := countPtr(usage["input_tokens"]), countPtr(usage["cache_read_input_tokens"]), countPtr(usage["cache_creation_input_tokens"])
		u.Cached, u.CacheWrite, u.Output = cr, cw, countPtr(usage["output_tokens"])
		if in != nil && cr != nil && cw != nil {
			total := *in + *cr + *cw
			u.Input = &total
		}
	}
	switch {
	case u.Input != nil && u.Cached != nil && u.Output != nil:
		u.State = executor.UsageComplete
	case u.Input != nil || u.Cached != nil || u.CacheWrite != nil || u.Output != nil:
		u.State = executor.UsagePartial
	}
	if total, ok := number(res["total_cost_usd"]); ok {
		if !s.costGap && total >= s.prevCost {
			d := math.Round((total-s.prevCost)*1e9) / 1e9
			u.CostUSD = &d
		}
		return u, total, true
	}
	return u, 0, false
}

// addResult adds what the round's result line reported to a failed round's event: usage (as on
// executor_round_ended), num_turns, subtype and terminal_reason. A round whose stream never
// reached a result line, and a field the result did not report, add nothing. The session's cost
// baseline is not advanced.
func (r *roundRun) addResult(event map[string]any) {
	res := r.result
	if res == nil {
		return
	}
	addModelUsage(event, res)
	r.s.addModelRoundUsage(event, res, false)
	r.addDenials(event)
	_, hasUsage := res["usage"].(map[string]any)
	_, hasCost := res["total_cost_usd"].(json.Number)
	if hasUsage || hasCost {
		u, _, _ := r.s.usageOf(res, r.model)
		event["usage"] = usageEvent(u)
	}
	if n := countPtr(res["num_turns"]); n != nil {
		event["num_turns"] = *n
	}
	for _, k := range []string{"subtype", "terminal_reason"} {
		if v, ok := res[k].(string); ok && v != "" {
			event[k] = v
		}
	}
}

// addModelUsage observes the result breakdown without changing aggregate accounting.
func addModelUsage(event, res map[string]any) {
	breakdown, ok := res["modelUsage"].(map[string]any)
	if !ok {
		return
	}
	var ids []string
	for id, value := range breakdown {
		if _, ok := value.(map[string]any); ok {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return
	}
	sort.Strings(ids)
	entries := make([]map[string]any, 0, min(len(ids), 20))
	for _, id := range ids[:min(len(ids), 20)] {
		entry := map[string]any{"model": boundBytes(id, 256)}
		fields := breakdown[id].(map[string]any)
		for _, pair := range [][2]string{{"inputTokens", "input"}, {"cacheReadInputTokens", "cached"}, {"outputTokens", "output"}, {"costUSD", "cost_usd"}} {
			if nonnegativeJSONNumber(fields[pair[0]]) {
				entry[pair[1]] = fields[pair[0]]
			}
		}
		entries = append(entries, entry)
	}
	event["model_usage"] = entries
	event["model_usage_scope"] = "session"
	if len(ids) > 20 {
		event["model_usage_omitted"] = len(ids) - 20
	}
}

// modelUsageFields maps the result's per-model counter names to the event's keys.
var modelUsageFields = [][2]string{{"inputTokens", "input"}, {"cacheReadInputTokens", "cached"}, {"outputTokens", "output"}, {"costUSD", "cost_usd"}}

// addModelRoundUsage adds model_round_usage next to model_usage: per model, each field's value
// minus the same model's value in the session's last successful round (zero for a model or field
// not seen before), rounded to 9 decimals. A field whose number is missing or invalid, or whose
// difference is negative, is left out; an entry without fields is left out, and so is the key
// when no entry is left. With advance (a successful round) the baseline then takes the new value
// of every field that was a valid number, including a lowered one; a failed round passes false
// and leaves the baseline as it was.
func (s *session) addModelRoundUsage(event, res map[string]any, advance bool) {
	if _, ok := event["model_usage"]; !ok {
		return
	}
	breakdown, _ := res["modelUsage"].(map[string]any)
	var ids []string
	for id, value := range breakdown {
		if _, ok := value.(map[string]any); ok {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	var entries []map[string]any
	for _, id := range ids[:min(len(ids), 20)] {
		fields := breakdown[id].(map[string]any)
		base := s.modelBase[id]
		entry := map[string]any{"model": boundBytes(id, 256)}
		found := false
		for _, pair := range modelUsageFields {
			v, ok := number(fields[pair[0]])
			if !ok {
				continue
			}
			if d := math.Round((v-base[pair[1]])*1e9) / 1e9; v >= base[pair[1]] {
				entry[pair[1]] = d
				found = true
			}
			if advance {
				if s.modelBase == nil {
					s.modelBase = map[string]map[string]float64{}
				}
				if s.modelBase[id] == nil {
					s.modelBase[id] = map[string]float64{}
				}
				s.modelBase[id][pair[1]] = v
			}
		}
		if found {
			entries = append(entries, entry)
		}
	}
	if len(entries) > 0 {
		event["model_round_usage"] = entries
	}
}

// nonnegativeJSONNumber checks the decoded JSON number without float64 overflow or
// underflow changing its validity or sign.
func nonnegativeJSONNumber(v any) bool {
	n, ok := v.(json.Number)
	if !ok {
		return false
	}
	s := string(n)
	if !strings.HasPrefix(s, "-") {
		return true
	}
	for _, c := range s[1:] {
		if c == 'e' || c == 'E' {
			break
		}
		if c >= '1' && c <= '9' {
			return false
		}
	}
	return true
}

// addDenials projects the already redacted result into bounded terminal telemetry.
func (r *roundRun) addDenials(event map[string]any) {
	d, ok := r.result["permission_denials"].([]any)
	event["permission_denials"] = len(d)
	if !ok {
		return
	}
	calls := make([]any, 0, min(len(d), 32))
	var env []string
	if r.s.a != nil {
		env = secretEnvValues(r.s.a.opts.Env)
	}
	for _, entry := range d {
		obj, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		name, ok := obj["tool_name"].(string)
		if !ok || name == "" {
			continue
		}
		if len(calls) == 32 {
			break
		}
		call := map[string]any{"name": processValue(name, env), "arguments": r.s.toolArguments(obj["tool_input"])}
		if id, ok := obj["tool_use_id"].(string); ok {
			call["tool_use_id"] = processValue(id, env)
		}
		calls = append(calls, call)
	}
	event["permission_denial_calls"] = calls
	event["permission_denials_omitted"] = len(d) - len(calls)
}

func usageEvent(u executor.Usage) map[string]any {
	m := map[string]any{"state": u.State, "source": u.Source, "input": nil, "cached": nil, "cache_write": nil, "output": nil, "reasoning": nil, "cost_usd": nil, "model": u.Model}
	for k, p := range map[string]*int{"input": u.Input, "cached": u.Cached, "cache_write": u.CacheWrite, "output": u.Output, "reasoning": u.Reasoning} {
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

// resultTexts lists the strings of a result's text and its errors list, in that order.
// Non-string items are skipped.
func resultTexts(res map[string]any) []string {
	var out []string
	if t, ok := res["result"].(string); ok {
		out = append(out, t)
	}
	if errs, ok := res["errors"].([]any); ok {
		for _, item := range errs {
			if t, ok := item.(string); ok {
				out = append(out, t)
			}
		}
	}
	return out
}

// promptTooLong returns the first text of a result or its errors that is Claude Code's
// refusal of an oversized prompt, or "" when there is none.
func promptTooLong(res map[string]any) string {
	for _, t := range resultTexts(res) {
		if strings.Contains(t, "Prompt is too long") {
			return t
		}
	}
	return ""
}

// cloudflareBlocked reports whether an error result is Cloudflare's challenge page (HTTP 403)
// and not the API's own answer.
func cloudflareBlocked(res map[string]any) bool {
	for _, t := range resultTexts(res) {
		l := strings.ToLower(t)
		if strings.Contains(l, "attention required! | cloudflare") || (strings.Contains(l, "cloudflare") && (strings.Contains(l, "api error: 403") || strings.Contains(l, "you have been blocked") || strings.Contains(l, "cf-ray") || strings.Contains(l, "ray id"))) {
			return true
		}
	}
	return false
}

// authFailedText reports whether a result or its errors carry Claude Code's 401 authentication failure.
func authFailedText(res map[string]any) bool {
	for _, t := range resultTexts(res) {
		if strings.Contains(t, "Failed to authenticate") || strings.Contains(t, "API Error: 401") {
			return true
		}
	}
	return false
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

// usageLimitText recognizes explicit diagnostics, not generic API failures or usage percentages.
func usageLimitText(v any) bool {
	switch x := v.(type) {
	case string:
		t := strings.ToLower(x)
		return strings.Contains(t, "rate limit") || strings.Contains(t, "rate_limit") || strings.Contains(t, "usage limit") || strings.Contains(t, "usage_limit") || strings.Contains(t, "quota exceeded")
	case []any:
		for _, item := range x {
			if usageLimitText(item) {
				return true
			}
		}
	}
	return false
}

// Match explicit overload wording or a status in an API error diagnostic, not incidental numbers.
var providerTrouble = regexp.MustCompile(`(?i)overloaded_error|\boverloaded\b|api error:\s*(?:http\s*)?5[0-9][0-9]\b`)

func providerDiagnostic(v any) string {
	switch x := v.(type) {
	case string:
		loc := providerTrouble.FindStringIndex(x)
		if loc == nil {
			return ""
		}
		// A status diagnostic can contain arbitrarily much whitespace between its
		// label and status. Keep both ends so truncation cannot discard the status.
		if loc[1]-loc[0] > 700 {
			return bound(x[loc[0]:loc[0]+100]+" ... "+x[loc[1]-100:loc[1]], 990)
		}
		start := max(0, loc[0]-200)
		for start < loc[0] && !isRuneStart(x[start]) {
			start++
		}
		return bound(boundBytes(x[start:], 990), 990)
	case []any:
		for _, item := range x {
			if d := providerDiagnostic(item); d != "" {
				return d
			}
		}
	}
	return ""
}
