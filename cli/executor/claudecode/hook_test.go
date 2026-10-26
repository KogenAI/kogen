package claudecode

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type hookEnv struct {
	t      *testing.T
	root   string // real path
	policy string
	log    string
}

func newHookEnv(t *testing.T, protected ...string) *hookEnv {
	t.Helper()
	tmp := t.TempDir()
	if r, err := filepath.EvalSymlinks(tmp); err == nil {
		tmp = r
	}
	root := filepath.Join(tmp, "repo")
	for _, d := range []string{"protected", "src", ".git", "sub/.git"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"protected/contract.txt", "src/a.go", ".git/config", "sub/.git/config", "top.txt"} {
		if err := os.WriteFile(filepath.Join(root, f), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(tmp, "outside"), 0o755); err != nil {
		t.Fatal(err)
	}
	if len(protected) == 0 {
		protected = []string{"protected/contract.txt"}
	}
	h := &hookEnv{t: t, root: root, policy: filepath.Join(tmp, "policy.json"), log: filepath.Join(tmp, "hook-log.jsonl")}
	b, _ := json.Marshal(policy{Root: root, Protected: protected, Log: h.log, Nonce: "n1"})
	if err := os.WriteFile(h.policy, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return h
}

func (h *hookEnv) run(mode string, input map[string]any) (code int, stdout, stderr string) {
	h.t.Helper()
	b, _ := json.Marshal(input)
	var so, se bytes.Buffer
	code = RunHook([]string{mode, "--policy", h.policy}, bytes.NewReader(b), &so, &se)
	return code, so.String(), se.String()
}

func (h *hookEnv) pre(tool, key, path, id string) (code int, stdout string) {
	code, so, _ := h.run("pretool", map[string]any{
		"cwd": h.root, "tool_name": tool, "tool_use_id": id, "tool_input": map[string]any{key: path, "content": "c"},
	})
	return code, so
}

func (h *hookEnv) sentinels() []sentinel {
	h.t.Helper()
	b, _ := os.ReadFile(h.log)
	var out []sentinel
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if l == "" {
			continue
		}
		var s sentinel
		if err := json.Unmarshal([]byte(l), &s); err != nil {
			h.t.Fatalf("bad sentinel %q", l)
		}
		out = append(out, s)
	}
	return out
}

func (h *hookEnv) symlink(target, name string) {
	h.t.Helper()
	if err := os.Symlink(target, filepath.Join(h.root, name)); err != nil {
		h.t.Fatal(err)
	}
}

func TestPreToolDecisions(t *testing.T) {
	t.Parallel()
	h := newHookEnv(t, "protected/contract.txt", "protected/future.txt")
	h.symlink("protected/contract.txt", "link-to-protected")
	h.symlink("protected", "link-to-dir")
	h.symlink(".git", "link-to-git")
	h.symlink(filepath.Join(filepath.Dir(h.root), "outside"), "link-outside")
	h.symlink("protected/future.txt", "dangling")
	h.symlink("src", "link-to-src")
	abs := func(p string) string { return filepath.Join(h.root, p) }
	cases := []struct {
		name  string
		tool  string
		key   string
		path  string
		allow bool
		why   string
	}{
		{"plain new file", "Write", "file_path", abs("src/new/deep/file.go"), true, ""},
		{"existing file", "Edit", "file_path", abs("src/a.go"), true, ""},
		{"multiedit", "MultiEdit", "file_path", abs("top.txt"), true, ""},
		{"notebook", "NotebookEdit", "notebook_path", abs("src/nb.ipynb"), true, ""},
		{"relative to cwd", "Write", "file_path", "src/rel.go", true, ""},
		{"through safe symlink", "Write", "file_path", abs("link-to-src/x.go"), true, ""},
		{"protected", "Write", "file_path", abs("protected/contract.txt"), false, "protected"},
		{"protected multiedit", "MultiEdit", "file_path", abs("protected/contract.txt"), false, "protected"},
		{"protected relative", "Edit", "file_path", "protected/contract.txt", false, "protected"},
		{"protected dotdot", "Write", "file_path", abs("src/../protected/contract.txt"), false, "protected"},
		{"protected via symlink", "Write", "file_path", abs("link-to-protected"), false, "protected"},
		{"protected via dir symlink", "Write", "file_path", abs("link-to-dir/contract.txt"), false, "protected"},
		{"dangling symlink to protected area", "Write", "file_path", abs("dangling"), false, "protected"},
		{"protected different case", "Write", "file_path", abs("Protected/Contract.TXT"), false, "protected"},
		{"git config", "Write", "file_path", abs(".git/config"), false, ".git"},
		{"git new file", "Write", "file_path", abs(".git/hooks/pre-commit"), false, ".git"},
		{"nested git", "Edit", "file_path", abs("sub/.git/config"), false, ".git"},
		{"git via symlink", "Write", "file_path", abs("link-to-git/config"), false, ".git"},
		{"outside", "Write", "file_path", filepath.Join(filepath.Dir(h.root), "outside", "x.txt"), false, "outside"},
		{"outside dotdot", "Write", "file_path", abs("../outside/x.txt"), false, "outside"},
		{"outside via symlink", "Write", "file_path", abs("link-outside/x.txt"), false, "outside"},
		{"no path", "Write", "file_path", "", false, "no file path"},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			id := "toolu_" + string(rune('a'+i))
			code, out := h.pre(c.tool, c.key, c.path, id)
			if code != 0 {
				t.Fatalf("exit %d", code)
			}
			recs := h.sentinels()
			last := recs[len(recs)-1]
			if last.ToolUseID != id || last.ToolName != c.tool || last.Nonce != "n1" || last.Hook != "pretool" || last.Time == "" {
				t.Fatalf("sentinel %+v", last)
			}
			if c.allow {
				if out != "" || last.Decision != "allow" {
					t.Fatalf("allow: stdout %q sentinel %+v", out, last)
				}
				return
			}
			var resp struct {
				Out struct {
					Event    string `json:"hookEventName"`
					Decision string `json:"permissionDecision"`
					Reason   string `json:"permissionDecisionReason"`
				} `json:"hookSpecificOutput"`
			}
			if err := json.Unmarshal([]byte(out), &resp); err != nil {
				t.Fatalf("stdout %q: %v", out, err)
			}
			if resp.Out.Event != "PreToolUse" || resp.Out.Decision != "deny" || !strings.Contains(resp.Out.Reason, c.why) {
				t.Fatalf("response %+v, want reason containing %q", resp.Out, c.why)
			}
			if last.Decision != "deny" || last.Reason == "" {
				t.Fatalf("sentinel %+v", last)
			}
		})
	}
}

