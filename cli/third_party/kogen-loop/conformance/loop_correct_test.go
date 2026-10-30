package conformance

// Regression tests of the loopCorrect audit (LC-02, LC-03, LC-04): a failed write_file keeps
// the previous bytes, a Responses refusal is part of the round's claim, and a request
// without a Session is a clear error. Temporary directories only; the one child process is
// started, and signalled by no one, by the test.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"

	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

const (
	lcChildEnv   = "KOGEN_LOOP_CORRECT_CHILD_ROOT"
	lcFileLimit  = 4096
	lcReplaceLen = 65536
	lcRefusal    = "I cannot perform that request."
)

func lcTools(root string, protected ...string) *tools.Tools {
	return &tools.Tools{Root: root, Enabled: []string{tools.ReadFileTool, tools.WriteFileTool}, Protected: protected}
}

func lcWrite(t *testing.T, tl *tools.Tools, path, content string) string {
	t.Helper()
	out, err := tl.RunContext(context.Background(), tools.WriteFileTool, map[string]any{"path": path, "content": content})
	if err != nil {
		t.Fatal(err)
	}
	return out.Text
}

// lcFailedWriteChild is the isolated child of TestLoopCorrectFailedWrite: its file size
// limit is 4096 bytes and SIGXFSZ is ignored, so a 65536-byte write stores a part of the
// bytes and then fails with EFBIG.
func lcFailedWriteChild(root string) {
	signal.Ignore(syscall.SIGXFSZ)
	lim := &syscall.Rlimit{Cur: lcFileLimit, Max: lcFileLimit}
	if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, lim); err != nil {
		os.Stdout.WriteString("setrlimit: " + err.Error())
		os.Exit(3)
	}
	out, err := lcTools(root).RunContext(context.Background(), tools.WriteFileTool, map[string]any{
		"path": "src/config.go", "content": strings.Repeat("x", lcReplaceLen),
	})
	if err != nil {
		os.Stdout.WriteString("error: " + err.Error())
		os.Exit(4)
	}
	os.Stdout.WriteString(out.Text)
	os.Exit(0)
}

