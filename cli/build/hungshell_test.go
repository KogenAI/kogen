package build

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/executor"
	"kogen/executor/conformance"
)

// shortenShellSilence sets the fixed silence bound for one test and restores it. Such tests
// cannot run in parallel.
func shortenShellSilence(t *testing.T, d time.Duration) {
	t.Helper()
	old := shellSilence
	shellSilence = d
	t.Cleanup(func() { shellSilence = old })
}

// hungCommand starts, announces itself, records its process ID and then blocks on a FIFO
// nothing ever opens for writing.
func hungCommand(t *testing.T) (command, pidFile string) {
	t.Helper()
	dir := physical(t, t.TempDir())
	fifo := filepath.Join(dir, "never.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	pidFile = filepath.Join(dir, "hung.pid")
	return fmt.Sprintf("printf 'started\\n'; echo $$ > '%s'; read line < '%s'", pidFile, fifo), pidFile
}

func requireGone(t *testing.T, pidFile string) {
	t.Helper()
	b, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	var pid int
	if _, err := fmt.Sscan(string(b), &pid); err != nil || pid <= 0 {
		t.Fatalf("pid file %q", b)
	}
	if err := syscall.Kill(pid, 0); err != syscall.ESRCH {
		t.Fatalf("process %d still exists (kill 0: %v)", pid, err)
	}
}

func stoppedText(bound, command, output string) string {
	return "no output for " + bound + "; Kogen stopped the command and its process group: " + command + "\n" + output
}

func eventIndex(events []map[string]any, name string, match func(map[string]any) bool) int {
	for i, ev := range events {
		if ev["event"] == name && (match == nil || match(ev)) {
			return i
		}
	}
	return -1
}

func TestHungShellStoppedBuildLands(t *testing.T) {
	shortenShellSilence(t, 500*time.Millisecond)
	e := newEnv(t)
	c, pidFile := hungCommand(t)
	e.prov.then(
		e.prov.calls("shell", map[string]any{"command": c}),
		e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}),
	)
	start := e.head()
	a := e.build()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s\n%s", a.exit, a.err, a.out, a.errs)
	}
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	reqs := e.prov.requests()
	if len(reqs) != 2 {
		t.Fatalf("%d requests", len(reqs))
	}
	eq(t, "result", strings.Join(toolOutputsOf(reqs[1]), "|"), stoppedText("500ms", c, "started\n"))

	events := e.events(e.onlyRun())
	stops := eventsNamed(events, "command_no_progress")
	if len(stops) != 1 {
		t.Fatalf("command_no_progress events %v", stops)
	}
	want := map[string]any{"event": "command_no_progress", "owner": "build", "name": "shell", "command": c, "rule": "no_output", "after_ms": float64(500)}
	for k, v := range want {
		eq(t, k, stops[0][k], v)
	}
	stop := eventIndex(events, "command_no_progress", nil)
	call := eventIndex(events, "tool_call", func(ev map[string]any) bool { return ev["name"] == "shell" })
	if stop < 0 || call < 0 || stop > call {
		t.Fatalf("command_no_progress at %d, shell tool_call at %d", stop, call)
	}
	contains(t, "stderr", a.errs.String(), "kogen: "+stoppedText("500ms", c, ""))
	requireGone(t, pidFile)
}

func TestProgressingShellNotStopped(t *testing.T) {
	shortenShellSilence(t, 2*time.Second)
	root := conformance.NewCheckout(t)
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	prov := newFakeProvider(t)
	const p = `i=0; while [ $i -lt 15 ]; do echo line-$i; sleep 0.2; i=$((i+1)); done`
	prov.then(
		respondWith([]map[string]any{prov.call("shell", map[string]any{"command": p})}, nil),
		respondWith([]map[string]any{prov.call("finish", map[string]any{"summary": "done"})}, nil),
	)
	b := newConformanceAttempt(t, root, home, prov, true)
	sess, err := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	began := time.Now()
	if _, err := sess.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	took := time.Since(began)
	var want strings.Builder
	want.WriteString("exit status: 0\n")
	for i := 0; i < 15; i++ {
		fmt.Fprintf(&want, "line-%d\n", i)
	}
	outs := prov.toolOutputs()
	if len(outs) != 1 {
		t.Fatalf("tool outputs %q", outs)
	}
	eq(t, "result", outs[0], want.String())
	if took <= 2*time.Second {
		t.Fatalf("the call took %v; the case is meaningful only past the 2s bound", took)
	}
	log, err := os.ReadFile(b.Run.LogPath)
	if err != nil {
		t.Fatal(err)
	}
	lacks(t, "run log", string(log), "command_no_progress")
}

