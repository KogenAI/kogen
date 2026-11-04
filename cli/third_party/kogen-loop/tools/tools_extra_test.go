package tools

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

func run(t *testing.T, tools *Tools, name string, args map[string]any) string {
	t.Helper()
	out, err := tools.Run(name, args)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if out.Typed() {
		t.Fatalf("%s: typed result", name)
	}
	return out.Text
}

func TestShellRunsInTheRootWithStdinClosedAndReportsStatusAndOutput(t *testing.T) {
	t.Parallel()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	tools := newTools(root, ShellTool)
	for _, c := range []struct{ command, want string }{
		{"echo hi; echo err >&2; exit 3", "exit status: 3\nhi\nerr\n"},
		{"pwd", "exit status: 0\n" + root + "\n"},
		{"cat; echo after", "exit status: 0\nafter\n"}, // stdin is closed: cat ends at once
		{"read x && echo got $x", "exit status: 1\n"},
		{"true", "exit status: 0\n"},
		{"kill -9 $$", "exit status: 137\n"},
		{"exit 300", "exit status: 44\n"},
		{"printf 'no newline'", "exit status: 0\nno newline"},
		{"nonexistent-command-xyz", "exit status: 127\n/bin/sh: nonexistent-command-xyz: command not found\n"},
	} {
		got := run(t, tools, ShellTool, map[string]any{"command": c.command})
		if c.command == "nonexistent-command-xyz" {
			if !strings.HasPrefix(got, "exit status: 127\n") || !strings.Contains(got, "nonexistent-command-xyz") {
				t.Errorf("%q: %q", c.command, got)
			}
			continue
		}
		if got != c.want {
			t.Errorf("%q: %q, want %q", c.command, got, c.want)
		}
	}
}

func TestShellUsesTheSessionsEnvironment(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	tools := &Tools{Root: root, Enabled: []string{ShellTool}, Session: sys.NewWith(append(os.Environ(), "KOGEN_AGENT_TEST=value"), root)}
	if got := run(t, tools, ShellTool, map[string]any{"command": "echo $KOGEN_AGENT_TEST"}); got != "exit status: 0\nvalue\n" {
		t.Errorf("%q", got)
	}
}

func TestShellQuickCommand(t *testing.T) {
	t.Parallel()
	tools := newTools(t.TempDir(), ShellTool)
	start := time.Now()
	got := run(t, tools, ShellTool, map[string]any{"command": "echo done"})
	if got != "exit status: 0\ndone\n" {
		t.Errorf("%q after %v", got, time.Since(start))
	}
}

func TestShellInterruptIsAnErrorNotAResult(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	session := sys.NewWith(os.Environ(), root)
	tools := &Tools{Root: root, Session: session, Enabled: []string{ShellTool}}
	type outcome struct {
		out Output
		err error
	}
	done := make(chan outcome, 1)
	go func() {
		out, err := tools.Run(ShellTool, map[string]any{"command": "echo ready > ready; sleep 30"})
		done <- outcome{out, err}
	}()
	joined := false
	defer func() {
		if !joined {
			session.Interrupt("SIGINT")
			sys.Terminate(session.Groups())
			<-done
		}
		tools.EndShellRound()
	}()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for {
		if _, err := os.Stat(filepath.Join(root, "ready")); err == nil {
			break
		}
		select {
		case got := <-done:
			joined = true
			t.Fatalf("command exited before readiness: %+v", got)
		case <-deadline.C:
			t.Fatal("command did not become ready")
		case <-time.After(10 * time.Millisecond):
		}
	}
	session.Interrupt("SIGINT")
	got := <-done
	joined = true
	out, err := got.out, got.err
	var interrupted *sys.Interrupted
	if !errors.As(err, &interrupted) || interrupted.Signal != "SIGINT" || out.Text != "" {
		t.Errorf("output %q, error %v", out.Text, err)
	}
	// Nothing starts after an interrupt.
	if _, err := tools.Run(ShellTool, map[string]any{"command": "touch started"}); !errors.As(err, &interrupted) {
		t.Errorf("error after an interrupt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "started")); err == nil {
		t.Error("a command started after the interrupt")
	}
}

func TestShellNeedsACommandString(t *testing.T) {
	t.Parallel()
	tools := newTools(t.TempDir(), ShellTool)
	for _, args := range []map[string]any{{"command": 5}, {"command": nil}} {
		if got := run(t, tools, ShellTool, args); got != "error: argument command must be a string" {
			t.Errorf("%v: %q", args, got)
		}
	}
	// An empty command is not usable.
	if got := run(t, tools, ShellTool, map[string]any{"command": ""}); got != "error: supply exactly one of command or handle" {
		t.Errorf("empty command: %q", got)
	}
}

func TestShellResultNeedsCutWhenLong(t *testing.T) {
	t.Parallel()
	tools := newTools(t.TempDir(), ShellTool)
	out, err := tools.Run(ShellTool, map[string]any{"command": "head -c 40000 /dev/zero | tr '\\0' x"})
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Text) < 40_000 {
		t.Fatalf("run result is %d bytes: tools return the whole output, callers cut", len(out.Text))
	}
	cut := out.Cut()
	if len(cut.Text) > 16_384 || !strings.HasPrefix(cut.Text, "exit status: 0\n\n[... ") || !strings.Contains(cut.Text, " bytes omitted ...]\n") {
		t.Errorf("cut %d bytes: %.60q", len(cut.Text), cut.Text)
	}
}

