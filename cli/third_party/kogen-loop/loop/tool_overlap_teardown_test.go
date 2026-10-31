package loop

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	_ "unsafe" // go:linkname

	"kogen-loop/sys"
)

// shellStartHook is sys's test-only seam at the shell-start boundary ("enter", "starting",
// "started"); nil outside the test that sets it.
//
//go:linkname shellStartHook kogen-loop/sys.startHook
var shellStartHook func(stage string)

func olPidFile(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	pid, perr := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || perr != nil {
		t.Fatalf("pid file %s: %q %v %v", path, b, err, perr)
	}
	return pid
}

// olBackground starts a quiet long-running process in the command's group, recording its pid.
func olBackground(path string) string {
	return "sleep 600 >/dev/null 2>&1 & echo $! > " + olQuote(path)
}

// Every round ends the process groups it started, on success and on every kind of failure,
// whether the shell was starting, running or had left a background process; groups that
// existed before the round and processes outside every group are not touched.
func TestToolOverlapTeardown(t *testing.T) {
	type fixture struct {
		root string
		sess *sys.Session
		pre  int // a process in a group started before the round
		host int // a process outside every session group
	}
	setup := func(t *testing.T) fixture {
		root := t.TempDir()
		sess := sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, root)
		if res, err := sess.Run(olBackground(filepath.Join(root, "pre.pid")), root, sys.Options{}); err != nil || res.Status != 0 {
			t.Fatalf("pre-round group: %+v %v", res, err)
		}
		pre := olPidFile(t, filepath.Join(root, "pre.pid"))
		groups := sess.Groups()
		host := exec.Command("sleep", "600")
		host.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		if err := host.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			syscall.Kill(pre, syscall.SIGKILL)
			sys.Terminate(groups)
			host.Process.Kill()
			host.Wait()
		})
		return fixture{root, sess, pre, host.Process.Pid}
	}
	untouched := func(t *testing.T, f fixture) {
		t.Helper()
		if !procLive(t, f.pre) || !procLive(t, f.host) {
			t.Fatal("a process the round did not start was stopped")
		}
	}

	for _, ending := range []string{"terminal", "no call", "failure"} {
		t.Run("background after "+ending, func(t *testing.T) {
			f := setup(t)
			bg := filepath.Join(f.root, "bg.pid")
			last := fcall("end", "finish", `{}`)
			if ending == "no call" {
				last = prose("done")[0]
			}
			script := [][]map[string]any{{olShell("c1", olBackground(bg)), olShell("c2", "kill -0 $(cat "+olQuote(bg)+") && echo alive")}, {last}}
			if ending == "failure" {
				script = script[:1] // the requester fails on the next request
			}
			rq := &scriptRequester{script: script}
			res, err := Run(context.Background(), Round{Tools: olTools(f.root, newOLRepo(t), f.sess)}, []any{userMsg("go")}, rq, Hooks{})
			if (ending == "failure") != (err != nil) {
				t.Fatalf("%+v %v", res, err)
			}
			if ending != "failure" {
				var outs []string
				for _, it := range res.Input {
					if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
						outs = append(outs, m["output"].(string))
					}
				}
				// The background process lived between the round's calls.
				if len(outs) != 2 || outs[1] != "exit status: 0\nalive\n" {
					t.Fatalf("outputs %q", outs)
				}
			}
			if procLive(t, olPidFile(t, bg)) {
				t.Fatal("the background process outlived the round")
			}
			untouched(t, f)
		})
	}

	// Cancelling mid-stream with a shell running and a background process behind it.
	t.Run("running shell and background on cancel", func(t *testing.T) {
		f := setup(t)
		bg := filepath.Join(f.root, "bg.pid")
		dir := t.TempDir()
		ready, gate := olFifo(t, dir, "ready"), olFifo(t, dir, "gate")
		sent := make(chan struct{})
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.call(0, "a", "shell", string(mustJSON(map[string]any{"command": olBackground(bg) + "; " + olHold(ready, gate, "echo never")})))
				close(sent)
				s.wait(nil)
			},
			olFinish,
		)
		d, role, _ := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(f.root, newOLRepo(t), f.sess)}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		run := olStart(ctx, rd, []any{userMsg("go")}, d, Hooks{})
		shell := olReadPid(t, ready)
		<-sent
		bgPid := olPidFile(t, bg)
		cancel()
		if _, err := run.wait(t); err == nil {
			t.Fatal("no error")
		}
		if procLive(t, shell) || procLive(t, bgPid) {
			t.Fatalf("shell %v or background %v outlived the round", procLive(t, shell), procLive(t, bgPid))
		}
		untouched(t, f)
	})

	// A shell that is starting when the round is cancelled is stopped by the round, which
	// returns only after it: the process exists but is not yet registered with the session.
	t.Run("starting shell on cancel", func(t *testing.T) {
		f := setup(t)
		dir := t.TempDir()
		ready := olFifo(t, dir, "ready")
		entered, release := make(chan struct{}), make(chan struct{})
		shellStartHook = func(stage string) {
			if stage == "starting" {
				close(entered)
				<-release
			}
		}
		t.Cleanup(func() { shellStartHook = nil })
		sent := make(chan struct{})
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.call(0, "a", "shell", string(mustJSON(map[string]any{"command": "echo $$ > " + olQuote(ready) + "; echo never"})))
				close(sent)
				s.wait(nil)
			},
			olFinish,
		)
		d, role, _ := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(f.root, newOLRepo(t), f.sess)}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		old := map[int]bool{}
		for _, g := range f.sess.Groups() {
			old[g] = true
		}
		run := olStart(ctx, rd, []any{userMsg("go")}, d, Hooks{})
		<-entered
		<-sent
		cancel()
		if run.returned() {
			t.Fatal("the round returned while its shell was still starting")
		}
		close(release)
		res, err := run.wait(t)
		if err == nil || res.Input != nil {
			t.Fatalf("%+v %v", res, err)
		}
		started := 0
		for _, g := range f.sess.Groups() {
			if old[g] {
				continue
			}
			started++
			if groupLive(t, g) {
				t.Fatalf("group %d of the starting shell is still alive", g)
			}
		}
		if started != 1 {
			t.Fatalf("%d groups started by the round, want 1", started)
		}
		untouched(t, f)
	})
}
