package contract_test

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-loop/tools"
)

// newTools is Tools for root with the session's hermetic environment and these tools enabled.
func newTools(s *sys.Session, enabled ...string) *tools.Tools {
	return &tools.Tools{Root: s.Cwd, Session: s, Enabled: enabled}
}

// sortedLines is text with its lines sorted: Git lists untracked files before or after the others.
func sortedLines(text string) string {
	lines := strings.Split(text, "\n")
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}

func run(t *testing.T, tl *tools.Tools, name string, args map[string]any) string {
	t.Helper()
	out, err := tl.Run(name, args)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if out.Typed() {
		t.Fatalf("%s: typed result", name)
	}
	return out.Text
}

// TestToolsRefuseNamesThatAreNotEnabled pins the text of a call to a tool that is not enabled
// and that the disabled shell does not run. Adapted from kogen-executor agent/tools_test.go.
func TestToolsRefuseNamesThatAreNotEnabled(t *testing.T) {
	s, root, _ := newSession(t)
	tl := newTools(s, tools.ReadFileTool)
	writeFile(t, filepath.Join(root, "a"), "x\n", 0o644)
	for _, name := range []string{tools.ShellTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.ViewImageTool, tools.DocumentationTool, "probe", "finish", "bogus", ""} {
		got := run(t, tl, name, map[string]any{"command": "touch x", "path": "a", "content": "y", "pattern": "x"})
		if got != "error: unknown tool "+name {
			t.Errorf("%q: %q", name, got)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "x")); err == nil {
		t.Error("a disabled shell ran")
	}
	// An enabled name nothing implements (a terminal tool) is also unknown.
	tl.Enabled = append(tl.Enabled, "finish")
	if got := run(t, tl, "finish", nil); got != "error: unknown tool finish" {
		t.Errorf("finish: %q", got)
	}
}

// TestToolsReadFileNumbersLines pins read_file's `<n>\t<line>` text and its refusals.
// Adapted from kogen-executor agent/tools_test.go.
func TestToolsReadFileNumbersLines(t *testing.T) {
	s, root, _ := newSession(t)
	tl := newTools(s, tools.ReadFileTool)
	writeFile(t, filepath.Join(root, "a"), "x\n", 0o644)
	writeFile(t, filepath.Join(root, "b"), "one\ntwo\nthree\n", 0o644)
	if got := run(t, tl, tools.ReadFileTool, map[string]any{"path": "a"}); got != "1\tx" {
		t.Errorf("read_file: %q", got)
	}
	if got := run(t, tl, tools.ReadFileTool, map[string]any{"path": "b", "start_line": int64(2), "end_line": int64(3)}); got != "2\ttwo\n3\tthree" {
		t.Errorf("read_file range: %q", got)
	}
	if got := run(t, tl, tools.ReadFileTool, map[string]any{"path": "missing"}); got != "error: missing does not exist" {
		t.Errorf("read_file of a missing file: %q", got)
	}
	outside := filepath.Join(t.TempDir(), "outside")
	if got := run(t, tl, tools.ReadFileTool, map[string]any{"path": outside}); got != "error: "+outside+": path is outside the repository root; reads are confined to the repository root" {
		t.Errorf("read_file outside the root: %q", got)
	}
	if got := run(t, tl, tools.ReadFileTool, map[string]any{"path": "~/x"}); got != "error: ~/x: home paths (~) are not allowed; reads are confined to the repository root" {
		t.Errorf("read_file of a home path: %q", got)
	}
	if got := run(t, tl, tools.ReadFileTool, map[string]any{}); got != "error: argument path must be a string" {
		t.Errorf("read_file without a path: %q", got)
	}
}