func TestToolsRefuseNamesThatAreNotEnabled(t *testing.T) {
	t.Parallel()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tools := newTools(root, ReadFileTool)
	os.WriteFile(filepath.Join(root, "a"), []byte("x\n"), 0o644)
	for _, name := range []string{ShellTool, WriteFileTool, ListFilesTool, SearchTextTool, ViewImageTool, ProbeTool, "finish", "report_blocker", "submit", "bogus", ""} {
		if got := run(t, tools, name, map[string]any{"command": "touch x", "path": "a", "content": "y", "pattern": "x"}); got != "error: unknown tool "+name {
			t.Errorf("%q: %q", name, got)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "x")); err == nil {
		t.Error("a disabled shell ran")
	}
	if got := run(t, tools, ReadFileTool, map[string]any{"path": "a"}); got != "1\tx" {
		t.Errorf("read_file: %q", got)
	}
	// An enabled name nothing implements (a terminal tool) is also unknown.
	tools.Enabled = append(tools.Enabled, "finish")
	if got := run(t, tools, "finish", nil); got != "error: unknown tool finish" {
		t.Errorf("finish: %q", got)
	}
}

func TestCallRunsTheDecodedFunctionCall(t *testing.T) {
	t.Parallel()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	os.WriteFile(filepath.Join(root, "a"), []byte("1\n2\n"), 0o644)
	tools := newTools(root, ReadFileTool)
	call := Call{Name: "read_file", Arguments: `{"path":"a","start_line":2}`}
	if out, err := tools.Call(call); err != nil || out.Text != "2\t2" {
		t.Errorf("%q %v", out.Text, err)
	}
	call.Arguments = "not json"
	if out, _ := tools.Call(call); out.Text != "error: argument path must be a string" {
		t.Errorf("%q", out.Text)
	}
}

func TestProbeBelongsToTheShaper(t *testing.T) {
	t.Parallel()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tools := newTools(root, ProbeTool)
	if got := run(t, tools, ProbeTool, map[string]any{"command": "true"}); got != "error: probe is not available" {
		t.Errorf("without a probe: %q", got)
	}
	var gotCommand string
	var gotFiles any
	tools.Probe = func(command string, files any) (string, error) {
		gotCommand, gotFiles = command, files
		return "exit status: 0\ntimed_out: false\nwall: 0.1 s\n", nil
	}
	files := []any{map[string]any{"path": "a", "content": "b"}}
	if got := run(t, tools, ProbeTool, map[string]any{"command": "make", "files": files}); !strings.HasPrefix(got, "exit status: 0\n") {
		t.Errorf("%q", got)
	}
	if gotCommand != "make" || len(gotFiles.([]any)) != 1 {
		t.Errorf("probe got %q %v", gotCommand, gotFiles)
	}
	if got := run(t, tools, ProbeTool, map[string]any{"command": 5}); got != "error: argument command must be a string" {
		t.Errorf("invalid command: %q", got)
	}
	failure := errors.New("interrupted")
	tools.Probe = func(string, any) (string, error) { return "", failure }
	if _, err := tools.Run(ProbeTool, map[string]any{"command": "x"}); err != failure {
		t.Errorf("error %v", err)
	}
}

