// Package conformance holds the caller-contract conformance suite of kogen-loop: recorded
// fake-provider exchanges (testdata/*.json) with the event sequences the loop must produce,
// driven through the Go library and through the built `kogen-loop` process. A change that
// alters an expected sequence must update the fixture in the same reviewable change.
//
// Nothing here talks to a real provider: a local httptest server plays the Responses API and
// every test runs with a private HOME holding a fake credential.
package conformance

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// ---- the fake Responses API ----

// exchange is one recorded answer of the fake provider.
type exchange struct {
	// Items are the response's output items (messages and function calls) in Responses form.
	Items []map[string]any `json:"items"`
	// Output, when set, is also the terminal envelope's authoritative output list.
	Output []map[string]any `json:"output"`
	// Usage is the response's usage object as the wire carries it; absent or null: none.
	Usage map[string]any `json:"usage"`
	// ID is the response id ("" = none reported).
	ID string `json:"id"`
	// DelayMS delays the answer; Hang never answers until the client leaves.
	DelayMS int  `json:"delay_ms"`
	Hang    bool `json:"hang"`
	// Status other than 0 answers that HTTP status with a refusal body instead.
	Status int `json:"status"`
}

type fakeProvider struct {
	t         *testing.T
	srv       *httptest.Server
	mu        sync.Mutex
	script    []exchange
	next      int
	bodies    []map[string]any
	rawBodies [][]byte
	headers   []http.Header
}

func newFakeProvider(t *testing.T, script []exchange) *fakeProvider {
	t.Helper()
	f := &fakeProvider{t: t, script: script}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeProvider) url() string { return f.srv.URL }

// requests are the decoded request bodies the fake received, in order.
func (f *fakeProvider) requests() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.bodies...)
}

func (f *fakeProvider) serve(w http.ResponseWriter, r *http.Request) {
	data, _ := io.ReadAll(r.Body)
	var body map[string]any
	json.Unmarshal(data, &body)
	f.mu.Lock()
	f.bodies = append(f.bodies, body)
	f.rawBodies = append(f.rawBodies, data)
	f.headers = append(f.headers, r.Header.Clone())
	i := f.next
	f.next++
	f.mu.Unlock()
	if (r.URL.Path != "/v1/responses" && r.URL.Path != "/inference/go/openai/v1/chat/completions") || i >= len(f.script) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(400)
		fmt.Fprint(w, `{"error":{"message":"scripted refusal: no exchange left","code":"invalid_request_error"}}`)
		return
	}
	ex := f.script[i]
	if strings.HasSuffix(r.URL.Path, "/chat/completions") {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"fixture","choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}`)
		return
	}
	if ex.Hang {
		select {
		case <-r.Context().Done():
		case <-time.After(30 * time.Second):
		}
		return
	}
	if ex.DelayMS > 0 {
		time.Sleep(time.Duration(ex.DelayMS) * time.Millisecond)
	}
	if ex.Status != 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(ex.Status)
		fmt.Fprint(w, `{"error":{"message":"scripted refusal","code":"invalid_request_error"}}`)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Request-Id", "req-fixture")
	frame := func(v any) {
		data, _ := json.Marshal(v)
		fmt.Fprintf(w, "data: %s\n\n", data)
	}
	for n, item := range ex.Items {
		frame(map[string]any{"type": "response.output_item.done", "output_index": n, "item": item})
	}
	response := map[string]any{"status": "completed"}
	if ex.ID != "" {
		response["id"] = ex.ID
	}
	if ex.Usage != nil {
		response["usage"] = ex.Usage
	}
	if ex.Output != nil {
		response["output"] = ex.Output
	}
	frame(map[string]any{"type": "response.completed", "response": response})
}

// ---- item builders (the Responses wire shapes the provider accepts) ----

func call(id, name string, args map[string]any) map[string]any {
	data, _ := json.Marshal(args)
	return map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": string(data)}
}

func message(text string) map[string]any {
	return map[string]any{
		"type": "message", "id": "msg-fixture", "role": "assistant",
		"content": []any{map[string]any{"type": "output_text", "text": text, "annotations": []any{}}},
	}
}

func fullUsage(in, cached, out, reasoning int) map[string]any {
	return map[string]any{
		"input_tokens": in, "input_tokens_details": map[string]any{"cached_tokens": cached},
		"output_tokens": out, "output_tokens_details": map[string]any{"reasoning_tokens": reasoning},
	}
}

// ---- the private world: HOME, credentials, root ----

type world struct {
	t    *testing.T
	home string
	tmp  string
	root string
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{t: t, home: t.TempDir(), tmp: t.TempDir(), root: t.TempDir()}
	return w
}