func TestPreToolProtectedDirectory(t *testing.T) {
	t.Parallel()
	h := newHookEnv(t, "protected", "top.txt")
	if code, out := h.pre("Write", "file_path", filepath.Join(h.root, "protected", "anything", "new.txt"), "t1"); code != 0 || !strings.Contains(out, "deny") {
		t.Fatalf("directory protection: %d %q", code, out)
	}
	if code, out := h.pre("Write", "file_path", filepath.Join(h.root, "top.txt"), "t2"); code != 0 || !strings.Contains(out, "deny") {
		t.Fatalf("file protection: %d %q", code, out)
	}
	if code, out := h.pre("Write", "file_path", filepath.Join(h.root, "protected-other.txt"), "t3"); code != 0 || out != "" {
		t.Fatalf("sibling with a shared prefix must be allowed: %d %q", code, out)
	}
}

func TestPreToolRelativeUsesHookCWD(t *testing.T) {
	t.Parallel()
	h := newHookEnv(t)
	code, so, _ := h.run("pretool", map[string]any{"cwd": filepath.Join(h.root, "protected"), "tool_name": "Write", "tool_use_id": "t", "tool_input": map[string]any{"file_path": "contract.txt"}})
	if code != 0 || !strings.Contains(so, "deny") {
		t.Fatalf("relative path in a protected cwd: %d %q", code, so)
	}
}

