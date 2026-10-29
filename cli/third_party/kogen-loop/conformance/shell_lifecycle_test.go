package conformance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	_ "unsafe" // go:linkname

	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// shellStartHook is sys's test-only seam at the shell-start boundary ("enter", "starting",
// "started"). It is nil outside the startup tests, which set it before a round starts and
// clear it after the round has returned.
//
//go:linkname shellStartHook kogen-loop/sys.startHook
var shellStartHook func(stage string)

// ---- owned process observation ----

// owned is a process this test's fixtures created, identified by pid and start time so that a
// reused pid is never mistaken for it.
type owned struct {
	pid int
	id  string
}

// psInfo is the state letter and start time of pid; ok is false when no such process exists.
func psInfo(t *testing.T, pid int) (stat, id string, ok bool) {
	t.Helper()
	out, err := exec.Command("ps", "-o", "stat=,lstart=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 1 {
			return "", "", false
		}
		t.Fatalf("cannot observe process %d: %v", pid, err)
	}
	f := strings.Fields(string(out))
	if len(f) < 2 {
		return "", "", false
	}
	return f[0], strings.Join(f[1:], " "), true
}

// own records the identity of the process whose pid the fixture wrote to path and kills it
// when the test ends, whatever the outcome.
func own(t *testing.T, path string) owned {
	t.Helper()
	pid := readPid(t, path)
	_, id, ok := psInfo(t, pid)
	if !ok {
		t.Fatalf("process %d from %s is not observable", pid, path)
	}
	o := owned{pid, id}
	t.Cleanup(func() {
		if o.live(t) {
			syscall.Kill(o.pid, syscall.SIGKILL)
		}
	})
	return o
}

// live is true while the process exists and is not a zombie.
func (o owned) live(t *testing.T) bool {
	t.Helper()
	stat, id, ok := psInfo(t, o.pid)
	return ok && id == o.id && !strings.HasPrefix(stat, "Z")
}

// waitGone waits up to d for the process to end (a zombie has ended).
func (o owned) waitGone(t *testing.T, d time.Duration) bool {
	t.Helper()
	for deadline := time.Now().Add(d); ; time.Sleep(50 * time.Millisecond) {
		if !o.live(t) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
	}
}

// pidIfWritten is the pid in path when a complete pid line is there, else 0.
func pidIfWritten(path string) int {
	data, err := os.ReadFile(path)
	if err != nil || !strings.HasSuffix(string(data), "\n") {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid
}

// liveMembers are the non-zombie members of the process group pgid.
func liveMembers(t *testing.T, pgid int) []int {
	t.Helper()
	out, err := exec.Command("ps", "-A", "-o", "pid=,pgid=,stat=").Output()
	if err != nil {
		t.Fatalf("cannot enumerate processes: %v", err)
	}
	var pids []int
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		group, e2 := strconv.Atoi(f[1])
		if e1 == nil && e2 == nil && group == pgid && !strings.HasPrefix(f[2], "Z") {
			pids = append(pids, pid)
		}
	}
	return pids
}

// noLiveMembers waits up to d until none of the groups has a live member.
func noLiveMembers(t *testing.T, groups []int, d time.Duration) []int {
	t.Helper()
	var left []int
	for deadline := time.Now().Add(d); ; time.Sleep(50 * time.Millisecond) {
		left = nil
		for _, g := range groups {
			left = append(left, liveMembers(t, g)...)
		}
		if len(left) == 0 || time.Now().After(deadline) {
			return left
		}
	}
}

// ---- fixture commands ----

func shq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// background starts a quiet long-running process in the command's group and records its pid.
func background(dir, name string) string {
	return fmt.Sprintf(`sleep 600 >/dev/null 2>&1 & echo $! > %s`, shq(filepath.Join(dir, name+".pid")))
}

// aliveCheck prints alive or gone for the process recorded by background.
func aliveCheck(dir, name string) string {
	return fmt.Sprintf(`if [ -n "$(ps -o stat= -p "$(cat %s)")" ]; then echo alive; else echo gone; fi`, shq(filepath.Join(dir, name+".pid")))
}