// signIn writes the fake chatgpt credential in the format of Kogen's store.
func (w *world) signIn() *world {
	w.t.Helper()
	dir := filepath.Join(w.home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		w.t.Fatal(err)
	}
	cred, _ := json.Marshal(map[string]any{
		"client_id": "oaiapp_fixture", "access_token": "fake-access-token", "refresh_token": "fake-refresh-token",
		"expires_at": time.Now().Unix() + 3600,
	})
	if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), cred, 0o600); err != nil {
		w.t.Fatal(err)
	}
	return w
}

func (w *world) seed(files map[string]string) *world {
	w.t.Helper()
	for name, content := range files {
		p := filepath.Join(w.root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			w.t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			w.t.Fatal(err)
		}
	}
	return w
}

// env is the process environment of the CLI: private HOME and TMPDIR, the fake provider.
func (w *world) env(f *fakeProvider) []string {
	env := []string{"HOME=" + w.home, "TMPDIR=" + w.tmp, "PATH=" + os.Getenv("PATH")}
	if f != nil {
		env = append(env, "KOGEN_PROVIDER_URL="+f.url())
	}
	return env
}

// task is a complete task for the fake: the chatgpt role, the world's root, and overrides.
func (w *world) task(over map[string]any) map[string]any {
	task := map[string]any{
		"protocol": "kogen-loop/v1", "root": w.root,
		"role":         map[string]any{"provider": "chatgpt", "model": "fixture-model", "effort": "medium", "base_url": ""},
		"instructions": "", "prompt": "do the thing",
		"tools":     []any{"read_file", "write_file", "list_files", "search_text", "shell"},
		"protected": []any{}, "excluded": []any{}, "terminal": []any{"finish"},
		"deadline_seconds": 0, "session": map[string]any{"dir": "", "resume": false}, "requires": []any{},
	}
	for k, v := range over {
		task[k] = v
	}
	return task
}

// ---- the built CLI ----

var (
	buildOnce sync.Once
	binPath   string
	buildErr  error
	buildDir  string
)

func TestMain(m *testing.M) {
	code := m.Run()
	if buildDir != "" {
		os.RemoveAll(buildDir)
	}
	os.Exit(code)
}

// cliBinary builds cmd/kogen-loop once per test run.
func cliBinary(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		buildDir, buildErr = os.MkdirTemp("", "kogen-loop-bin-")
		if buildErr != nil {
			return
		}
		binPath = filepath.Join(buildDir, "kogen-loop")
		cmd := exec.Command("go", "build", "-o", binPath, "kogen-loop/cmd/kogen-loop")
		if out, err := cmd.CombinedOutput(); err != nil {
			buildErr = fmt.Errorf("go build: %v\n%s", err, out)
		}
	})
	if buildErr != nil {
		t.Fatal(buildErr)
	}
	return binPath
}

// proc is a running kogen-loop process.
type proc struct {
	t       *testing.T
	cmd     *exec.Cmd
	stdout  *lineBuffer
	stderr  bytes.Buffer
	done    chan struct{}
	waitErr error
}

// lineBuffer collects stdout and lets a test wait for a line that matches.
type lineBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lineBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lineBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func startCLI(t *testing.T, w *world, f *fakeProvider, stdin []byte, args ...string) *proc {
	t.Helper()
	p := &proc{t: t, stdout: &lineBuffer{}, done: make(chan struct{})}
	p.cmd = exec.Command(cliBinary(t), args...)
	p.cmd.Env = w.env(f)
	p.cmd.Dir = w.root
	p.cmd.Stdin = bytes.NewReader(stdin)
	p.cmd.Stdout = p.stdout
	p.cmd.Stderr = &p.stderr
	if err := p.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { p.waitErr = p.cmd.Wait(); close(p.done) }()
	t.Cleanup(func() {
		select {
		case <-p.done:
		default:
			p.cmd.Process.Kill()
			<-p.done
		}
	})
	return p
}

// wait returns the exit code once the process ends (the test fails after 60 s).
func (p *proc) wait() int {
	p.t.Helper()
	select {
	case <-p.done:
	case <-time.After(60 * time.Second):
		p.t.Fatalf("kogen-loop did not exit; stdout:\n%s\nstderr:\n%s", p.stdout.String(), p.stderr.String())
	}
	return p.cmd.ProcessState.ExitCode()
}

// result is a finished CLI run.
type result struct {
	exit   int
	events []map[string]any
	lines  []string
	stderr string
}

func (p *proc) result() result {
	p.t.Helper()
	exit := p.wait()
	r := result{exit: exit, stderr: p.stderr.String()}
	sc := bufio.NewScanner(strings.NewReader(p.stdout.String()))
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	for sc.Scan() {
		line := sc.Text()
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			p.t.Fatalf("stdout carries a line that is not a JSON event: %q (%v)", line, err)
		}
		r.lines = append(r.lines, line)
		r.events = append(r.events, ev)
	}
	checkInvariants(p.t, r)
	return r
}