// TestToolsWriteFileRefusesProtectedPaths pins write_file and Tools.Protected.
// Adapted from kogen-build build/executor_native.go (the approved baseline is the protected set).
func TestToolsWriteFileRefusesProtectedPaths(t *testing.T) {
	s, root, _ := newSession(t)
	tl := newTools(s, tools.WriteFileTool, tools.ReadFileTool)
	tl.Protected = []string{"features/accept.feature"}
	if got := run(t, tl, tools.WriteFileTool, map[string]any{"path": "dir/new.txt", "content": "text\n"}); got != "ok" {
		t.Fatalf("write_file: %q", got)
	}
	if b, err := os.ReadFile(filepath.Join(root, "dir", "new.txt")); err != nil || string(b) != "text\n" {
		t.Fatalf("written file %q, %v", b, err)
	}
	got := run(t, tl, tools.WriteFileTool, map[string]any{"path": "features/accept.feature", "content": "changed"})
	if got != "refused: features/accept.feature is part of the approved acceptance baseline" {
		t.Fatalf("write_file of a protected path: %q", got)
	}
	if _, err := os.Stat(filepath.Join(root, "features")); err == nil {
		t.Fatal("a protected write created its folder")
	}
}

// TestToolsListAndSearchThroughGit pins list_files and search_text on a Git repository.
// Adapted from kogen-executor agent/git_test.go (TestToolsRunThroughKogensRepository).
func TestToolsListAndSearchThroughGit(t *testing.T) {
	root := repo(t, map[string]string{"a.txt": "needle\n", "sub/b.txt": "hay\n"})
	home := t.TempDir()
	tl := newTools(sys.NewWith(hermeticEnv(home), root), tools.ListFilesTool, tools.SearchTextTool)
	writeFile(t, filepath.Join(root, "new.txt"), "needle again\n", 0o644)
	if got := run(t, tl, tools.ListFilesTool, nil); sortedLines(got) != "a.txt\nnew.txt\nsub/b.txt" {
		t.Errorf("list_files: %q", got)
	}
	if got := run(t, tl, tools.ListFilesTool, map[string]any{"path": "sub"}); got != "sub/b.txt" {
		t.Errorf("list_files of a folder: %q", got)
	}
	if got := run(t, tl, tools.SearchTextTool, map[string]any{"pattern": "needle"}); got != "a.txt:1:needle\nnew.txt:1:needle again" {
		t.Errorf("search_text: %q", got)
	}
	if got := run(t, tl, tools.SearchTextTool, map[string]any{"pattern": "absent"}); got != "(no matches)" {
		t.Errorf("search_text without a match: %q", got)
	}
}

// gitRepo is a tools.Git that answers from a real repository, as kogen-executor's adapter answers from
// Kogen's: Run is git in root, Head the commit HEAD names and Tree the candidate tree built in a private
// index. It counts what the tools ask of it.
type gitRepo struct {
	home string
	root string
	runs int
}

func (g *gitRepo) git(extra []string, args ...string) (tools.GitResult, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = g.root
	cmd.Env = append(hermeticEnv(g.home), extra...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	res := tools.GitResult{}
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			return res, err
		}
		res.Status = ee.ExitCode()
	}
	res.Stdout, res.Stderr = out.String(), errb.String()
	return res, nil
}

func (g *gitRepo) Run(args ...string) (tools.GitResult, error) {
	g.runs++
	return g.git(nil, args...)
}

