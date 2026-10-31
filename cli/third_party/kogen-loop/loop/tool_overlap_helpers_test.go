package loop

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// Fixtures of the TestToolOverlap* tests. Tool timing is controlled by channel gates in a
// fake Git (Tools.Repo) and by FIFOs for real shells; the provider is a local httptest
// server that streams the wire's real event shapes and holds the response at points the
// test controls. The watchdog bounds only failing runs; nothing is synchronized by sleeping.

const olWatchdog = 30 * time.Second

// olRepo is a tools.Git whose search_text and list_files calls announce their start and
// finish when their gate is opened. A key is the search pattern or "ls:<path>"; the
// view_image candidate tree is "tree".
type olRepo struct {
	mu      sync.Mutex
	gates   map[string]chan struct{}
	auto    bool     // every gate is open
	log     []string // "start k" and "end k" in order
	snaps   map[string]string
	started chan string
	ended   chan string
	snap    func(key string) string // optional: state observed on entry
}

func newOLRepo(t *testing.T) *olRepo {
	r := &olRepo{gates: map[string]chan struct{}{}, snaps: map[string]string{}, started: make(chan string, 64), ended: make(chan string, 64)}
	t.Cleanup(r.openAll)
	return r
}

func (r *olRepo) gate(key string) chan struct{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	g, ok := r.gates[key]
	if !ok {
		g = make(chan struct{})
		if r.auto {
			close(g)
		}
		r.gates[key] = g
	}
	return g
}

// release lets every call with the key (now or later) finish.
func (r *olRepo) release(keys ...string) {
	for _, k := range keys {
		g := r.gate(k)
		r.mu.Lock()
		select {
		case <-g:
		default:
			close(g)
		}
		r.mu.Unlock()
	}
}

// openAll opens every gate, now and later.
func (r *olRepo) openAll() {
	r.mu.Lock()
	r.auto = true
	for _, g := range r.gates {
		select {
		case <-g:
		default:
			close(g)
		}
	}
	r.mu.Unlock()
}

func olKey(args []string) string {
	for i, a := range args {
		if a == "-e" && i+1 < len(args) {
			return args[i+1]
		}
	}
	if len(args) > 0 && args[0] == "ls-files" {
		if i := slices.Index(args, "--"); i >= 0 && i+1 < len(args) {
			return "ls:" + args[i+1]
		}
		return "ls:."
	}
	return strings.Join(args, " ")
}

func (r *olRepo) enter(key string) {
	r.mu.Lock()
	r.log = append(r.log, "start "+key)
	if r.snap != nil {
		r.snaps[key] = r.snap(key)
	}
	r.mu.Unlock()
	r.started <- key
	<-r.gate(key)
	r.mu.Lock()
	r.log = append(r.log, "end "+key)
	r.mu.Unlock()
	r.ended <- key
}

func (r *olRepo) Run(args ...string) (tools.GitResult, error) {
	key := olKey(args)
	r.enter(key)
	return tools.GitResult{Stdout: key + "\n"}, nil
}

func (r *olRepo) Head() string { return "" }

func (r *olRepo) Tree(string, []string) (string, error) {
	r.enter("tree")
	return "tree", nil
}

func (r *olRepo) events() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.log)
}

func (r *olRepo) snapshot(key string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.snaps[key]
}

// entered are the keys that have started, in order.
func (r *olRepo) entered() []string {
	var keys []string
	for _, e := range r.events() {
		if k, ok := strings.CutPrefix(e, "start "); ok {
			keys = append(keys, k)
		}
	}
	return keys
}

func (r *olRepo) finished(key string) bool { return slices.Contains(r.events(), "end "+key) }

// next waits for the next call to start and returns its key.
func (r *olRepo) next(t *testing.T) string {
	t.Helper()
	select {
	case k := <-r.started:
		return k
	case <-time.After(olWatchdog):
		t.Fatalf("no call started; log %v", r.events())
		return ""
	}
}

// nextEnd waits for the next call to finish and returns its key.
func (r *olRepo) nextEnd(t *testing.T) string {
	t.Helper()
	select {
	case k := <-r.ended:
		return k
	case <-time.After(olWatchdog):
		t.Fatalf("no call finished; log %v", r.events())
		return ""
	}
}

// startedKeys waits until exactly the given keys (in any order) have each started.
func (r *olRepo) startedKeys(t *testing.T, want ...string) {
	t.Helper()
	var got []string
	for range want {
		got = append(got, r.next(t))
	}
	slices.Sort(got)
	w := slices.Clone(want)
	slices.Sort(w)
	if !slices.Equal(got, w) {
		t.Fatalf("started %v, want %v", got, w)
	}
}