func TestPreToolFailsClosed(t *testing.T) {
	t.Parallel()
	h := newHookEnv(t)
	var so, se bytes.Buffer
	good := `{"cwd":"` + h.root + `","tool_name":"Write","tool_use_id":"t","tool_input":{"file_path":"a.txt"}}`
	cases := []struct {
		name  string
		args  []string
		stdin string
	}{
		{"no args", nil, good},
		{"unknown mode", []string{"guard", "--policy", h.policy}, good},
		{"no policy flag", []string{"pretool"}, good},
		{"missing policy file", []string{"pretool", "--policy", filepath.Join(t.TempDir(), "nope.json")}, good},
		{"bad input", []string{"pretool", "--policy", h.policy}, "{not json"},
	}
	for _, c := range cases {
		so.Reset()
		se.Reset()
		if code := RunHook(c.args, strings.NewReader(c.stdin), &so, &se); code != 2 || so.Len() != 0 {
			t.Errorf("%s: exit %d stdout %q", c.name, code, so.String())
		}
	}
	// A log that cannot be written blocks (liveness could not be proven).
	b, _ := json.Marshal(policy{Root: h.root, Log: filepath.Join(t.TempDir(), "no", "such", "dir", "log"), Nonce: "n"})
	bad := filepath.Join(t.TempDir(), "p.json")
	os.WriteFile(bad, b, 0o600)
	if code := RunHook([]string{"pretool", "--policy", bad}, strings.NewReader(good), &so, &se); code != 2 {
		t.Errorf("unwritable log: exit %d", code)
	}
}

func TestPostToolObservesAndNeverBlocks(t *testing.T) {
	t.Parallel()
	h := newHookEnv(t)
	code, so, se := h.run("posttool", map[string]any{"cwd": h.root, "tool_name": "Bash", "tool_use_id": "tb", "tool_input": map[string]any{"command": "echo SECRET=abc"}, "tool_response": map[string]any{"stdout": "SECRET=abc"}})
	if code != 0 || so != "" || se != "" {
		t.Fatalf("posttool: %d %q %q", code, so, se)
	}
	recs := h.sentinels()
	if len(recs) != 1 || recs[0].Hook != "posttool" || recs[0].Decision != "observed" || recs[0].ToolUseID != "tb" || recs[0].ToolName != "Bash" {
		t.Fatalf("records %+v", recs)
	}
	raw, _ := os.ReadFile(h.log)
	if strings.Contains(string(raw), "SECRET") {
		t.Fatal("posttool logged command or output")
	}
	// A posttool failure never blocks.
	if code := RunHook([]string{"posttool", "--policy", filepath.Join(t.TempDir(), "nope")}, strings.NewReader("{}"), &bytes.Buffer{}, &bytes.Buffer{}); code != 0 {
		t.Fatalf("posttool failure exit %d", code)
	}
}

func TestSentinelLogAppendsAndIsPrivate(t *testing.T) {
	t.Parallel()
	h := newHookEnv(t)
	h.pre("Write", "file_path", filepath.Join(h.root, "a.txt"), "t1")
	h.pre("Write", "file_path", filepath.Join(h.root, "b.txt"), "t2")
	if recs := h.sentinels(); len(recs) != 2 || recs[0].ToolUseID != "t1" || recs[1].ToolUseID != "t2" {
		t.Fatalf("records %+v", recs)
	}
	if fi, err := os.Stat(h.log); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("log mode: %v %v", fi, err)
	}
	recs, err := readSentinels(h.log, "n1")
	if err != nil || len(recs) != 2 || recs["t2"].Decision != "allow" {
		t.Fatalf("readSentinels: %+v %v", recs, err)
	}
	if recs, _ := readSentinels(h.log, "other"); len(recs) != 0 {
		t.Fatal("a record of another nonce counted")
	}
}