// resistant starts a descendant that ignores SIGTERM; its pid file appears once the trap is set.
func resistant(dir, name string) string {
	return fmt.Sprintf(`sh -c 'trap "" TERM; echo $$ > %s; while :; do sleep 1; done' >/dev/null 2>&1 &`, shq(filepath.Join(dir, name+".pid")))
}

// ---- library rounds with real tools ----

type lifecycleRun struct {
	w    *world
	sess *sys.Session
	rd   loop.Round
}

func newLifecycleRun(t *testing.T) *lifecycleRun {
	t.Helper()
	w := newWorld(t)
	sess := sys.NewWith([]string{"HOME=" + w.home, "PATH=" + os.Getenv("PATH")}, w.root)
	return &lifecycleRun{w: w, sess: sess, rd: loop.Round{
		Owner: "test", Role: provider.Role{Provider: "chatgpt", Model: "m", Effort: "e"},
		Instructions: "inst", Definitions: []any{"def"},
		Tools: &tools.Tools{Root: w.root, Session: sess, Enabled: []string{"shell"}},
	}}
}

func shellItem(id, command string) map[string]any {
	args, _ := json.Marshal(map[string]any{"command": command})
	return fakeCall(id, "shell", string(args))
}

// preRound starts a group before the round, as an ownership control, and returns the
// process it left and the session's groups at that point. The caller cleans it up.
func (l *lifecycleRun) preRound(t *testing.T) (owned, []int) {
	t.Helper()
	res, err := l.sess.Run(background(l.w.root, "pre"), l.w.root, sys.Options{})
	if err != nil || res.Status != 0 {
		t.Fatalf("pre-round setup: %+v %v", res, err)
	}
	pre := own(t, filepath.Join(l.w.root, "pre.pid"))
	groups := l.sess.Groups()
	t.Cleanup(func() { sys.Terminate(groups) })
	return pre, groups
}

// unrelatedHost starts a process of the host outside every session group.
func unrelatedHost(t *testing.T) owned {
	t.Helper()
	cmd := exec.Command("sleep", "600")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	_, id, ok := psInfo(t, cmd.Process.Pid)
	if !ok {
		t.Fatal("unrelated process is not observable")
	}
	return owned{cmd.Process.Pid, id}
}

// Successful runs stop their background shells only at the end of the run.
func TestShellLifecycleSuccessCleanup(t *testing.T) {
	for _, ending := range []string{"no_call", "terminal"} {
		t.Run(ending, func(t *testing.T) {
			l := newLifecycleRun(t)
			pre, _ := l.preRound(t)
			host := unrelatedHost(t)
			last := message("done")
			if ending == "terminal" {
				last = fakeCall("c3", "finish", `{"summary":"s"}`)
			}
			rq := &scripted{responses: []*provider.Response{
				respond("r1", shellItem("c1", background(l.w.root, "bg"))),
				respond("r2", shellItem("c2", aliveCheck(l.w.root, "bg"))),
				respond("r3", last),
			}}
			var bg owned
			hooks := loop.Hooks{AfterCall: func(_ context.Context, c tools.Call, out tools.Output, _ bool, _ []any) error {
				switch c.CallID() {
				case "c1":
					bg = own(t, filepath.Join(l.w.root, "bg.pid"))
				case "c2":
					if !bg.live(t) || out.Text != "exit status: 0\nalive\n" {
						t.Errorf("the background process did not survive between calls: %q", out.Text)
					}
				}
				return nil
			}}
			res, err := loop.Run(context.Background(), l.rd, []any{userMessage("go")}, rq, hooks)
			if err != nil || (ending == "no_call") != (res.Ending == loop.EndNoCall) {
				t.Fatalf("%+v %v", res, err)
			}
			if !bg.waitGone(t, 10*time.Second) {
				t.Error("the background process outlived a successful run")
			}
			if !pre.live(t) || !host.live(t) {
				t.Error("a process the round did not start was stopped")
			}
		})
	}
}