func TestFileErrorsUseErlangsReasonNames(t *testing.T) {
	t.Parallel()
	if os.Geteuid() == 0 {
		t.Skip("root ignores file permissions")
	}
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tools := newTools(root, ReadFileTool, WriteFileTool)
	os.WriteFile(filepath.Join(root, "secret"), []byte("x"), 0o000)
	os.Mkdir(filepath.Join(root, "ro"), 0o555)
	t.Cleanup(func() { os.Chmod(filepath.Join(root, "ro"), 0o755) })
	os.Mkdir(filepath.Join(root, "closed"), 0o000)
	t.Cleanup(func() { os.Chmod(filepath.Join(root, "closed"), 0o755) })

	for _, c := range []struct {
		tool string
		args map[string]any
		want string
	}{
		{ReadFileTool, map[string]any{"path": "secret"}, "error: secret: eacces"},
		{ReadFileTool, map[string]any{"path": "closed/x"}, "error: closed/x: eacces"},
		{WriteFileTool, map[string]any{"path": "ro/x", "content": "y"}, "error: ro/x: eacces"},
		{WriteFileTool, map[string]any{"path": "ro/sub/x", "content": "y"}, "error: ro/sub/x: eacces"},
		{WriteFileTool, map[string]any{"path": "secret", "content": "y"}, "error: secret: eacces"},
		{WriteFileTool, map[string]any{"path": "closed/x", "content": "y"}, "error: closed/x: eacces"},
	} {
		if got := run(t, tools, c.tool, c.args); got != c.want {
			t.Errorf("%s %v: %q, want %q", c.tool, c.args, got, c.want)
		}
	}
}

func TestWriteFileCreatesFoldersAndReplacesContent(t *testing.T) {
	t.Parallel()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tools := newTools(root, ReadFileTool, WriteFileTool)
	for _, content := range []string{"first\n", "second, longer\n", "", "é\x00\xff\n"} {
		if got := run(t, tools, WriteFileTool, map[string]any{"path": "a/b/c.txt", "content": content}); got != "ok" {
			t.Fatalf("%q", got)
		}
		data, err := os.ReadFile(filepath.Join(root, "a/b/c.txt"))
		if err != nil || string(data) != content {
			t.Errorf("file holds %q (%v), want %q", data, err, content)
		}
	}
	st, _ := os.Stat(filepath.Join(root, "a/b"))
	if !st.IsDir() {
		t.Error("folder missing")
	}
	// An existing file keeps its mode.
	os.Chmod(filepath.Join(root, "a/b/c.txt"), 0o755)
	run(t, tools, WriteFileTool, map[string]any{"path": "a/b/c.txt", "content": "x"})
	if st, _ := os.Stat(filepath.Join(root, "a/b/c.txt")); st.Mode().Perm() != 0o755 {
		t.Errorf("mode %v", st.Mode())
	}
}

func TestWriteFileRefusesProtectedPathsHoweverTheyAreSpelled(t *testing.T) {
	t.Parallel()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tools := newTools(root, WriteFileTool)
	tools.Protected = []string{"features/a.feature", ".kogen/project.yaml"}
	os.MkdirAll(filepath.Join(root, "features"), 0o755)
	want := "refused: features/a.feature is part of the approved acceptance baseline"
	for _, path := range []string{"features/a.feature", "./features/a.feature", "features/../features/a.feature", filepath.Join(root, "features/a.feature"), "features//a.feature", "other/../features/a.feature"} {
		if got := run(t, tools, WriteFileTool, map[string]any{"path": path, "content": "x"}); got != want {
			t.Errorf("%q: %q", path, got)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "features/a.feature")); err == nil {
		t.Error("a protected file was written")
	}
	if got := run(t, tools, WriteFileTool, map[string]any{"path": "features/b.feature", "content": "x"}); got != "ok" {
		t.Errorf("neighbour: %q", got)
	}
	// Only the exact path: neither a prefix nor a case variant is protected.
	for _, path := range []string{"features/a.feature2", "Features/a.feature", "features/a.feature/x"} {
		if got := run(t, tools, WriteFileTool, map[string]any{"path": path, "content": "x"}); strings.HasPrefix(got, "refused") {
			t.Errorf("%q refused: %q", path, got)
		}
	}
}

// Serial: this test changes the parent process HOME.
func TestTildeIsNotTheHomeFolderForReads(t *testing.T) {
	home, _ := filepath.EvalSymlinks(t.TempDir())
	t.Setenv("HOME", home)
	os.WriteFile(filepath.Join(home, "note.txt"), []byte("home\n"), 0o644)
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tools := newTools(root, ReadFileTool)
	for _, path := range []string{"~/note.txt", "~"} {
		got := run(t, tools, ReadFileTool, map[string]any{"path": path})
		if got != "error: "+path+": "+string(errHome) {
			t.Errorf("%s: %q", path, got)
		}
	}
	// Only a bare ~ or ~/ is the home folder; ~note.txt is an ordinary name.
	if got := run(t, tools, ReadFileTool, map[string]any{"path": "~note.txt"}); got != "error: ~note.txt does not exist" {
		t.Errorf("%q", got)
	}
}