func TestLoopCorrectFailedWrite(t *testing.T) {
	if root := os.Getenv(lcChildEnv); root != "" {
		lcFailedWriteChild(root)
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	var preimage bytes.Buffer
	for i := 0; i < 100; i++ {
		preimage.WriteString("// uncommitted work " + strconv.Itoa(i) + " \xff\x00\n")
	}
	if preimage.Len() >= lcFileLimit {
		t.Fatal("the preimage must fit below the child's file size limit")
	}
	config := filepath.Join(root, "src", "config.go")
	if err := os.WriteFile(config, preimage.Bytes(), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(config, 0o640); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command(os.Args[0], "-test.run=^TestLoopCorrectFailedWrite$", "-test.count=1")
	cmd.Env = append(os.Environ(), lcChildEnv+"="+root)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		t.Fatalf("the child failed: %v\nstdout: %s\nstderr: %s", err, out.String(), errOut.String())
	}
	if got, want := out.String(), "error: src/config.go: efbig"; got != want {
		t.Errorf("the failed write returned %q, want %q", got, want)
	}
	got, err := os.ReadFile(config)
	if err != nil || !bytes.Equal(got, preimage.Bytes()) {
		t.Errorf("src/config.go holds %d bytes (%v), want its %d-byte preimage unchanged", len(got), err, preimage.Len())
	}
	if st, err := os.Stat(config); err != nil || st.Mode().Perm() != 0o640 {
		t.Errorf("src/config.go: %v, %v; want mode 0640", st, err)
	}
	entries, err := os.ReadDir(filepath.Join(root, "src"))
	if err != nil || len(entries) != 1 || entries[0].Name() != "config.go" {
		t.Errorf("src holds %v (%v), want only config.go: a temporary replacement leaked", entries, err)
	}
}

func TestLoopCorrectCompatibility(t *testing.T) {
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tl := lcTools(root, "protected.txt")
	readAll := func(path string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}

	// Creation: folders are made and the mode is what 0666 and the umask give.
	if got := lcWrite(t, tl, "new/dir/a.txt", "first\n"); got != "ok" {
		t.Fatalf("creation: %q", got)
	}
	ref := filepath.Join(root, "umask-reference")
	f, err := os.OpenFile(ref, os.O_CREATE|os.O_WRONLY, 0o666)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	refStat, _ := os.Stat(ref)
	if st, _ := os.Stat(filepath.Join(root, "new/dir/a.txt")); st.Mode().Perm() != refStat.Mode().Perm() {
		t.Errorf("created mode %v, want %v", st.Mode().Perm(), refStat.Mode().Perm())
	}
	// Replacement keeps the mode and takes the bytes, including empty and binary ones.
	if err := os.Chmod(filepath.Join(root, "new/dir/a.txt"), 0o751); err != nil {
		t.Fatal(err)
	}
	for _, content := range []string{"second, longer\n", "", "é\x00\xff\n"} {
		if got := lcWrite(t, tl, "new/dir/a.txt", content); got != "ok" || readAll("new/dir/a.txt") != content {
			t.Errorf("replacement with %q: %q, file %q", content, got, readAll("new/dir/a.txt"))
		}
	}
	if st, _ := os.Stat(filepath.Join(root, "new/dir/a.txt")); st.Mode().Perm() != 0o751 {
		t.Errorf("replaced mode %v, want 0751", st.Mode().Perm())
	}

	// A protected path is refused and not touched.
	if got, want := lcWrite(t, tl, "protected.txt", "x"), "refused: protected.txt is part of the approved acceptance baseline"; got != want {
		t.Errorf("protected: %q", got)
	}
	if _, err := os.Stat(filepath.Join(root, "protected.txt")); err == nil {
		t.Error("a protected file was created")
	}

	// A symlink stays a link: its target is replaced, however it is reached.
	os.WriteFile(filepath.Join(root, "target.txt"), []byte("old\n"), 0o600)
	os.Symlink("target.txt", filepath.Join(root, "link.txt"))
	os.Symlink(filepath.Join(root, "link.txt"), filepath.Join(root, "link2.txt"))
	for _, name := range []string{"link.txt", "link2.txt"} {
		if got := lcWrite(t, tl, name, "via "+name); got != "ok" {
			t.Errorf("%s: %q", name, got)
		}
		if st, err := os.Lstat(filepath.Join(root, name)); err != nil || st.Mode()&os.ModeSymlink == 0 {
			t.Errorf("%s is no longer a link: %v, %v", name, st, err)
		}
		if got := readAll("target.txt"); got != "via "+name {
			t.Errorf("target holds %q after writing %s", got, name)
		}
	}
	if st, _ := os.Stat(filepath.Join(root, "target.txt")); st.Mode().Perm() != 0o600 {
		t.Errorf("target mode %v, want 0600", st.Mode().Perm())
	}
	// Resolve .. after an intermediate symlink, as the filesystem does.
	os.MkdirAll(filepath.Join(root, "physical", "sub"), 0o755)
	os.WriteFile(filepath.Join(root, "physical", "dest"), []byte("physical"), 0o600)
	os.WriteFile(filepath.Join(root, "dest"), []byte("root"), 0o600)
	os.Symlink("physical/sub", filepath.Join(root, "intermediate"))
	os.Symlink("intermediate/../dest", filepath.Join(root, "complex-link"))
	if got := lcWrite(t, tl, "complex-link", "updated"); got != "ok" || readAll("physical/dest") != "updated" || readAll("dest") != "root" {
		t.Errorf("symlink with intermediate ..: %q, physical %q, root %q", got, readAll("physical/dest"), readAll("dest"))
	}
	// A dangling link creates its target.
	os.Symlink("made-by-link.txt", filepath.Join(root, "dangling.txt"))
	if got := lcWrite(t, tl, "dangling.txt", "made"); got != "ok" || readAll("made-by-link.txt") != "made" {
		t.Errorf("dangling link: %q", got)
	}

	// Nonregular targets are refused without a change.
	os.Mkdir(filepath.Join(root, "folder"), 0o755)
	if got := lcWrite(t, tl, "folder", "x"); got != "error: folder: eisdir" {
		t.Errorf("folder: %q", got)
	}
	if err := syscall.Mkfifo(filepath.Join(root, "fifo"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := lcWrite(t, tl, "fifo", "x"); !strings.HasPrefix(got, "error: fifo: ") {
		t.Errorf("fifo: %q", got)
	}
	if st, _ := os.Lstat(filepath.Join(root, "fifo")); st.Mode()&os.ModeNamedPipe == 0 {
		t.Error("the fifo was replaced")
	}

	// A read-only file is not replaced because its folder is writable.
	if os.Geteuid() != 0 {
		os.WriteFile(filepath.Join(root, "readonly.txt"), []byte("keep"), 0o444)
		if got := lcWrite(t, tl, "readonly.txt", "x"); got != "error: readonly.txt: eacces" || readAll("readonly.txt") != "keep" {
			t.Errorf("read-only file: %q, holds %q", got, readAll("readonly.txt"))
		}
	}

	// A hardlink alias keeps its preimage: replacement changes the inode, not the old one.
	os.WriteFile(filepath.Join(root, "hard.txt"), []byte("one"), 0o644)
	if err := os.Link(filepath.Join(root, "hard.txt"), filepath.Join(root, "alias.txt")); err != nil {
		t.Fatal(err)
	}
	if got := lcWrite(t, tl, "hard.txt", "two"); got != "ok" || readAll("hard.txt") != "two" || readAll("alias.txt") != "one" {
		t.Errorf("hardlink: %q, hard %q, alias %q", got, readAll("hard.txt"), readAll("alias.txt"))
	}

	// Nothing but the files above remains: no temporary replacement.
	filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if strings.Contains(d.Name(), ".kogen-write-") {
			t.Errorf("leaked temporary replacement %s", path)
		}
		return nil
	})
}

// lcRefusalMessage is a Responses assistant message made of the given content parts.
func lcRefusalMessage(parts ...map[string]any) map[string]any {
	content := make([]any, len(parts))
	for i, p := range parts {
		content[i] = p
	}
	return map[string]any{"type": "message", "id": "msg-fixture", "role": "assistant", "content": content}
}

func lcText(text string) map[string]any {
	return map[string]any{"type": "output_text", "text": text, "annotations": []any{}}
}

func lcRefuse(text string) map[string]any { return map[string]any{"type": "refusal", "refusal": text} }

// lcEndedClaim runs the answer through the built CLI (no session.dir) and returns the one
// round.ended event after checking the ending was a normal, unverified model claim.
func lcEndedClaim(t *testing.T, answer map[string]any) map[string]any {
	t.Helper()
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{answer}, Usage: fullUsage(10, 0, 5, 0)}})
	r := runCLI(t, w, f, w.task(nil))
	if r.exit != 0 {
		t.Fatalf("exit %d, want 0 (stderr: %s)", r.exit, r.stderr)
	}
	if got := len(f.requests()); got != 1 {
		t.Errorf("the provider saw %d requests, want 1", got)
	}
	ended := r.all("round.ended")
	if len(ended) != 1 {
		t.Fatalf("%d round.ended events in %v", len(ended), r.types())
	}
	ev := ended[0]
	if ev["ending"] != "no_call" || ev["terminal_tool"] != nil {
		t.Errorf("ending %v, terminal_tool %v; want an ended model claim without a terminal call", ev["ending"], ev["terminal_tool"])
	}
	for key := range ev {
		if strings.Contains(key, "verified") || strings.Contains(key, "complete") {
			t.Errorf("round.ended asserts completion with %q", key)
		}
	}
	if end := r.first("session.ended"); end["exit"] != float64(0) {
		t.Errorf("session.ended %v", end)
	}
	return ev
}

