package build

import (
	"strings"
	"testing"
)

// A native shell call that writes nothing for a while is answered by the vendored tool with its
// ordinary result (LOOP-5): no stop, no command_no_progress event.
const silentCommand = "sleep 2; printf 'done\\n'"

func TestSilentBuildShellNotStopped(t *testing.T) {
	e := newEnv(t)
	e.prov.then(
		e.prov.calls("shell", map[string]any{"command": silentCommand}),
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
	eq(t, "result", strings.Join(toolOutputsOf(reqs[1]), "|"), "exit status: 0\ndone\n")
	if stops := eventsNamed(e.events(e.onlyRun()), "command_no_progress"); len(stops) != 0 {
		t.Fatalf("command_no_progress events %v", stops)
	}
}

func TestSilentReviewShellNotStopped(t *testing.T) {
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	f.then(f.calls("shell", map[string]any{"command": silentCommand}), submit(f, "approve"))
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
	eq(t, "result", strings.Join(toolOutputsOf(reqs[1]), "|"), "exit status: 0\ndone\n")
	if stops := eventsNamed(e.events(e.onlyRun()), "command_no_progress"); len(stops) != 0 {
		t.Fatalf("command_no_progress events %v", stops)
	}
}