func (g *gitRepo) Head() string {
	res, err := g.git(nil, "rev-parse", "--verify", "-q", "HEAD")
	if err != nil || res.Status != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

func (g *gitRepo) Tree(start string, excluded []string) (string, error) {
	index := filepath.Join(g.home, "candidate-index")
	defer os.Remove(index)
	env := []string{"GIT_INDEX_FILE=" + index}
	add := []string{"add", "-A", "--", "."}
	for _, p := range excluded {
		add = append(add, ":(exclude,literal)"+p)
	}
	for _, args := range [][]string{{"read-tree", start}, add} {
		if res, err := g.git(env, args...); err != nil || res.Status != 0 {
			return "", errors.New("git " + args[0] + " failed: " + res.Stderr)
		}
	}
	res, err := g.git(env, "write-tree")
	return strings.TrimSpace(res.Stdout), err
}

// TestToolsRepoRunsTheGitOfTheCaller pins Tools.Repo and the tools.Git interface: list_files and search_text
// run through the caller's Git, and view_image reads its candidate from Repo.Tree of Repo.Head with
// Tools.Excluded. Adapted from kogen-executor agent/git_test.go and kogen-build build/review_delivery_test.go.
func TestToolsRepoRunsTheGitOfTheCaller(t *testing.T) {
	root := repo(t, map[string]string{"a.txt": "needle\n"})
	writeFile(t, filepath.Join(root, "shot.png"), string(pngOf(t, 2, 2)), 0o644)
	impl := &gitRepo{home: t.TempDir(), root: root}
	var g tools.Git = impl

	head := g.Head()
	if want := strings.TrimSpace(gitIn(t, root, "rev-parse", "HEAD")); head == "" || head != want {
		t.Fatalf("Head = %q, want %q", head, want)
	}
	res, err := g.Run("ls-files", "--others", "--exclude-standard")
	if err != nil || res != (tools.GitResult{Stdout: "shot.png\n", Stderr: "", Status: 0}) {
		t.Fatalf("Run = %+v, %v", res, err)
	}
	res, err = g.Run("rev-parse", "--verify", "no-such-ref")
	if err != nil || res.Status == 0 || res.Stderr == "" || res.Stdout != "" {
		t.Fatalf("a failing command is a status with Git's text: %+v, %v", res, err)
	}
	headTree := strings.TrimSpace(gitIn(t, root, "rev-parse", "HEAD^{tree}"))
	candidate, err := g.Tree(head, nil)
	if err != nil || len(candidate) != 40 || candidate == headTree {
		t.Fatalf("Tree = %q, %v (HEAD's tree %s)", candidate, err, headTree)
	}
	if got, err := g.Tree(head, []string{"shot.png"}); err != nil || got != headTree {
		t.Fatalf("Tree without the image = %q, %v", got, err)
	}
	if _, err := g.Tree("", nil); err == nil {
		t.Fatal("a Tree from nothing")
	}

	impl.runs = 0
	tl := &tools.Tools{Root: root, Session: sys.NewWith(hermeticEnv(t.TempDir()), root), Repo: g,
		Enabled: []string{tools.ListFilesTool, tools.SearchTextTool, tools.ViewImageTool}, Excluded: []string{"other-intent"}}
	if got := run(t, tl, tools.ListFilesTool, nil); sortedLines(got) != "a.txt\nshot.png" {
		t.Errorf("list_files: %q", got)
	}
	if got := run(t, tl, tools.SearchTextTool, map[string]any{"pattern": "needle"}); got != "a.txt:1:needle" {
		t.Errorf("search_text: %q", got)
	}
	if impl.runs != 2 {
		t.Errorf("the two tools made %d runs through Tools.Repo", impl.runs)
	}
	out, err := tl.Run(tools.ViewImageTool, map[string]any{"path": "shot.png"})
	if err != nil || !out.Typed() {
		t.Fatalf("view_image = %+v, %v", out, err)
	}
	entries := tools.ImageEntries([]any{tools.OutputItem("call-1", out)})
	if len(entries) != 1 || entries[0].Meta["read_candidate"] != candidate {
		t.Fatalf("entries %+v: the candidate is not the tree Repo answered (%s)", entries, candidate)
	}
	var entry tools.ImageEntry = entries[0]
	if entry.CallID != "call-1" {
		t.Fatalf("entry %+v", entry)
	}
	tl.Excluded = []string{"shot.png"}
	out, _ = tl.Run(tools.ViewImageTool, map[string]any{"path": "shot.png"})
	if entries := tools.ImageEntries([]any{tools.OutputItem("call-2", out)}); len(entries) != 1 || entries[0].Meta["read_candidate"] != headTree {
		t.Fatalf("with the image excluded: %+v", entries)
	}
}

// TestToolsProbeBelongsToTheCaller pins the Probe seam: without one the probe tool says so, with one
// it receives the validated command and the raw files, and its error ends the call.
// Adapted from kogen-executor agent/tools_test.go (TestProbeBelongsToTheShaper).
func TestToolsProbeBelongsToTheCaller(t *testing.T) {
	s, _, _ := newSession(t)
	tl := newTools(s, "probe")
	if got := run(t, tl, "probe", map[string]any{"command": "true"}); got != "error: probe is not available" {
		t.Errorf("without a probe: %q", got)
	}
	var gotCommand string
	var gotFiles any
	tl.Probe = func(command string, files any) (string, error) {
		gotCommand, gotFiles = command, files
		return "exit status: 0\ntimed_out: false\nwall: 0.1 s\n", nil
	}
	files := []any{map[string]any{"path": "a", "content": "b"}}
	if got := run(t, tl, "probe", map[string]any{"command": "make", "files": files}); !strings.HasPrefix(got, "exit status: 0\n") {
		t.Errorf("%q", got)
	}
	if gotCommand != "make" || len(gotFiles.([]any)) != 1 {
		t.Errorf("probe got %q %v", gotCommand, gotFiles)
	}
	if got := run(t, tl, "probe", map[string]any{"command": 5}); got != "error: argument command must be a string" {
		t.Errorf("invalid command: %q", got)
	}
	failure := errors.New("interrupted")
	tl.Probe = func(string, any) (string, error) { return "", failure }
	if _, err := tl.Run("probe", map[string]any{"command": "x"}); err != failure {
		t.Errorf("error %v", err)
	}
}

// TestToolsShellRunsInTheRootAndCutsOutput pins the shell tool through Tools.Run and the cut of
// its result by Output.Cut and tools.Cut: the status line precedes the marker,
// and the long output line falls back to a bounded byte suffix. Adapted from kogen cli/research_removal_test.go.
func TestToolsShellRunsInTheRootAndCutsOutput(t *testing.T) {
	s, root, _ := newSession(t)
	tl := newTools(s, tools.ShellTool)
	if got := run(t, tl, tools.ShellTool, map[string]any{"command": "pwd -P; echo $((6*7))"}); got != "exit status: 0\n"+root+"\n42\n" {
		t.Errorf("shell: %q", got)
	}
	out, err := tl.Run(tools.ShellTool, map[string]any{"command": "head -c 30000 /dev/zero | tr '\\000' a"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.Text, "exit status: 0\n") || len(out.Text) != len("exit status: 0\n")+30000 {
		t.Fatalf("raw output is %d bytes", len(out.Text))
	}
	cut := out.Cut().Text
	loc := strings.Index(cut, "\n[... ")
	if len(cut) > 16384 || loc != len("exit status: 0\n") || !strings.Contains(cut, "bytes omitted ...]") {
		t.Fatalf("%d bytes, marker at %d: %.120q", len(cut), loc, cut[max(0, loc-10):])
	}
	for _, text := range []string{out.Text, strings.Repeat("é", 20000), "short"} {
		if got, want := (tools.Output{Text: text}).Cut().Text, tools.Cut(text); got != want {
			t.Errorf("Output.Cut and tools.Cut differ: %d and %d bytes", len(got), len(want))
		}
	}
	whole := tools.Cut(out.Text)
	if len(whole) > 16384 || strings.Index(whole, "\n[... ") != loc || tools.Cut(whole) != whole || tools.Cut("short") != "short" {
		t.Fatalf("tools.Cut: %d bytes, marker at %d", len(whole), strings.Index(whole, "\n[... "))
	}
	typed := tools.Output{Parts: []any{map[string]any{"type": "input_text", "text": strings.Repeat("x", 20000)}}}
	if got := typed.Cut(); !reflect.DeepEqual(got, typed) || !typed.Typed() || len(typed.Parts) != 1 {
		t.Error("typed parts changed")
	}
}

// TestOutputValueIsTheTextOrTheParts pins Output.Text, Output.Parts, Output.Typed and
// Output.Value, the "output" of a function_call_output. Adapted from kogen-build build/records.go
// and kogen cli/research_removal_test.go.
func TestOutputValueIsTheTextOrTheParts(t *testing.T) {
	text := tools.Output{Text: "done"}
	if text.Typed() || text.Value() != "done" || text.Text != "done" || text.Parts != nil {
		t.Errorf("text output %+v", text)
	}
	parts := []any{map[string]any{"type": "input_text", "text": "meta"}, map[string]any{"type": "input_image", "image_url": "data:image/png;base64,AA=="}}
	typed := tools.Output{Parts: parts}
	if !typed.Typed() || !reflect.DeepEqual(typed.Value(), parts) || len(typed.Parts) != 2 || typed.Text != "" {
		t.Errorf("typed output %+v", typed)
	}
	var out tools.Output = typed
	if got := tools.OutputItem("c1", out); !reflect.DeepEqual(got["output"], parts) {
		t.Errorf("OutputItem of an Output = %v", got)
	}
}

// TestDecodeArgumentsOfAnythingButAnObject pins the invalid-argument object and the Call that
// carries it. Adapted from kogen-shaping shape/init_test.go and kogen-build build/review_delivery_test.go.
func TestDecodeArgumentsOfAnythingButAnObject(t *testing.T) {
	invalid := map[string]any{"__invalid__": true}
	for _, in := range []string{"", "not json", "[1,2]", `"text"`, "42", "null", `{"a":1} trailing`} {
		if got := tools.DecodeArguments(in); !reflect.DeepEqual(got, invalid) || fmt.Sprint(got) != "map[__invalid__:true]" {
			t.Errorf("DecodeArguments(%q) = %v", in, got)
		}
	}
	if got := tools.DecodeArguments(`{"path":"a","n":2}`); got["path"] != "a" || len(got) != 2 {
		t.Errorf("DecodeArguments(object) = %v", got)
	}
	call := tools.Call{Item: map[string]any{"type": "function_call", "call_id": "c1"}, Name: "read_file", Arguments: "oops"}
	if got := call.Args(); !reflect.DeepEqual(got, invalid) {
		t.Errorf("Call.Args = %v", got)
	}
	s, _, _ := newSession(t)
	tl := newTools(s, tools.ReadFileTool)
	out, err := tl.Call(call)
	if err != nil || out.Text != "error: argument path must be a string" {
		t.Errorf("a call with invalid arguments = %+v, %v", out, err)
	}
}

// TestCallsAndOutputItems pins Calls, the Call fields and the function_call_output that answers a
// call, in exact JSON. Adapted from kogen-build build/builder.go, build/review_delivery_test.go and
// kogen-shaping shape/conversation.go.
func TestCallsAndOutputItems(t *testing.T) {
	items := []map[string]any{
		textItem("thinking aloud"),
		callItem("1", "read_file", map[string]any{"path": "a"}),
		{"type": "reasoning", "id": "rs-1"},
		callItem("2", "list_files", map[string]any{}),
	}
	calls := tools.Calls(items)
	if len(calls) != 2 || calls[0].Name != "read_file" || calls[0].Arguments != `{"path":"a"}` || calls[1].Name != "list_files" {
		t.Fatalf("Calls = %+v", calls)
	}
	if calls[0].CallID() != "call-1" || !reflect.DeepEqual(calls[0].Item, items[1]) || calls[0].Args()["path"] != "a" {
		t.Fatalf("call 1 = %+v", calls[0])
	}
	if tools.Calls(nil) != nil || (tools.Call{Item: map[string]any{}}).CallID() != nil {
		t.Error("no calls, no call id")
	}
	if got := jsonText(t, tools.OutputItem("call-1", "1\tx")); got != `{"call_id":"call-1","output":"1\tx","type":"function_call_output"}` {
		t.Errorf("OutputItem = %s", got)
	}
	got := tools.OutputItem("call-1", "text")
	if !reflect.DeepEqual(got, map[string]any{"type": "function_call_output", "call_id": "call-1", "output": "text"}) || len(got) != 3 {
		t.Errorf("OutputItem = %v", got)
	}
	if got := calls[1].Output(tools.Output{Text: "a.txt"}); !reflect.DeepEqual(got, map[string]any{"type": "function_call_output", "call_id": "call-2", "output": "a.txt"}) {
		t.Errorf("Call.Output = %v", got)
	}
}

// TestReplayKeepsWhatTheProviderAcceptsBack pins Replay and ReplayItem: the fields the next request
// replays, nothing manufactured, nothing for other items. Adapted from kogen-shaping shape/batch.go,
// kogen-build build/executor_native.go and kogen's migration drivers (shape_working_summary).
func TestReplayKeepsWhatTheProviderAcceptsBack(t *testing.T) {
	call := map[string]any{"type": "function_call", "id": "fc-1", "call_id": "call-1", "name": "shell", "arguments": "{}", "status": "completed", "extra": "dropped"}
	if got := tools.ReplayItem(call); !reflect.DeepEqual(got, map[string]any{"type": "function_call", "id": "fc-1", "call_id": "call-1", "name": "shell", "arguments": "{}", "status": "completed"}) {
		t.Errorf("function_call replays as %v", got)
	}
	reasoning := map[string]any{"type": "reasoning", "id": "rs-1", "encrypted_content": "blob", "summary": []any{}, "extra": 1}
	if got := tools.ReplayItem(reasoning); !reflect.DeepEqual(got, map[string]any{"type": "reasoning", "id": "rs-1", "encrypted_content": "blob", "summary": []any{}}) {
		t.Errorf("reasoning replays as %v", got)
	}
	msg := map[string]any{"type": "message", "id": "m-1", "role": "assistant", "status": "completed", "content": []any{
		map[string]any{"type": "output_text", "text": "hello", "annotations": []any{}},
		map[string]any{"type": "other"},
	}}
	want := map[string]any{"type": "message", "id": "m-1", "role": "assistant", "status": "completed",
		"content": []any{map[string]any{"type": "output_text", "text": "hello"}}}
	if got := tools.ReplayItem(msg); !reflect.DeepEqual(got, want) {
		t.Errorf("message replays as %v", got)
	}
	for _, none := range []map[string]any{{"type": "web_search_call"}, {"type": "message", "content": []any{map[string]any{"type": "other"}}}, {"type": "message"}} {
		if got := tools.ReplayItem(none); got != nil {
			t.Errorf("%v replays as %v", none, got)
		}
	}
	replayed := tools.Replay([]map[string]any{reasoning, {"type": "web_search_call"}, call, msg})
	if len(replayed) != 3 || replayed[0].(map[string]any)["type"] != "reasoning" || replayed[2].(map[string]any)["type"] != "message" {
		t.Errorf("Replay = %v", replayed)
	}
}

// TestDefinitionsOfTheGenericTools pins the model-facing definitions consumers send: their names,
// required arguments and the AsAny list. Adapted from kogen-executor agent/defs_test.go and
// kogen cli/research_removal_test.go.
func TestDefinitionsOfTheGenericTools(t *testing.T) {
	s, _, _ := newSession(t)
	tl := newTools(s)
	required := map[string][]any{
		tools.ShellTool: {}, tools.ViewImageTool: {"path"}, tools.ReadFileTool: {"path"}, tools.WriteFileTool: {"path", "content"},
		tools.ListFilesTool: {}, tools.SearchTextTool: {"pattern"}, tools.DocumentationTool: {"operation"},
	}
	var defs []map[string]any
	for _, name := range []string{tools.ShellTool, tools.ViewImageTool, tools.ReadFileTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.DocumentationTool} {
		def, ok := tools.Definition(name)
		if !ok || def["type"] != "function" || def["name"] != name || def["strict"] != false {
			t.Fatalf("Definition(%s) = %v, %v", name, def, ok)
		}
		params, _ := def["parameters"].(map[string]any)
		if params["type"] != "object" || params["additionalProperties"] != false || !reflect.DeepEqual(params["required"], required[name]) {
			t.Errorf("%s parameters %v", name, params)
		}
		if viaTools, ok := tl.Definition(name); !ok || !reflect.DeepEqual(viaTools, def) {
			t.Errorf("Tools.Definition(%s) differs from Definition", name)
		}
		defs = append(defs, def)
	}
	for _, name := range []string{"finish", "report_blocker", "probe", "bogus", ""} {
		if def, ok := tools.Definition(name); ok || def != nil {
			t.Errorf("Definition(%q) = %v", name, def)
		}
		if def, ok := tl.Definition(name); ok || def != nil {
			t.Errorf("Tools.Definition(%q) = %v", name, def)
		}
	}
	list := tools.AsAny(defs[:2], defs[2:])
	if len(list) != 7 || list[0].(map[string]any)["name"] != "shell" || list[6].(map[string]any)["name"] != "documentation" {
		t.Errorf("AsAny = %v", list)
	}
	if got := tools.AsAny(); len(got) != 0 {
		t.Errorf("AsAny() = %v", got)
	}
}

// TestMeasureAgainstTheInputBudget pins Measure and the budget constants: a body of exactly
// 524288 bytes fits, one byte more does not. Adapted from kogen cli/research_removal_test.go and
// kogen-shaping shape/window_test.go.
func TestMeasureAgainstTheInputBudget(t *testing.T) {
	if tools.InputBudgetBytes != 524288 || tools.OutputReserveTokens != 131072 || provider.InputBudgetBytes != 524288 || provider.OutputReserveTokens != 131072 {
		t.Fatalf("budget %d bytes, reserve %d tokens", tools.InputBudgetBytes, tools.OutputReserveTokens)
	}
	// {"x":"<n a's>"} is n+8 bytes.
	fit, err := tools.Measure(map[string]any{"x": strings.Repeat("a", 524288-8)})
	if err != nil || fit.RenderedBytes != 524288 || fit.InputBudgetBytes != 524288 || fit.OutputReserveTokens != 131072 || !fit.Fits {
		t.Fatalf("at the ceiling: %+v (%v)", fit, err)
	}
	var m tools.Measurement = fit
	over, err := tools.Measure(map[string]any{"x": strings.Repeat("a", 524288-7)})
	if err != nil || over.RenderedBytes != 524289 || over.Fits || over.InputBudgetBytes != m.InputBudgetBytes {
		t.Fatalf("one byte over: %+v (%v)", over, err)
	}
}

// pngOf is a small opaque RGB8 PNG: view_image's input.
func pngOf(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		for y := 0; y < h; y++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 40), G: uint8(y * 40), B: 99, A: 255})
		}
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// TestImageToolDeliversPixelsAndEvents pins view_image as typed parts, ImageEntries and ReadEvent
// on them, and Deliver's image_delivery events. Adapted from kogen-build build/material.go,
// build/review_delivery_test.go and build/executor_native.go.
func TestImageToolDeliversPixelsAndEvents(t *testing.T) {
	s, root, _ := newSession(t)
	data := pngOf(t, 3, 2)
	writeFile(t, filepath.Join(root, "shot.png"), string(data), 0o644)
	tl := newTools(s, tools.ViewImageTool)
	call := tools.Call{Item: map[string]any{"type": "function_call", "call_id": "call-img"}, Name: tools.ViewImageTool, Arguments: `{"path":"shot.png"}`}
	out, err := tl.Call(call)
	if err != nil || !out.Typed() || len(out.Parts) != 2 {
		t.Fatalf("view_image = %+v, %v", out, err)
	}
	input := []any{user("look"), call.Output(out)}
	entries := tools.ImageEntries(input)
	if len(entries) != 1 || entries[0].CallID != "call-img" {
		t.Fatalf("entries %+v", entries)
	}
	meta := entries[0].Meta
	if meta["path"] != "shot.png" || meta["format"] != "png" || fmt.Sprint(meta["width"]) != "3" || fmt.Sprint(meta["height"]) != "2" || fmt.Sprint(meta["bytes"]) != fmt.Sprint(len(data)) {
		t.Fatalf("metadata %v", meta)
	}
	if got := tools.ImageEntries([]any{user("no image"), tools.OutputItem("c", "text")}); len(got) != 0 {
		t.Fatalf("entries of text: %v", got)
	}
	event := tools.ReadEvent(call, out, "build")
	if event["event"] != "image_read" || event["owner"] != "build" || event["call_id"] != "call-img" || event["status"] != "read" || event["sha256"] != meta["sha256"] {
		t.Fatalf("ReadEvent = %v", event)
	}
	if got := tools.ReadEvent(call, tools.Output{Text: "text"}, "build"); got != nil {
		t.Fatalf("ReadEvent of text = %v", got)
	}

	var events []map[string]any
	resp, err := tools.Deliver(input, "build", func(e map[string]any) { events = append(events, e) },
		func() (*provider.Response, error) { return &provider.Response{ID: "resp-1"}, nil })
	if err != nil || resp.ID != "resp-1" || len(events) != 1 {
		t.Fatalf("Deliver = %+v, %v, %v", resp, err, events)
	}
	if e := events[0]; e["event"] != "image_delivery" || e["owner"] != "build" || e["status"] != "completed" || e["call_id"] != "call-img" ||
		e["response_id"] != "resp-1" || e["sha256"] != meta["sha256"] || e["request_id"] == "" {
		t.Fatalf("delivery event %v", e)
	}
	events = nil
	rejected := &sys.Error{Class: "provider", Reason: "refused", Detail: "no", Exit: 4, ProviderFailure: map[string]any{"http_status": 400}}
	if _, err := tools.Deliver(input, "build", func(e map[string]any) { events = append(events, e) },
		func() (*provider.Response, error) { return nil, rejected }); err != rejected || len(events) != 1 || events[0]["status"] != "failed" || events[0]["response_id"] != nil {
		t.Fatalf("a rejected request: %v, %v", err, events)
	}
	events = nil
	if _, err := tools.Deliver(input, "build", func(e map[string]any) { events = append(events, e) },
		func() (*provider.Response, error) { return nil, errors.New("connection reset") }); err == nil || len(events) != 1 || events[0]["status"] != "unknown" {
		t.Fatalf("an unknown outcome: %v, %v", err, events)
	}
	events = nil
	if _, err := tools.Deliver([]any{user("no image")}, "build", func(e map[string]any) { events = append(events, e) },
		func() (*provider.Response, error) { return &provider.Response{}, nil }); err != nil || len(events) != 0 {
		t.Fatalf("without images: %v, %v", err, events)
	}
	outside := filepath.Join(t.TempDir(), "outside.png")
	if got := run(t, tl, tools.ViewImageTool, map[string]any{"path": outside}); got != "error: "+outside+": path is outside the repository root; reads are confined to the repository root" {
		t.Errorf("view_image outside the root: %q", got)
	}
}