// idle fails the test when a call has started that the test did not wait for.
func (r *olRepo) idle(t *testing.T, why string) {
	t.Helper()
	select {
	case k := <-r.started:
		t.Fatalf("%s: %q started", why, k)
	default:
	}
}

// ---- the provider ----

// olProvider is a local provider of one wire, serving one script function per request.
type olProvider struct {
	t      *testing.T
	wire   string
	srv    *httptest.Server
	mu     sync.Mutex
	script []func(*olStream)
	bodies []map[string]any
}

func newOLProvider(t *testing.T, wire string, script ...func(*olStream)) *olProvider {
	p := &olProvider{t: t, wire: wire, script: script}
	p.srv = httptest.NewServer(http.HandlerFunc(p.serve))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *olProvider) serve(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	json.Unmarshal(raw, &body)
	p.mu.Lock()
	n := len(p.bodies)
	p.bodies = append(p.bodies, body)
	p.mu.Unlock()
	if n >= len(p.script) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"message":"script exhausted","code":"invalid_request_error"}}`)
		return
	}
	s := &olStream{w: w, r: r, wire: p.wire, open: map[int]bool{}}
	s.fl, _ = w.(http.Flusher)
	p.script[n](s)
}

func (p *olProvider) requests() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.bodies)
}

// olStream writes one response in the events of its wire.
type olStream struct {
	w       http.ResponseWriter
	fl      http.Flusher
	r       *http.Request
	wire    string
	begun   bool
	open    map[int]bool // positions whose item has started
	ended   bool
	toolUse bool
}

func (s *olStream) begin() {
	if s.begun {
		return
	}
	s.begun = true
	s.w.Header().Set("Content-Type", "text/event-stream")
	s.w.Header().Set("X-Request-Id", "req-fixture")
	if s.wire == "messages" {
		s.event("message_start", map[string]any{"message": map[string]any{"id": "msg", "model": "claude-opus-5-5",
			"usage": map[string]any{"input_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})
	}
}

func (s *olStream) flush() {
	if s.fl != nil {
		s.fl.Flush()
	}
}

func (s *olStream) event(typ string, kv map[string]any) {
	kv["type"] = typ
	b, _ := json.Marshal(kv)
	if s.wire == "messages" {
		fmt.Fprintf(s.w, "event: %s\ndata: %s\n\n", typ, b)
	} else {
		fmt.Fprintf(s.w, "data: %s\n\n", b)
	}
	s.flush()
}

// frag starts the call at pos and streams its argument fragments; the call is not complete.
func (s *olStream) frag(pos int, id, name string, parts ...string) {
	s.begin()
	if !s.open[pos] {
		s.open[pos] = true
		if s.wire == "messages" {
			s.event("content_block_start", map[string]any{"index": pos, "content_block": map[string]any{"type": "tool_use", "id": id, "name": name, "input": map[string]any{}}})
		} else {
			s.event("response.output_item.added", map[string]any{"output_index": pos, "item": map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": ""}})
		}
	}
	for _, part := range parts {
		if s.wire == "messages" {
			s.event("content_block_delta", map[string]any{"index": pos, "delta": map[string]any{"type": "input_json_delta", "partial_json": part}})
		} else {
			s.event("response.function_call_arguments.delta", map[string]any{"output_index": pos, "item_id": id, "delta": part})
		}
	}
}

// done completes the call at pos. A Messages call is the fragments already streamed, or args.
func (s *olStream) done(pos int, id, name, args string) {
	if s.wire == "messages" {
		if !s.open[pos] {
			s.frag(pos, id, name, args)
		}
		s.toolUse = true
		s.event("content_block_stop", map[string]any{"index": pos})
		return
	}
	s.frag(pos, id, name)
	s.event("response.output_item.done", map[string]any{"output_index": pos, "item": map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": args}})
}

func (s *olStream) call(pos int, id, name, args string) {
	if s.wire == "messages" {
		s.frag(pos, id, name, args)
	} else {
		s.frag(pos, id, name)
	}
	s.done(pos, id, name, args)
}

// text completes an assistant message at pos.
func (s *olStream) text(pos int, text string) {
	s.begin()
	if s.wire == "messages" {
		s.event("content_block_start", map[string]any{"index": pos, "content_block": map[string]any{"type": "text", "text": ""}})
		s.event("content_block_delta", map[string]any{"index": pos, "delta": map[string]any{"type": "text_delta", "text": text}})
		s.event("content_block_stop", map[string]any{"index": pos})
		return
	}
	s.event("response.output_item.done", map[string]any{"output_index": pos, "item": map[string]any{"type": "message", "role": "assistant",
		"content": []any{map[string]any{"type": "output_text", "text": text}}}})
}

// reasoning completes a reasoning item at pos (Responses only).
func (s *olStream) reasoning(pos int) {
	s.begin()
	s.event("response.output_item.done", map[string]any{"output_index": pos, "item": map[string]any{"type": "reasoning", "id": "rs" + strconv.Itoa(pos), "summary": []any{}}})
}

// end completes the response. output, when set, is the terminal envelope's output list.
func (s *olStream) end(output ...map[string]any) {
	s.begin()
	s.ended = true
	if s.wire == "messages" {
		stop := "end_turn"
		if s.toolUse {
			stop = "tool_use"
		}
		s.event("message_delta", map[string]any{"delta": map[string]any{"stop_reason": stop}, "usage": map[string]any{"output_tokens": 1}})
		s.event("message_stop", map[string]any{})
		return
	}
	resp := map[string]any{"status": "completed"}
	if output != nil {
		resp["output"] = output
	}
	s.event("response.completed", map[string]any{"response": resp})
}

// cut ends the transfer without completing the response: the client sees a cut stream.
func (s *olStream) cut() {
	s.begin()
	s.flush()
	if hj, ok := s.w.(http.Hijacker); ok {
		if conn, _, err := hj.Hijack(); err == nil {
			conn.Close()
		}
	}
}

// wait blocks until ch is closed or the client leaves.
func (s *olStream) wait(ch <-chan struct{}) {
	select {
	case <-ch:
	case <-s.r.Context().Done():
	}
}

// chat answers a Chat Completions request with one JSON body; split is called between its
// two halves and may block.
func (s *olStream) chat(calls [][3]string, split func()) {
	var tc []any
	for _, c := range calls {
		tc = append(tc, map[string]any{"id": c[0], "type": "function", "function": map[string]any{"name": c[1], "arguments": c[2]}})
	}
	body, _ := json.Marshal(map[string]any{"id": "chat", "choices": []any{map[string]any{
		"message":       map[string]any{"role": "assistant", "content": nil, "tool_calls": tc},
		"finish_reason": "tool_calls"}}})
	half := len(body) / 2
	s.w.Header().Set("Content-Type", "application/json")
	s.w.Write(body[:half])
	s.flush()
	if split != nil {
		split()
	}
	s.w.Write(body[half:])
	s.flush()
}

// ---- engine setup ----

// olWire is a provider fixture reachable through Direct.
func olDirect(t *testing.T, p *olProvider) (*Direct, provider.Role, *sys.Session) {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	env := []string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}
	var role provider.Role
	switch p.wire {
	case "responses":
		cred, _ := json.Marshal(map[string]any{"client_id": "oaiapp_fixture", "access_token": "fake-access-token", "refresh_token": "fake-refresh-token", "expires_at": time.Now().Unix() + 3600})
		if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), cred, 0o600); err != nil {
			t.Fatal(err)
		}
		env = append(env, "KOGEN_PROVIDER_URL="+p.srv.URL)
		role = provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"}
	case "messages":
		if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), []byte(`{"provider":"anthropic","api_key":"SYNTHETIC_API_KEY_0001"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		env = append(env, "KOGEN_PROVIDER_URL="+p.srv.URL)
		role = parallelRole
	default:
		role = provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: p.srv.URL}
	}
	sess := sys.NewWith(env, t.TempDir())
	client := provider.NewClient("")
	client.Sleep = func(ctx context.Context, d time.Duration) error { return ctx.Err() }
	return &Direct{Client: client, Session: sess}, role, sess
}

