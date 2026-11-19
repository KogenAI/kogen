package claudecode

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/KogenAI/kogen-executor/executor"
)

// Kogen's hook self-test of a candidate Claude Code version. The candidate runs once with the
// executor's real argument list and hook settings in a throwaway checkout, against a loopback
// stand-in for the model service inside Kogen, with a throwaway token and its own temporary
// configuration directory: the saved Claude Code token never reaches it. The stand-in scripts
// one write of a new file, one edit of an existing file and one write to a protected file.
const (
	// selfTestLimit bounds the candidate's whole scripted session.
	selfTestLimit = 3 * time.Minute
	selfTestModel = "claude-sonnet-5-5"

	// The failing checks.
	checkNoHookRecord  = "guarded call ran without a hook record"
	checkProtectedPass = "protected edit was not refused"
	checkWriteMissing  = "allowed write did not happen"
	checkNoSession     = "the candidate did not run the scripted session"

	newFileName       = "new.txt"
	newFileContent    = "written by the self-test\n"
	existingFileName  = "existing.txt"
	existingOriginal  = "one\n"
	existingEdited    = "edited\n"
	protectedFileName = "protected.txt"
	protectedOriginal = "protected\n"
)

const selfTestSchema = `{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}`

// scriptedCall is one tool call the stand-in asks the candidate to make.
type scriptedCall struct {
	id    string
	name  string
	input map[string]any
}

func scriptedCalls(root string) []scriptedCall {
	return []scriptedCall{
		{"toolu_selftest_1", "Write", map[string]any{"file_path": filepath.Join(root, newFileName), "content": newFileContent}},
		{"toolu_selftest_2", "Edit", map[string]any{"file_path": filepath.Join(root, existingFileName), "old_string": "one", "new_string": "edited"}},
		{"toolu_selftest_3", "Write", map[string]any{"file_path": filepath.Join(root, protectedFileName), "content": "overwritten by the self-test\n"}},
	}
}

// toolResult is what the candidate reported for one scripted call.
type toolResult struct{ isError bool }

// standIn is the loopback model service of the self-test: it answers every POST /v1/messages
// with the Anthropic streaming wire format, one scripted turn per request.
type standIn struct {
	token string
	calls []scriptedCall

	mu       sync.Mutex
	requests int
	results  map[string]toolResult
}

func newStandIn(token string, calls []scriptedCall) *standIn {
	return &standIn{token: token, calls: calls, results: map[string]toolResult{}}
}

func (s *standIn) snapshot() (requests int, results map[string]toolResult) {
	s.mu.Lock()
	defer s.mu.Unlock()
	results = make(map[string]toolResult, len(s.results))
	for k, v := range s.results {
		results[k] = v
	}
	return s.requests, results
}

func (s *standIn) fail(w http.ResponseWriter, code int, kind, msg string) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"type": "error", "error": map[string]any{"type": kind, "message": msg}})
}

func (s *standIn) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	bearer := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if bearer != s.token && r.Header.Get("x-api-key") != s.token {
		s.fail(w, http.StatusUnauthorized, "authentication_error", "invalid credentials")
		return
	}
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/v1/messages":
		s.messages(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/messages/count_tokens":
		w.Header().Set("content-type", "application/json")
		io.WriteString(w, `{"input_tokens":1}`)
	default:
		s.fail(w, http.StatusNotFound, "not_found_error", "the self-test stand-in serves only /v1/messages")
	}
}

type messagesRequest struct {
	Model     string `json:"model"`
	MaxTokens int    `json:"max_tokens"`
	Stream    bool   `json:"stream"`
	Messages  []struct {
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
}

func (s *standIn) messages(w http.ResponseWriter, r *http.Request) {
	var req messagesRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<20)).Decode(&req); err != nil {
		s.fail(w, http.StatusBadRequest, "invalid_request_error", "the request is not JSON")
		return
	}
	known := map[string]bool{}
	for _, c := range s.calls {
		known[c.id] = true
	}
	s.mu.Lock()
	s.requests++
	for _, m := range req.Messages {
		var blocks []struct {
			Type      string `json:"type"`
			ToolUseID string `json:"tool_use_id"`
			IsError   bool   `json:"is_error"`
		}
		if json.Unmarshal(m.Content, &blocks) != nil {
			continue
		}
		for _, b := range blocks {
			if b.Type == "tool_result" && known[b.ToolUseID] {
				s.results[b.ToolUseID] = toolResult{isError: b.IsError}
			}
		}
	}
	turn := len(s.results)
	s.mu.Unlock()

	var block map[string]any
	// A request that asks for at most one token is a side request (a quota probe): it gets text.
	if turn < len(s.calls) && req.MaxTokens > 1 {
		c := s.calls[turn]
		block = map[string]any{"type": "tool_use", "id": c.id, "name": c.name, "input": c.input}
	} else {
		block = map[string]any{"type": "text", "text": "The self-test is complete."}
	}
	writeMessage(w, req, block)
}