// TestDocumentationFetchesWithTheUserAgent pins Documentation.Lookup, its UserAgent and the
// Documentation of Tools on a loopback origin. Adapted from kogen cli/research_removal_test.go and
// kogen-shaping shape/refine.go.
func TestDocumentationFetchesWithTheUserAgent(t *testing.T) {
	var agent string
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		agent = r.Header.Get("User-Agent")
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprint(w, "hello docs\n")
	}))
	defer origin.Close()
	d := tools.Documentation{UserAgent: "kogen/1.2.3"}
	out := d.Lookup(map[string]any{"operation": "fetch", "url": origin.URL + "/page", "base": origin.URL})
	contains(t, "Lookup", out, `"status":"retrieved"`, `"body":"hello docs\n"`, `"body_total":11`, `"untrusted":true`, `"truncated":false`)
	if agent != "kogen/1.2.3" {
		t.Errorf("user-agent %q", agent)
	}
	if out := d.Lookup(map[string]any{"operation": "fetch", "url": "ftp://example.invalid/x"}); !strings.Contains(out, `"status":"unsupported"`) {
		t.Errorf("an unsupported source: %s", out)
	}
	if out := d.Lookup(nil); !strings.Contains(out, "documentation source unsupported") {
		t.Errorf("Lookup(nil): %s", out)
	}

	s, _, _ := newSession(t)
	tl := newTools(s, tools.DocumentationTool)
	tl.Documentation = tools.Documentation{UserAgent: "kogen/4.5.6"}
	got := run(t, tl, tools.DocumentationTool, map[string]any{"operation": "fetch", "url": origin.URL + "/again", "base": origin.URL})
	if !strings.Contains(got, `"status":"retrieved"`) || agent != "kogen/4.5.6" {
		t.Errorf("documentation through Tools: %s (user-agent %q)", got, agent)
	}
}

// TestDocumentationOutputIsBounded pins the 16384-byte bound of a documentation result.
// Adapted from kogen cli/research_removal_test.go ("documentation keeps its pinned defaults").
func TestDocumentationOutputIsBounded(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < 4000; i++ {
			fmt.Fprintf(w, "line %05d\n", i)
		}
	}))
	defer origin.Close()
	out := (tools.Documentation{}).Lookup(map[string]any{"operation": "fetch", "url": origin.URL + "/big", "base": origin.URL})
	if !strings.Contains(out, `"body_total":44000`) || !strings.Contains(out, `"truncated":true`) || len(out) > 16384 || len(out) < 8192 {
		t.Fatalf("%d bytes: %.200q", len(out), out)
	}
}