func TestNumberedWindows(t *testing.T) {
	t.Parallel()
	text := "a\nb\nc\n"
	for _, c := range []struct {
		text     string
		from, to any
		want     string
	}{
		{text, nil, nil, "1\ta\n2\tb\n3\tc"},
		{text, int64(2), nil, "2\tb\n3\tc"},
		{text, nil, int64(2), "1\ta\n2\tb"},
		{text, int64(2), int64(2), "2\tb"},
		{text, int64(3), int64(1), "3\tc"},
		{text, int64(0), int64(0), "1\ta\n2\tb\n3\tc"},
		{text, int64(-5), int64(-5), "1\ta\n2\tb\n3\tc"},
		{text, 2.0, 2.0, "1\ta\n2\tb\n3\tc"},
		{text, "2", "2", "1\ta\n2\tb\n3\tc"},
		{text, int64(4), nil, ""},
		{text, nil, int64(100), "1\ta\n2\tb\n3\tc"},
		{"", nil, nil, ""},
		{"\n", nil, nil, "1\t"},
		{"\n\n", nil, nil, "1\t\n2\t"},
		{"x", nil, nil, "1\tx"},
		{"x\n\n", nil, nil, "1\tx\n2\t"},
		{"a\r\nb\r\n", nil, nil, "1\ta\r\n2\tb\r"},
	} {
		if got := numbered(c.text, c.from, c.to); got != c.want {
			t.Errorf("numbered(%q, %v, %v) = %q, want %q", c.text, c.from, c.to, got, c.want)
		}
	}
}

func TestRelativeTo(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ abs, root, want string }{
		{"/r/a/b", "/r", "a/b"},
		{"/r", "/r", "."},
		{"/rx/a", "/r", "/rx/a"},
		{"/other/a", "/r", "/other/a"},
		{"/a", "/", "a"},
		{"/", "/", "."},
		{"/r/a", "/r/", "a"},
	} {
		if got := relativeTo(c.abs, c.root); got != c.want {
			t.Errorf("relativeTo(%q, %q) = %q, want %q", c.abs, c.root, got, c.want)
		}
	}
}

func TestExpandNormalisesWithoutResolvingLinks(t *testing.T) {
	t.Parallel()
	for _, c := range []struct{ path, want string }{
		{"a/b", "/r/a/b"},
		{"./a/../b", "/r/b"},
		{"../x", "/x"},
		{"", "/r"},
		{".", "/r"},
		{"/abs//x/", "/abs/x"},
		{"a/", "/r/a"},
	} {
		if got := expand(c.path, "/r"); got != c.want {
			t.Errorf("expand(%q) = %q, want %q", c.path, got, c.want)
		}
	}
}

func TestListAndSearchOutsideARepositoryAreErrors(t *testing.T) {
	t.Parallel()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tools := newTools(root, ListFilesTool, SearchTextTool)
	for _, c := range []struct {
		tool string
		args map[string]any
	}{{ListFilesTool, nil}, {SearchTextTool, map[string]any{"pattern": "x"}}} {
		if got := run(t, tools, c.tool, c.args); !strings.HasPrefix(got, "error: fatal: not a git repository") {
			t.Errorf("%s: %q", c.tool, got)
		}
	}
}

func TestListAndSearchUseTheRepoGiven(t *testing.T) {
	t.Parallel()
	_, root := newRepo(t)
	write(t, root, "a.txt", "needle\n")
	write(t, root, "b/c.txt", "needle\n")
	commitAll(t, root)
	tools := &Tools{Root: root, Enabled: []string{ListFilesTool, SearchTextTool}, Repo: newRunner(root, hermeticEnv())}
	if got := run(t, tools, ListFilesTool, nil); got != "a.txt\nb/c.txt" {
		t.Errorf("list: %q", got)
	}
	if got := run(t, tools, SearchTextTool, map[string]any{"pattern": "needle", "path": "b"}); got != "b/c.txt:1:needle" {
		t.Errorf("search: %q", got)
	}
	// Untracked files are listed and searched; ignored ones are not.
	write(t, root, ".gitignore", "*.log\n")
	write(t, root, "new.txt", "needle\n")
	write(t, root, "x.log", "needle\n")
	if got := run(t, tools, ListFilesTool, nil); strings.Contains(got, "x.log") || !strings.Contains(got, "new.txt") {
		t.Errorf("list: %q", got)
	}
	if got := run(t, tools, SearchTextTool, map[string]any{"pattern": "needle"}); strings.Contains(got, "x.log") || !strings.Contains(got, "new.txt:1:needle") {
		t.Errorf("search: %q", got)
	}
	if got := run(t, tools, ListFilesTool, map[string]any{"path": "nothing-here"}); got != "(no files)" {
		t.Errorf("list: %q", got)
	}
}