func olDefs() []any {
	var defs []any
	for _, name := range []string{"read_file", "write_file", "list_files", "search_text", "view_image", "shell", "finish"} {
		defs = append(defs, map[string]any{"type": "function", "name": name, "description": "d", "parameters": map[string]any{"type": "object"}})
	}
	return defs
}

// olTools are real tools over root with the fake Git.
func olTools(root string, repo tools.Git, sess *sys.Session) *tools.Tools {
	return &tools.Tools{Root: root, Repo: repo, Session: sess,
		Enabled: []string{tools.ReadFileTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.ViewImageTool, tools.ShellTool}}
}

func olSearch(id, pattern string) map[string]any {
	b, _ := json.Marshal(map[string]any{"pattern": pattern})
	return fcall(id, "search_text", string(b))
}

func olList(id, path string) map[string]any {
	b, _ := json.Marshal(map[string]any{"path": path})
	return fcall(id, "list_files", string(b))
}

func olWrite(id, path, content string) map[string]any {
	b, _ := json.Marshal(map[string]any{"path": path, "content": content})
	return fcall(id, "write_file", string(b))
}

func olShell(id, command string) map[string]any {
	b, _ := json.Marshal(map[string]any{"command": command})
	return fcall(id, "shell", string(b))
}

// olRun is a round running in the background.
type olRun struct {
	done chan struct{}
	res  Result
	err  error
}