// A round without an explicitly supplied session still owns its shell groups.
func TestShellLifecycleImplicitSessionCleanup(t *testing.T) {
	l := newLifecycleRun(t)
	l.rd.Tools.Session = nil
	rq := &scripted{responses: []*provider.Response{
		respond("r1", shellItem("c1", background(l.w.root, "implicit"))),
		respond("r2", message("done")),
	}}
	var bg owned
	hooks := loop.Hooks{AfterCall: func(_ context.Context, c tools.Call, _ tools.Output, _ bool, _ []any) error {
		if c.CallID() == "c1" {
			bg = own(t, filepath.Join(l.w.root, "implicit.pid"))
		}
		return nil
	}}
	if _, err := loop.Run(context.Background(), l.rd, nil, rq, hooks); err != nil {
		t.Fatal(err)
	}
	if !bg.waitGone(t, 10*time.Second) {
		t.Error("implicit session background survived round")
	}
}

// Ordinary failures stop their background shells and return the error unchanged.
func TestShellLifecycleFailureCleanup(t *testing.T) {
	sentinel := errors.New("ordinary failure")
	for _, source := range []string{"requester", "hook"} {
		t.Run(source, func(t *testing.T) {
			l := newLifecycleRun(t)
			pre, _ := l.preRound(t)
			host := unrelatedHost(t)
			script := []*provider.Response{
				respond("r1", shellItem("c1", background(l.w.root, "bg"))),
				respond("r2", shellItem("c2", aliveCheck(l.w.root, "bg"))),
			}
			var rq loop.Requester = &failingAfter{scripted: scripted{responses: script}, err: sentinel}
			if source == "hook" {
				rq = &scripted{responses: append(script, respond("r3", message("never")))}
			}
			var bg owned
			hooks := loop.Hooks{AfterCall: func(_ context.Context, c tools.Call, out tools.Output, _ bool, _ []any) error {
				switch c.CallID() {
				case "c1":
					bg = own(t, filepath.Join(l.w.root, "bg.pid"))
				case "c2":
					if !bg.live(t) || out.Text != "exit status: 0\nalive\n" {
						t.Errorf("the background process did not survive between calls: %q", out.Text)
					}
					if source == "hook" {
						return sentinel
					}
				}
				return nil
			}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			res, err := loop.Run(ctx, l.rd, []any{userMessage("go")}, rq, hooks)
			if err != sentinel || res.Ending != "" || ctx.Err() != nil {
				t.Fatalf("%+v, error %v, context %v", res, err, ctx.Err())
			}
			if !bg.waitGone(t, 10*time.Second) {
				t.Error("the background process outlived a failed run")
			}
			if !pre.live(t) || !host.live(t) {
				t.Error("a process the round did not start was stopped")
			}
		})
	}
}

// Normal shell results and the between-call lifetime of background processes stay unchanged.
func TestShellLifecycleCompatibility(t *testing.T) {
	l := newLifecycleRun(t)
	rq := &scripted{responses: []*provider.Response{
		respond("r1",
			shellItem("c1", background(l.w.root, "bg")),
			shellItem("c2", aliveCheck(l.w.root, "bg")),
			shellItem("c3", "printf 'out\\n'; printf 'err\\n' >&2; exit 7")),
		respond("r2", message("done")),
	}}
	if _, err := loop.Run(context.Background(), l.rd, []any{userMessage("go")}, rq, loop.Hooks{}); err != nil {
		t.Fatal(err)
	}
	outs := rq.asked[1].Input[len(rq.asked[1].Input)-3:]
	for i, want := range []string{"exit status: 0\n", "exit status: 0\nalive\n", "exit status: 7\nout\nerr\n"} {
		if got := outs[i].(map[string]any)["output"]; got != want {
			t.Errorf("call %d output %q, want %q", i+1, got, want)
		}
	}
	def, ok := tools.Definition(tools.ShellTool)
	if !ok || !strings.Contains(fmt.Sprint(def["description"]), "Commands have no time limit.") {
		t.Errorf("shell definition %v", def)
	}
	props := def["parameters"].(map[string]any)["properties"].(map[string]any)
	if len(props) != 1 || props["command"] == nil {
		t.Errorf("shell parameters %v", props)
	}
}

// ---- startup races ----

// startupRound runs a round whose second shell call is held at one stage of the shell-start
// boundary while the context ends, then released. Both ends of the context must stop it.
func startupRound(t *testing.T, stage string, end func() (context.Context, func(), func())) {
	t.Helper()
	l := newLifecycleRun(t)
	ctx, stop, waitEnded := end()
	defer stop()
	hold := `echo $$ > shell.pid; sleep 600 & echo $! > sleep.pid; wait`
	rq := &scripted{responses: []*provider.Response{
		respond("r1", shellItem("c1", background(l.w.root, "bg")), shellItem("c2", hold)),
		respond("r2", message("never requested")),
	}}
	var published []string
	var requests atomic.Int32
	hooks := loop.Hooks{
		BeforeRequest: func(context.Context, []any) error { requests.Add(1); return nil },
		AfterCall: func(_ context.Context, c tools.Call, _ tools.Output, _ bool, _ []any) error {
			published = append(published, fmt.Sprint(c.CallID()))
			return nil
		},
	}
	reached, gate := make(chan struct{}), make(chan struct{})
	var once sync.Once
	release := func() { once.Do(func() { close(gate) }) }
	defer release()
	var enters atomic.Int32
	shellStartHook = func(s string) {
		if s == "enter" {
			enters.Add(1)
		}
		if s == stage && enters.Load() == 2 {
			close(reached)
			<-gate
		}
	}
	defer func() { shellStartHook = nil }()
	type outcome struct {
		res loop.Result
		err error
	}
	done := make(chan outcome, 1)
	go func() {
		res, err := loop.Run(ctx, l.rd, []any{userMessage("go")}, rq, hooks)
		done <- outcome{res, err}
	}()
	select {
	case <-reached:
	case <-time.After(30 * time.Second):
		release()
		t.Fatal("the second shell call never reached the start boundary")
	}
	// The round's custody gets its chance to look at the existing groups (the first call's
	// background group) before the start is released.
	waitEnded()
	time.Sleep(200 * time.Millisecond)
	releasedAt := time.Now()
	release()
	var got outcome
	select {
	case got = <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the round did not return within 10 seconds of releasing the start gate")
	}
	t.Logf("returned %v after the release", time.Since(releasedAt))
	if got.res.Ending != "" || got.res.Terminal != nil {
		t.Errorf("an ended round returned %+v", got.res)
	}
	want := context.Canceled
	if ctx.Err() == context.DeadlineExceeded {
		want = context.DeadlineExceeded
	}
	if !errors.Is(got.err, want) {
		t.Errorf("error %v, want %v", got.err, want)
	}
	if fmt.Sprint(published) != "[c1]" || requests.Load() != 1 {
		t.Errorf("published %v and sent %d requests", published, requests.Load())
	}
	if left := noLiveMembers(t, l.sess.Groups(), 10*time.Second); len(left) != 0 {
		t.Errorf("owned processes survived: %v", left)
	}
	for _, name := range []string{"bg", "shell", "sleep"} {
		if pid := pidIfWritten(filepath.Join(l.w.root, name+".pid")); pid != 0 {
			if _, _, ok := psInfo(t, pid); ok && len(liveMembers(t, pid)) != 0 {
				t.Errorf("process %d (%s) survived", pid, name)
			}
		}
	}
	if stage == "enter" {
		if _, err := os.Stat(filepath.Join(l.w.root, "shell.pid")); err == nil {
			t.Error("a shell started after the context had ended")
		}
	}
}

// Cancellation during startup cannot miss a shell or hang the round.
func TestShellLifecycleCancelStartup(t *testing.T) {
	for _, stage := range []string{"enter", "starting", "started"} {
		t.Run(stage, func(t *testing.T) {
			startupRound(t, stage, func() (context.Context, func(), func()) {
				ctx, cancel := context.WithCancel(context.Background())
				return ctx, cancel, cancel
			})
		})
	}
}

// Deadline during startup cannot miss late registration.
func TestShellLifecycleDeadlineStartup(t *testing.T) {
	for _, stage := range []string{"enter", "starting", "started"} {
		t.Run(stage, func(t *testing.T) {
			startupRound(t, stage, func() (context.Context, func(), func()) {
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				return ctx, cancel, func() { <-ctx.Done() }
			})
		})
	}
	// The standalone CLI: the whole-round deadline stops a running shell and its
	// SIGTERM-resistant descendant before the process exits.
	t.Run("cli", func(t *testing.T) {
		w := newWorld(t).signIn()
		command := `echo $$ > shell.pid; ` + resistant(w.root, "desc") + ` wait`
		f := newFakeProvider(t, []exchange{{Items: []map[string]any{call("c1", "shell", map[string]any{"command": command})}}, {Hang: true}})
		start := time.Now()
		p := startCLI(t, w, f, mustJSON(t, w.task(map[string]any{"deadline_seconds": 2})), "run", "--task", "-")
		shell, desc := own(t, filepath.Join(w.root, "shell.pid")), own(t, filepath.Join(w.root, "desc.pid"))
		r := p.result()
		if time.Since(start) > 20*time.Second {
			t.Errorf("the deadline took %v", time.Since(start))
		}
		if r.exit != 1 {
			t.Errorf("exit %d (stderr %s)", r.exit, r.stderr)
		}
		if e := r.first("error"); e == nil || e["class"] != "loop" || e["reason"] != "deadline" {
			t.Errorf("error %v", e)
		}
		if end := r.events[len(r.events)-1]; end["status"] != "failed" {
			t.Errorf("session.ended %v", end)
		}
		if r.first("tool.result") != nil || len(f.requests()) != 1 {
			t.Errorf("an interrupted result was published or another request was sent (%d requests)", len(f.requests()))
		}
		for name, o := range map[string]owned{"shell": shell, "descendant": desc} {
			if !o.waitGone(t, 2*time.Second) {
				t.Errorf("the %s survived the process that was told to stop it", name)
			}
		}
	})
}

// ---- killed host ----

// A killed host's supervisor completes whole-group escalation although the direct shell
// exits on SIGTERM and a descendant ignores it, and also stops what a finished shell left.
func TestShellLifecycleKilledHostDescendants(t *testing.T) {
	for _, tc := range []struct {
		name     string
		finished bool
	}{{"running shell", false}, {"finished shell", true}} {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t).signIn()
			command := `echo $$ > shell.pid; ` + resistant(w.root, "desc") + ` wait`
			script := []exchange{{Items: []map[string]any{call("c1", "shell", map[string]any{"command": command})}}}
			if tc.finished {
				command = resistant(w.root, "desc")
				script = []exchange{{Items: []map[string]any{call("c1", "shell", map[string]any{"command": command})}}, {Hang: true}}
			}
			f := newFakeProvider(t, script)
			p := startCLI(t, w, f, mustJSON(t, w.task(nil)), "run", "--task", "-")
			desc := own(t, filepath.Join(w.root, "desc.pid"))
			var shell owned
			if tc.finished {
				// The next request proves the shell call ended and its result was returned.
				for deadline := time.Now().Add(30 * time.Second); len(f.requests()) < 2; time.Sleep(50 * time.Millisecond) {
					if time.Now().After(deadline) {
						t.Fatal("the shell call never returned")
					}
				}
			} else {
				shell = own(t, filepath.Join(w.root, "shell.pid"))
			}
			if !desc.live(t) {
				t.Fatal("the descendant is not running before the host dies")
			}
			killed := time.Now()
			if err := p.cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			<-p.done
			if !tc.finished {
				if !shell.waitGone(t, 10*time.Second) {
					t.Error("the direct shell survived the death of the host")
				}
				if time.Since(killed) < 3*time.Second && !desc.live(t) {
					t.Error("the descendant ended on SIGTERM: the fixture does not need SIGKILL escalation")
				}
			}
			if !desc.waitGone(t, 10*time.Second) {
				t.Errorf("the SIGTERM-ignoring descendant survived the death of the host (%v)", time.Since(killed))
			}
		})
	}
}