func TestReasonNames(t *testing.T) {
	t.Parallel()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	os.WriteFile(filepath.Join(root, "f"), nil, 0o644)
	_, err := os.ReadDir(filepath.Join(root, "f"))
	if got := reason(err); got != "enotdir" {
		t.Errorf("reason = %q", got)
	}
	if got := reason(errors.New("odd")); got != "odd" {
		t.Errorf("reason = %q", got)
	}
}

func TestReadFileLineRangeFeedback(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for name, content := range map[string]string{"a.txt": "one\ntwo\nthree\n", "e.txt": ""} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	tl := &Tools{Root: root, Enabled: []string{ReadFileTool}}
	for _, c := range []struct {
		args, text, kind, class string
	}{
		{`{"path":"a.txt","start_line":99}`, "(start_line 99 is past the end of a.txt; line count: 3)", "", ""},
		{`{"path":"a.txt","start_line":4}`, "(start_line 4 is past the end of a.txt; line count: 3)", "", ""},
		{`{"path":"a.txt","start_line":3}`, "3\tthree", "", ""},
		{`{"path":"e.txt","start_line":1}`, "(start_line 1 is past the end of e.txt; line count: 0)", "", ""},
		{`{"path":"e.txt","start_line":0}`, "(start_line 1 is past the end of e.txt; line count: 0)", "", ""},
		{`{"path":"e.txt"}`, "", "", ""},
		{`{"path":"e.txt","end_line":5}`, "", "", ""},
		{`{"path":"a.txt","start_line":"2"}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":2.5}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":2.0}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":1e2}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":null}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":true}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":[1]}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","end_line":{}}`, "error: argument end_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","end_line":2.5}`, "error: argument end_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":"x","end_line":"y"}`, "error: argument start_line must be an integer", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":1e999}`, "error: argument start_line is a number too large to represent", "", "wrong_argument_type"},
		{`{"path":"a.txt","end_line":-1e999}`, "error: argument end_line is a number too large to represent", "", "wrong_argument_type"},
		{`{"path":3,"start_line":1e999}`, "error: argument path must be a string", "", "wrong_argument_type"},
		{`{"path":"a.txt","start_line":3,"end_line":1}`, "error: end_line 1 is before start_line 3", "", "conflicting_arguments"},
		{`{"path":"a.txt","end_line":0}`, "error: end_line 0 is before start_line 1", "", "conflicting_arguments"},
		{`{"path":"a.txt","start_line":-4,"end_line":-5}`, "error: end_line -5 is before start_line 1", "", "conflicting_arguments"},
		{`{"path":"a.txt","start_line":99999999999999999999,"end_line":5}`, "error: end_line 5 is before start_line 9223372036854775807", "", "conflicting_arguments"},
		{`{"path":"missing.txt","start_line":3,"end_line":1}`, "error: end_line 1 is before start_line 3", "", "conflicting_arguments"},
		{`{"path":"missing.txt","start_line":2}`, "error: missing.txt does not exist", "not_found", ""},
		{`{"path":"a.txt","start_line":2,"end_line":2}`, "2\ttwo", "", ""},
		{`{"path":"a.txt","start_line":2,"end_line":99}`, "2\ttwo\n3\tthree", "", ""},
		{`{"path":"a.txt","start_line":-3}`, "1\tone\n2\ttwo\n3\tthree", "", ""},
	} {
		got, err := tl.CallClassified(context.Background(), Call{Name: ReadFileTool, Arguments: c.args})
		if err != nil {
			t.Fatalf("%s: %v", c.args, err)
		}
		if got.Text != c.text || got.ErrorKind != c.kind || got.MalformedClass != c.class {
			t.Errorf("%s = %q kind %q class %q, want %q %q %q", c.args, got.Text, got.ErrorKind, got.MalformedClass, c.text, c.kind, c.class)
		}
	}
}