// writeMessage answers with one assistant message holding the block, as a stream unless the
// request asked for a plain answer.
func writeMessage(w http.ResponseWriter, req messagesRequest, block map[string]any) {
	model := req.Model
	if model == "" {
		model = selfTestModel
	}
	stop := "end_turn"
	if block["type"] == "tool_use" {
		stop = "tool_use"
	}
	usage := map[string]any{"input_tokens": 1, "output_tokens": 1}
	if !req.Stream {
		w.Header().Set("content-type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"id": "msg_selftest", "type": "message", "role": "assistant", "model": model,
			"content": []any{block}, "stop_reason": stop, "stop_sequence": nil, "usage": usage})
		return
	}
	w.Header().Set("content-type", "text/event-stream")
	w.Header().Set("cache-control", "no-cache")
	flusher, _ := w.(http.Flusher)
	event := func(name string, data map[string]any) {
		b, _ := json.Marshal(data)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", name, b)
		if flusher != nil {
			flusher.Flush()
		}
	}
	event("message_start", map[string]any{"type": "message_start", "message": map[string]any{
		"id": "msg_selftest", "type": "message", "role": "assistant", "model": model, "content": []any{},
		"stop_reason": nil, "stop_sequence": nil, "usage": usage}})
	start := map[string]any{}
	for k, v := range block {
		start[k] = v
	}
	var delta map[string]any
	if block["type"] == "tool_use" {
		input, _ := json.Marshal(block["input"])
		start["input"] = map[string]any{}
		delta = map[string]any{"type": "input_json_delta", "partial_json": string(input)}
	} else {
		start["text"] = ""
		delta = map[string]any{"type": "text_delta", "text": block["text"]}
	}
	event("content_block_start", map[string]any{"type": "content_block_start", "index": 0, "content_block": start})
	event("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0, "delta": delta})
	event("content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
	event("message_delta", map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": stop, "stop_sequence": nil}, "usage": map[string]any{"output_tokens": 1}})
	event("message_stop", map[string]any{"type": "message_stop"})
}

func readString(path string) (string, bool) {
	b, err := os.ReadFile(path)
	return string(b), err == nil
}

// selfTest runs the candidate rt through the scripted session. failing is the failing check, or
// empty when the candidate passes; err means the self-test itself could not run.
func (a *adapter) selfTest(ctx context.Context, rt runtimeRef) (failing string, err error) {
	if len(a.opts.HookCommand) == 0 || a.opts.HookCommand[0] == "" {
		return "", fmt.Errorf("no hook command, so the hook policy of the self-test cannot be installed")
	}
	tmp, err := os.MkdirTemp("", "kogen-claude-selftest-")
	if err != nil {
		return "", fmt.Errorf("cannot create the throwaway checkout: %w", err)
	}
	defer os.RemoveAll(tmp)
	if real, err := filepath.EvalSymlinks(tmp); err == nil {
		tmp = real
	}
	root, home, cfg, dir := filepath.Join(tmp, "checkout"), filepath.Join(tmp, "home"), filepath.Join(tmp, "config"), filepath.Join(tmp, "task")
	for _, d := range []string{root, home, cfg, dir} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return "", fmt.Errorf("cannot create %s: %w", d, err)
		}
	}
	for name, content := range map[string]string{existingFileName: existingOriginal, protectedFileName: protectedOriginal} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o600); err != nil {
			return "", fmt.Errorf("cannot write the throwaway checkout: %w", err)
		}
	}

	protected, _, _, fatal := classifyProtected(root, []string{protectedFileName})
	if fatal != nil {
		return "", fmt.Errorf("protected path %s", fatal.Entry)
	}
	nonce, err := randomHex(16)
	if err != nil {
		return "", err
	}
	sessionID, err := newUUID()
	if err != nil {
		return "", err
	}
	token, err := randomHex(16)
	if err != nil {
		return "", err
	}
	token = "sk-selftest-" + token
	pol := policy{Root: root, Protected: protected, Log: filepath.Join(dir, "hook-log.jsonl"), Nonce: nonce, ProtectedIDs: protectedIDs(root, protected)}
	policyPath, settingsPath := filepath.Join(dir, "hook-policy.json"), filepath.Join(dir, "claude-settings.json")
	if err := writePrivate(policyPath, mustJSON(pol)); err != nil {
		return "", fmt.Errorf("cannot write the hook policy: %w", err)
	}
	if err := writePrivate(pol.Log, nil); err != nil {
		return "", fmt.Errorf("cannot create the hook log: %w", err)
	}
	if err := writePrivate(settingsPath, mustJSON(hookSettings(a.opts.HookCommand, policyPath))); err != nil {
		return "", fmt.Errorf("cannot write the hook settings: %w", err)
	}

	calls := scriptedCalls(root)
	stand := newStandIn(token, calls)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", fmt.Errorf("cannot start the model stand-in: %w", err)
	}
	srv := &http.Server{Handler: stand, ReadHeaderTimeout: 30 * time.Second}
	go srv.Serve(ln)
	defer srv.Close()

	// The candidate's environment is the executor's child environment without the stored
	// token: the throwaway home and configuration directory, the stand-in as the model service
	// and the throwaway token as its credential.
	env := childEnv(a.opts.Env, home, "", cfg)
	env = append(env, "ANTHROPIC_BASE_URL=http://"+ln.Addr().String(), "ANTHROPIC_AUTH_TOKEN="+token,
		"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "NO_PROXY=127.0.0.1,localhost", "no_proxy=127.0.0.1,localhost")
	args := roleRoundArgs(executor.RoleBuild, selfTestSchema, sessionID, 1, selfTestModel, "low", settingsPath)

	sctx, cancel := context.WithTimeout(ctx, selfTestLimit)
	defer cancel()
	_, end, stderr, ctxErr := a.runChildIn(sctx, root, strings.NewReader("Run the self-test: make the file changes the model service asks for.\n"), rt.path, env, "", args...)
	if ctxErr != nil && ctx.Err() != nil {
		return "", classify(ctx)
	}
	timedOut := ctxErr != nil

	requests, results := stand.snapshot()
	if requests == 0 {
		why := end
		if timedOut {
			why = "no answer within " + selfTestLimit.String()
		}
		if stderr != "" {
			why += "; stderr: " + stderr
		}
		if why != "" {
			return checkNoSession + " (" + why + ")", nil
		}
		return checkNoSession, nil
	}
	var log sentinelLog
	records, _ := log.read(pol.Log, nonce)
	return judge(root, calls, results, records, timedOut), nil
}