func olStart(ctx context.Context, rd Round, input []any, rq Requester, h Hooks) *olRun {
	r := &olRun{done: make(chan struct{})}
	go func() {
		defer close(r.done)
		r.res, r.err = Run(ctx, rd, input, rq, h)
	}()
	return r
}

func (r *olRun) wait(t *testing.T) (Result, error) {
	t.Helper()
	select {
	case <-r.done:
		return r.res, r.err
	case <-time.After(olWatchdog):
		t.Fatal("the round did not return")
		return Result{}, nil
	}
}

// returned reports whether the round has returned, without waiting.
func (r *olRun) returned() bool {
	select {
	case <-r.done:
		return true
	default:
		return false
	}
}

// olOutputIDs are the call ids of the tool outputs a request body carries, in order.
func olOutputIDs(wire string, body map[string]any) []string {
	var ids []string
	list := func(v any) []any { l, _ := v.([]any); return l }
	switch wire {
	case "responses":
		for _, it := range list(body["input"]) {
			if m, _ := it.(map[string]any); m["type"] == "function_call_output" {
				ids = append(ids, fmt.Sprint(m["call_id"]))
			}
		}
	case "messages":
		for _, msg := range list(body["messages"]) {
			m, _ := msg.(map[string]any)
			for _, b := range list(m["content"]) {
				if bm, _ := b.(map[string]any); bm["type"] == "tool_result" {
					ids = append(ids, fmt.Sprint(bm["tool_use_id"]))
				}
			}
		}
	default:
		for _, msg := range list(body["messages"]) {
			if m, _ := msg.(map[string]any); m["role"] == "tool" {
				ids = append(ids, fmt.Sprint(m["tool_call_id"]))
			}
		}
	}
	return ids
}

// olFinish is the closing response of a scripted provider: one finish call.
func olFinish(s *olStream) {
	switch s.wire {
	case "chat":
		s.chat([][3]string{{"fin", "finish", "{}"}}, nil)
	default:
		s.call(0, "fin", "finish", "{}")
		s.end()
	}
}

// ---- processes ----

// procLive is true while pid exists and is not a zombie.
func procLive(t *testing.T, pid int) bool {
	t.Helper()
	out, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return false
		}
		t.Fatalf("cannot observe process %d: %v", pid, err)
	}
	stat := strings.TrimSpace(string(out))
	return stat != "" && !strings.HasPrefix(stat, "Z")
}

// groupLive is true while a non-zombie process is a member of the process group pgid.
func groupLive(t *testing.T, pgid int) bool {
	t.Helper()
	out, err := exec.Command("ps", "-A", "-o", "pid=,pgid=,stat=").Output()
	if err != nil {
		t.Fatalf("cannot enumerate processes: %v", err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		if g, err := strconv.Atoi(f[1]); err == nil && g == pgid && !strings.HasPrefix(f[2], "Z") {
			return true
		}
	}
	return false
}

func olQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// olFifo makes a FIFO in dir.
func olFifo(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := exec.Command("mkfifo", p).Run(); err != nil {
		t.Fatalf("mkfifo: %v", err)
	}
	return p
}

// olHold is a shell command that reports its pid through the ready FIFO (blocking until the
// test reads it, which is the observable start of the command) and then blocks until the
// test writes to the gate FIFO.
func olHold(ready, gate, after string) string {
	return fmt.Sprintf(`echo $$ > %s; read x < %s; %s`, olQuote(ready), olQuote(gate), after)
}

// olReadPid reads the pid a command wrote to a FIFO.
func olReadPid(t *testing.T, path string) int {
	t.Helper()
	type res struct {
		data []byte
		err  error
	}
	c := make(chan res, 1)
	go func() { d, err := os.ReadFile(path); c <- res{d, err} }()
	select {
	case r := <-c:
		pid, err := strconv.Atoi(strings.TrimSpace(string(r.data)))
		if r.err != nil || err != nil {
			t.Fatalf("pid from %s: %q %v %v", path, r.data, r.err, err)
		}
		return pid
	case <-time.After(olWatchdog):
		t.Fatalf("nothing wrote a pid to %s", path)
		return 0
	}
}

// olOpen opens the gate FIFO for the command to continue; it never blocks the test.
func olOpen(path string) {
	go func() {
		if f, err := os.OpenFile(path, os.O_WRONLY, 0); err == nil {
			f.WriteString("go\n")
			f.Close()
		}
	}()
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