func TestShellResultBytesUnchanged(t *testing.T) {
	cases := []struct {
		name string
		args func(tmp string) map[string]any
	}{
		{"exit status and combined order", func(string) map[string]any {
			return map[string]any{"command": `printf 'out\n'; printf 'err\n' >&2; printf 'out2\n'; exit 3`}
		}},
		{"syntax error", func(string) map[string]any { return map[string]any{"command": "if then"} }},
		{"foreign kill refusal", func(tmp string) map[string]any {
			return map[string]any{"command": "kill -0 1; touch '" + filepath.Join(tmp, "ran") + "'"}
		}},
		{"non-string command", func(string) map[string]any { return map[string]any{"command": 5} }},
		{"cut", func(string) map[string]any {
			return map[string]any{"command": `head -c 40000 /dev/zero | tr '\0' a`}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tmp := physical(t, t.TempDir())
			args := c.args(tmp)
			root := conformance.NewCheckout(t)
			home := physical(t, t.TempDir())
			seedLogin(t, home)
			prov := newFakeProvider(t)
			prov.then(
				respondWith([]map[string]any{prov.call("shell", args)}, nil),
				respondWith([]map[string]any{prov.call("finish", map[string]any{"summary": "done"})}, nil),
			)
			b := newConformanceAttempt(t, root, home, prov, true)
			sess, err := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := sess.Round(context.Background(), executor.Input{}); err != nil {
				t.Fatal(err)
			}
			outs := prov.toolOutputs()
			if len(outs) != 1 {
				t.Fatalf("tool outputs %q", outs)
			}
			// The vendored tool's own answer, in the same root with the same session.
			oracle, err := (&tools.Tools{Root: root, Session: b.s, Enabled: []string{"shell"}}).Run("shell", args)
			if err != nil {
				t.Fatal(err)
			}
			eq(t, "result", outs[0], oracle.Cut().Text)
			if c.name == "foreign kill refusal" {
				if _, err := os.Stat(filepath.Join(tmp, "ran")); !os.IsNotExist(err) {
					t.Fatalf("the refused command ran: %v", err)
				}
				contains(t, "refusal", outs[0], sys.RefusalText(oracle.Rule))
			}
		})
	}
}

func TestReviewHungShellStopped(t *testing.T) {
	shortenShellSilence(t, 500*time.Millisecond)
	e := newEnv(t)
	f := e.prov
	c, pidFile := hungCommand(t)
	f.then(landScript(f)...)
	f.then(f.calls("shell", map[string]any{"command": c}), submit(f, "approve"))
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s\n%s", a.exit, a.err, a.out, a.errs)
	}
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	reqs := f.reviewRequests()
	if len(reqs) != 2 {
		t.Fatalf("%d review requests", len(reqs))
	}
	eq(t, "result", strings.Join(toolOutputsOf(reqs[1]), "|"), stoppedText("500ms", c, "started\n"))

	events := e.events(e.onlyRun())
	stops := eventsNamed(events, "command_no_progress")
	if len(stops) != 1 {
		t.Fatalf("command_no_progress events %v", stops)
	}
	eq(t, "owner", stops[0]["owner"], any("review"))
	eq(t, "name", stops[0]["name"], any("shell"))
	eq(t, "command", stops[0]["command"], any(c))
	eq(t, "rule", stops[0]["rule"], any("no_output"))
	eq(t, "after_ms", stops[0]["after_ms"], any(float64(500)))
	stop := eventIndex(events, "command_no_progress", nil)
	call := eventIndex(events, "review_tool_call", func(ev map[string]any) bool { return ev["name"] == "shell" })
	if stop < 0 || call < 0 || stop > call {
		t.Fatalf("command_no_progress at %d, review_tool_call at %d", stop, call)
	}
	requireGone(t, pidFile)
}