func runCLI(t *testing.T, w *world, f *fakeProvider, task map[string]any) result {
	t.Helper()
	data, err := json.Marshal(task)
	if err != nil {
		t.Fatal(err)
	}
	return runCLIRaw(t, w, f, data)
}

func runCLIRaw(t *testing.T, w *world, f *fakeProvider, task []byte) result {
	t.Helper()
	return startCLI(t, w, f, task, "run", "--task", "-").result()
}

// checkInvariants are the guarantees of every `run`: stdout is JSON Lines events only, the
// envelope is complete, seq is gapless from 1, time is RFC 3339 UTC and session.ended is last.
func checkInvariants(t *testing.T, r result) {
	t.Helper()
	if len(r.events) == 0 {
		t.Fatalf("no events (stderr: %s)", r.stderr)
	}
	for i, ev := range r.events {
		if ev["protocol"] != "kogen-loop/v1" {
			t.Errorf("event %d: protocol %v", i+1, ev["protocol"])
		}
		if seq, _ := ev["seq"].(float64); int(seq) != i+1 {
			t.Errorf("event %d: seq %v is not gapless", i+1, ev["seq"])
		}
		ts, _ := ev["time"].(string)
		if parsed, err := time.Parse(time.RFC3339, ts); err != nil || !strings.HasSuffix(ts, "Z") || parsed.Location() != time.UTC {
			t.Errorf("event %d: time %q is not RFC 3339 UTC", i+1, ts)
		}
		if typ, _ := ev["type"].(string); typ == "" {
			t.Errorf("event %d: no type", i+1)
		}
	}
	last := r.events[len(r.events)-1]
	if last["type"] != "session.ended" {
		t.Errorf("session.ended is not the last event: %v", last["type"])
	}
	if int(last["exit"].(float64)) != r.exit {
		t.Errorf("session.ended exit %v differs from the process exit %d", last["exit"], r.exit)
	}
	ended := 0
	for _, ev := range r.events {
		if ev["type"] == "session.ended" {
			ended++
		}
	}
	if ended != 1 {
		t.Errorf("session.ended appears %d times", ended)
	}
	for _, ev := range r.events {
		if rec, ok := ev["record"]; ok {
			if strings.Contains(fmt.Sprint(rec), "fake-access-token") || strings.Contains(fmt.Sprint(rec), "fake-refresh-token") {
				t.Errorf("an attempt record carries a credential: %v", rec)
			}
		}
	}
}

func (r result) types() []string {
	var out []string
	for _, ev := range r.events {
		out = append(out, ev["type"].(string))
	}
	return out
}

func (r result) first(typ string) map[string]any {
	for _, ev := range r.events {
		if ev["type"] == typ {
			return ev
		}
	}
	return nil
}

func (r result) all(typ string) []map[string]any {
	var out []map[string]any
	for _, ev := range r.events {
		if ev["type"] == typ {
			out = append(out, ev)
		}
	}
	return out
}

// ---- expected sequences ----

// match reports whether got satisfies want: every key of want is in got with an equal value;
// "*" matches any value other than null; nested objects and arrays match the same way (arrays
// by length and element).
func match(want, got any) bool {
	switch w := want.(type) {
	case string:
		if w == "*" {
			return got != nil
		}
		return got == want
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return false
		}
		for k, v := range w {
			if !match(v, g[k]) {
				return false
			}
		}
		return true
	case []any:
		g, ok := got.([]any)
		if !ok || len(g) != len(w) {
			return false
		}
		for i := range w {
			if !match(w[i], g[i]) {
				return false
			}
		}
		return true
	}
	return reflect.DeepEqual(want, got)
}

func expectEvents(t *testing.T, r result, want []map[string]any) {
	t.Helper()
	if len(r.events) != len(want) {
		t.Errorf("got %d events %v, want %d", len(r.events), r.types(), len(want))
	}
	for i := range want {
		if i >= len(r.events) {
			break
		}
		if !match(want[i], r.events[i]) {
			got, _ := json.Marshal(r.events[i])
			exp, _ := json.Marshal(want[i])
			t.Errorf("event %d:\n got  %s\n want %s", i+1, got, exp)
		}
	}
}

// fixture is one recorded case of testdata/.
type fixture struct {
	Description string            `json:"description"`
	Files       map[string]string `json:"files"`
	Task        map[string]any    `json:"task"`
	Exchanges   []exchange        `json:"exchanges"`
	Expect      struct {
		Exit     int              `json:"exit"`
		Requests int              `json:"requests"`
		Events   []map[string]any `json:"events"`
	} `json:"expect"`
}

func loadFixture(t *testing.T, name string) fixture {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx fixture
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&fx); err != nil {
		t.Fatalf("fixture %s: %v", name, err)
	}
	return fx
}

// pidGone waits until the process no longer exists.
func pidGone(pid int) bool {
	for i := 0; i < 100; i++ {
		if err := syscall.Kill(pid, 0); err == syscall.ESRCH {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}