// lcReplayed runs the answer through the library over the same fake and returns the
// response items and the conversation the round keeps (the replay).
func lcReplayed(t *testing.T, answer map[string]any) (items []map[string]any, input []any) {
	t.Helper()
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{answer}}})
	rd := roundWith(t, w)
	rd.Role = provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"}
	res, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, direct(t, w, f), loop.Hooks{})
	if err != nil {
		t.Fatal(err)
	}
	if res.Ending != loop.EndNoCall {
		t.Fatalf("ending %v", res.Ending)
	}
	return res.Response.Items, res.Input
}

// lcWire is v as the JSON the provider sent, for an exact comparison.
func lcWire(t *testing.T, v any) any {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestLoopCorrectRefusal(t *testing.T) {
	answer := lcRefusalMessage(lcRefuse(lcRefusal))
	ev := lcEndedClaim(t, answer)
	if ev["claim"] != lcRefusal {
		t.Errorf("claim %q, want %q", ev["claim"], lcRefusal)
	}
	items, input := lcReplayed(t, answer)
	if len(items) != 1 || !reflect.DeepEqual(lcWire(t, items[0]), lcWire(t, answer)) {
		t.Errorf("response items %v, want the received message %v", items, answer)
	}
	last, _ := input[len(input)-1].(map[string]any)
	if last == nil || !reflect.DeepEqual(lcWire(t, last["content"]), []any{map[string]any{"type": "refusal", "refusal": lcRefusal}}) {
		t.Errorf("the replayed conversation ends with %v, want the retained refusal", input[len(input)-1])
	}
}

func TestLoopCorrectMixed(t *testing.T) {
	answer := lcRefusalMessage(lcText("Before"), lcRefuse(lcRefusal), lcText("After"))
	ev := lcEndedClaim(t, answer)
	if want := "Before\n" + lcRefusal + "\nAfter"; ev["claim"] != want {
		t.Errorf("claim %q, want %q", ev["claim"], want)
	}
	items, input := lcReplayed(t, answer)
	if len(items) != 1 || !reflect.DeepEqual(lcWire(t, items[0]), lcWire(t, answer)) {
		t.Errorf("response items %v, want the received message %v", items, answer)
	}
	last, _ := input[len(input)-1].(map[string]any)
	want := []any{
		map[string]any{"type": "output_text", "text": "Before"},
		map[string]any{"type": "refusal", "refusal": lcRefusal},
		map[string]any{"type": "output_text", "text": "After"},
	}
	if last == nil || !reflect.DeepEqual(lcWire(t, last["content"]), want) {
		t.Errorf("the replayed conversation ends with %v, want the three parts in order", input[len(input)-1])
	}
}

// lcCounting counts transport attempts and answers none of them.
type lcCounting struct{ n atomic.Int32 }

func (c *lcCounting) RoundTrip(*http.Request) (*http.Response, error) {
	c.n.Add(1)
	return nil, errors.New("transport must not be used")
}

func TestLoopCorrectMissingSession(t *testing.T) {
	transport := &lcCounting{}
	client := provider.NewClient("host")
	client.HTTP = &http.Client{Transport: transport}
	roles := map[string]provider.Role{
		"unprofiled": {Provider: "chatgpt", Model: "fixture-model", Effort: "medium"},
		"profiled":   {Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "medium"},
	}
	if provider.ResolveProfile(roles["profiled"]) == nil || provider.ResolveProfile(roles["unprofiled"]) != nil {
		t.Fatal("the roles are not one profiled and one unprofiled")
	}
	check := func(name string, resp *provider.Response, err error) {
		t.Helper()
		var se *sys.Error
		if !errors.As(err, &se) || se.Class != "validation" || se.Reason != "missing_session" || se.Detail != "Session is required" {
			t.Errorf("%s: error %#v, want validation/missing_session: Session is required", name, err)
		}
		if err != nil && err.Error() != "validation/missing_session: Session is required" {
			t.Errorf("%s: message %q", name, err.Error())
		}
		if resp != nil {
			t.Errorf("%s: response %v, want nil", name, resp)
		}
	}
	for name, role := range roles {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("%s: panic %v", name, r)
				}
			}()
			input := []any{userMessage("small request")}
			d := &loop.Direct{Client: client, Cache: client.Cache, CacheID: provider.NewCacheID()}
			resp, sent, err := d.Request(context.Background(), loop.Request{Role: role, Input: input})
			check("Direct.Request "+name, resp, err)
			if sent != nil {
				t.Errorf("Direct.Request %s: sent %v, want nil", name, sent)
			}
			resp, err = client.Respond(context.Background(), nil, provider.Request{Role: role, Input: input, Context: map[string]any{"role": "build"}}, nil)
			check("Client.Respond "+name, resp, err)
			// Classification of a profiled request is no panic either.
			provider.Classify(provider.Request{Role: role, Input: input}, nil)
		}()
	}
	if n := transport.n.Load(); n != 0 {
		t.Errorf("%d transport calls, want 0", n)
	}
}