// judge decides the failing check, or none, from what the self-test observed: the results the
// candidate reported to the stand-in, the hook log and the files.
func judge(root string, calls []scriptedCall, results map[string]toolResult, records map[string]sentinel, timedOut bool) string {
	newFile, newOK := readString(filepath.Join(root, newFileName))
	existing, _ := readString(filepath.Join(root, existingFileName))
	protected, _ := readString(filepath.Join(root, protectedFileName))
	// A guarded call ran when the candidate reported its result or its effect is on disk.
	ran := []bool{
		hasResult(results, calls[0].id) || newOK,
		hasResult(results, calls[1].id) || existing != existingOriginal,
		hasResult(results, calls[2].id) || protected != protectedOriginal,
	}
	for i, c := range calls {
		if rec, ok := records[c.id]; ran[i] && (!ok || rec.Hook != "pretool") {
			return checkNoHookRecord
		}
	}
	if !hasResult(results, calls[0].id) || results[calls[0].id].isError || newFile != newFileContent ||
		!hasResult(results, calls[1].id) || results[calls[1].id].isError || existing != existingEdited {
		return checkWriteMissing
	}
	deny := records[calls[2].id]
	if deny.Decision != "deny" || !hasResult(results, calls[2].id) || !results[calls[2].id].isError || protected != protectedOriginal {
		return checkProtectedPass
	}
	if timedOut {
		return checkNoSession + " (it did not finish within " + selfTestLimit.String() + ")"
	}
	return ""
}

func hasResult(results map[string]toolResult, id string) bool {
	_, ok := results[id]
	return ok
}
