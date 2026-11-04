package consumes

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/KogenAI/kogen-setup/setup"
	"github.com/KogenAI/kogen-verification/verify"
	"kogen-loop/provider"
	"kogen-loop/sys"
)

// reply writes one scripted streamed response of the loopback provider.
type reply func(w http.ResponseWriter, r *http.Request)

// initFx is a temporary repository with its own identity, no signing and an empty hooks folder,
// a HOME of its own (signed in to ChatGPT when asked), fake npm and node programs, an empty
// Cucumber folder and a loopback provider on a free port that plays a script. Nothing reaches
// the network.
type initFx struct {
	t      *testing.T
	base   string
	home   string
	bin    string
	repo   string
	hooks  string
	srv    *httptest.Server
	mu     sync.Mutex
	script []reply
	n      int
	env    []string
	tools  verify.Tools
}

func newInitFx(t *testing.T, signedIn bool, script ...reply) *initFx {
	t.Helper()
	t.Parallel()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &initFx{t: t, base: base, home: filepath.Join(base, "home"), bin: filepath.Join(base, "bin"),
		repo: filepath.Join(base, "repo"), hooks: filepath.Join(base, "hooks"), script: script}
	for _, d := range []string{f.home, f.bin, f.repo, f.hooks, filepath.Join(base, "cucumber")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f.program("npm", "exit 0")
	f.program("node", `[ -n "$KOGEN_ACCEPTANCE_REPORT" ] && echo '{}' > "$KOGEN_ACCEPTANCE_REPORT"
exit 0`)
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	f.env = envWith(os.Environ(), "HOME="+f.home, "PATH="+f.bin+string(os.PathListSeparator)+os.Getenv("PATH"),
		"KOGEN_PROVIDER_URL="+f.srv.URL)
	f.tools = verify.Tools{Node: filepath.Join(f.bin, "node"), Cucumber: filepath.Join(base, "cucumber")}
	if signedIn {
		dir := filepath.Join(f.home, ".kogen", "credentials")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		creds := fmt.Sprintf(`{"client_id":"oaiapp_fixture","access_token":"fake-access","refresh_token":"fake-refresh","expires_at":%d}`, time.Now().Unix()+3600)
		if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), []byte(creds), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	f.git("init", "-q")
	f.git("config", "user.name", "Fixture")
	f.git("config", "user.email", "fixture@example.invalid")
	f.git("config", "core.hooksPath", f.hooks)
	f.git("config", "commit.gpgsign", "false")
	return f
}

// envWith is env with each KEY=value of set replacing the variable of the same name.
func envWith(env []string, set ...string) []string {
	out := slices.Clone(env)
	for _, kv := range set {
		k, _, _ := strings.Cut(kv, "=")
		out = slices.DeleteFunc(out, func(e string) bool { return strings.HasPrefix(e, k+"=") })
		out = append(out, kv)
	}
	return out
}

func (f *initFx) program(name, body string) {
	f.t.Helper()
	if err := os.WriteFile(filepath.Join(f.bin, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		f.t.Fatal(err)
	}
}

func (f *initFx) hook(name, body string) {
	f.t.Helper()
	if err := os.WriteFile(filepath.Join(f.hooks, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		f.t.Fatal(err)
	}
}

// serve plays the next scripted reply; a request beyond the script is refused.
func (f *initFx) serve(w http.ResponseWriter, r *http.Request) {
	io.Copy(io.Discard, r.Body)
	f.mu.Lock()
	f.n++
	var rep reply
	if f.n <= len(f.script) {
		rep = f.script[f.n-1]
	}
	f.mu.Unlock()
	if rep == nil {
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"message":"no scripted reply","code":"invalid_request_error"}}`)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	rep(w, r)
}

// requests is the number of requests the loopback provider received.
func (f *initFx) requests() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.n
}

// git runs a command in the fixture directly and fails the test unless it succeeds.
func (f *initFx) git(args ...string) string {
	f.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = f.repo
	cmd.Env = f.env
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		f.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, stderr.String())
	}
	return string(out)
}

func (f *initFx) write(rel, content string) {
	f.t.Helper()
	path := filepath.Join(f.repo, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *initFx) read(rel string) string {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.repo, rel))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *initFx) exists(rel string) bool {
	_, err := os.Lstat(filepath.Join(f.repo, rel))
	return err == nil
}

func (f *initFx) commitAll(message string) {
	f.t.Helper()
	f.git("add", "-A")
	f.git("commit", "-qm", message)
}

// head is HEAD's commit, or "" before the first commit.
func (f *initFx) head() string {
	cmd := exec.Command("git", "rev-parse", "-q", "--verify", "HEAD")
	cmd.Dir, cmd.Env = f.repo, f.env
	out, _ := cmd.Output()
	return strings.TrimSpace(string(out))
}

func (f *initFx) status() string { return f.git("status", "--porcelain", "--untracked-files=all") }

// session is a session in dir (the repository when ""), as kogen's runEngine makes one: its
// output goes to the returned builders.
func (f *initFx) session(dir string) (*sys.Session, *strings.Builder) {
	if dir == "" {
		dir = f.repo
	}
	s := sys.NewWith(f.env, dir)
	out := &strings.Builder{}
	s.Stdout, s.Stderr = out, io.Discard
	return s, out
}

// runSession calls setup.Init as kogen's runEngine does: with the session's context, the
// client and the tools.
func (f *initFx) runSession(s *sys.Session) (int, error) {
	return setup.Init(s.Context(), s, setup.InitInput{Client: provider.NewClient("dev+12345678"), Tools: f.tools})
}

// run calls setup.Init in dir (the repository when "") and returns its exit code, its standard
// output and its error.
func (f *initFx) run(dir string) (int, string, error) {
	f.t.Helper()
	s, out := f.session(dir)
	exit, err := f.runSession(s)
	return exit, out.String(), err
}

func (f *initFx) mustRun() string {
	f.t.Helper()
	exit, out, err := f.run("")
	if err != nil || exit != 0 {
		f.t.Fatalf("exit %d, err %v\nstdout %s", exit, err, out)
	}
	return out
}

func frame(v any) string {
	b, _ := json.Marshal(v)
	return "data: " + string(b) + "\n\n"
}

func usage() map[string]any {
	return map[string]any{"usage": map[string]any{
		"input_tokens": 100, "input_tokens_details": map[string]any{"cached_tokens": 0},
		"output_tokens": 20, "output_tokens_details": map[string]any{"reasoning_tokens": 5}}}
}

// nothing answers with a submit_configuration call that proposes no command.
func nothing() reply {
	args, _ := json.Marshal(map[string]any{"setup": []any{}, "fix": []any{}, "checks": []any{}, "protect": []any{}})
	call := map[string]any{"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "submit_configuration", "arguments": string(args), "status": "completed"}
	return func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, frame(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": call}))
		io.WriteString(w, frame(map[string]any{"type": "response.completed", "response": usage()}))
	}
}

// text answers with a message and no call.
func text(s string) reply {
	msg := map[string]any{"type": "message", "id": "msg_1", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": s, "annotations": []any{}}}}
	return func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, frame(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": msg}))
		io.WriteString(w, frame(map[string]any{"type": "response.completed", "response": usage()}))
	}
}
