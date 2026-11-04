package conformance

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"kogen-loop/internal/delivery"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/tools"
)

type snapshotRequester struct {
	scripted
	t       *testing.T
	root    string
	process owned
	groups  []int
	failure error
}

func (s *snapshotRequester) Request(ctx context.Context, r loop.Request) (*provider.Response, []any, error) {
	if len(s.asked) == 1 {
		text := shellResult(s.t, r, "c1")
		var result struct {
			Status string `json:"status"`
			Handle string `json:"handle"`
		}
		if err := json.Unmarshal([]byte(text), &result); err != nil || result.Status != "running" || result.Handle == "" {
			s.t.Fatalf("yield: %q: %v", text, err)
		}
		pidPath := filepath.Join(s.root, "writer.pid")
		for deadline := time.Now().Add(10 * time.Second); pidIfWritten(pidPath) == 0; time.Sleep(10 * time.Millisecond) {
			if time.Now().After(deadline) {
				s.t.Fatal("writer failed to start")
			}
		}
		s.process = own(s.t, pidPath)
		pgid, err := syscall.Getpgid(s.process.pid)
		if err != nil {
			s.t.Fatal(err)
		}
		s.groups = []int{pgid}
		s.t.Cleanup(func() {
			if s.process.live(s.t) {
				syscall.Kill(-pgid, syscall.SIGKILL)
			}
		})
		if !s.process.live(s.t) {
			s.t.Fatal("writer did not survive yield")
		}
		if data, err := os.ReadFile(filepath.Join(s.root, "writes")); err != nil || len(data) == 0 {
			s.t.Fatalf("writer did not produce files: %q %v", data, err)
		}
		if s.failure != nil {
			return nil, nil, s.failure
		}
	}
	return s.scripted.Request(ctx, r)
}

func TestShellLifecycleYieldSnapshot(t *testing.T) {
	t.Run("discarded", testSnapshotDiscarded)
	for _, session := range []string{"explicit", "implicit"} {
		for _, ending := range []string{"no_call", "terminal", "requester", "hook"} {
			t.Run(session+"/"+ending, func(t *testing.T) {
				t.Parallel()
				l := newLifecycleRun(t)
				// The first wait is the new command's; it elapses once the writer is running and
				// has written. A later wait (the hook ending's `true`) never elapses.
				var waits atomic.Int32
				l.rd.Tools.ShellAfter = func(wait time.Duration) <-chan time.Time {
					if waits.Add(1) > 1 {
						return nil
					}
					if wait != 45*time.Second {
						t.Errorf("the first shell wait is %v, want 45s", wait)
					}
					fire := make(chan time.Time, 1)
					go func() {
						pidPath, writes := filepath.Join(l.w.root, "writer.pid"), filepath.Join(l.w.root, "writes")
						for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
							if data, err := os.ReadFile(writes); pidIfWritten(pidPath) != 0 && err == nil && len(data) > 0 {
								break
							}
						}
						fire <- time.Now()
					}()
					return fire
				}
				if session == "implicit" {
					l.rd.Tools.Session = nil
				}
				init := exec.Command("git", "init", "-q", l.w.root)
				if out, err := init.CombinedOutput(); err != nil {
					t.Fatalf("git init: %s %v", out, err)
				}
				dir := filepath.Join(l.w.root, "internal/tmpl")
				if err := os.MkdirAll(dir, 0755); err != nil {
					t.Fatal(err)
				}
				transient := filepath.Join(dir, "expand_test.go.2127067331120939396")
				command := `echo $$ > writer.pid; trap 'rm -f internal/tmpl/expand_test.go.2127067331120939396; exit' TERM INT; while :; do : > internal/tmpl/expand_test.go.2127067331120939396; echo x >> writes; sleep .01; rm -f internal/tmpl/expand_test.go.2127067331120939396; done`
				last := message("done")
				if ending == "terminal" {
					last = fakeCall("finish", "finish", `{"summary":"s"}`)
				}
				sentinel := errors.New("snapshot sentinel")
				rq := &snapshotRequester{t: t, root: l.w.root, scripted: scripted{responses: []*provider.Response{respond("r1", shellItem("c1", command)), respond("r2", last)}}}
				if ending == "requester" {
					rq.failure = sentinel
				}
				var hooks loop.Hooks
				if ending == "hook" {
					hooks.AfterCall = func(_ context.Context, c tools.Call, out tools.Output, _ bool, _ []any) error {
						if c.CallID() == "c2" {
							return sentinel
						}
						return nil
					}
					rq.responses[1] = respond("r2", shellItem("c2", "true"))
				}
				res, err := loop.Run(context.Background(), l.rd, []any{userMessage("go")}, rq, hooks)
				if ending == "hook" || ending == "requester" {
					if err != sentinel {
						t.Fatalf("error %v", err)
					}
				} else if err != nil || (ending == "no_call") != (res.Ending == loop.EndNoCall) {
					t.Fatalf("result %+v: %v", res, err)
				}
				if rq.process.live(t) {
					t.Error("writer alive at return")
				}
				for _, g := range rq.groups {
					if members := liveMembers(t, g); len(members) != 0 {
						t.Errorf("group alive at return: %v", members)
					}
				}
				if _, err := os.Stat(transient); !errors.Is(err, os.ErrNotExist) {
					t.Errorf("transient at return: %v", err)
				}
				cmd := exec.Command("git", "add", "-A", "--", ".")
				cmd.Dir = l.w.root
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Errorf("git add: %s %v", out, err)
				}
				before, err := os.ReadFile(filepath.Join(l.w.root, "writes"))
				if err != nil {
					t.Fatal(err)
				}
				deadline := time.Now().Add(2 * time.Second)
				for time.Now().Before(deadline) {
					if _, err := os.Stat(transient); !errors.Is(err, os.ErrNotExist) {
						t.Fatalf("transient reappeared: %v", err)
					}
					after, err := os.ReadFile(filepath.Join(l.w.root, "writes"))
					if err != nil || string(after) != string(before) {
						t.Fatalf("writes advanced: %v", err)
					}
					time.Sleep(10 * time.Millisecond)
				}
			})
		}
	}
}

// The provider discards a streamed attempt after its yielded leader has exited,
// but while its child remains capable of writing.
type snapshotRetry struct {
	t    *testing.T
	root string
}

func (s *snapshotRetry) Request(ctx context.Context, r loop.Request) (*provider.Response, []any, error) {
	sink := delivery.From(ctx)
	command := `echo $$ > leader.pid; (while :; do echo x >> retry-writes; sleep .05; done) >/dev/null 2>&1 & echo $! > child.pid; sleep 2`
	sink.Done(0, shellItem("discarded", command))
	leaderPath := filepath.Join(s.root, "leader.pid")
	childPath := filepath.Join(s.root, "child.pid")
	for deadline := time.Now().Add(10 * time.Second); pidIfWritten(leaderPath) == 0 || pidIfWritten(childPath) == 0; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			s.t.Fatal("retry fixture failed to start")
		}
	}
	child := own(s.t, childPath)
	leader := own(s.t, leaderPath)
	pgid, err := syscall.Getpgid(child.pid)
	if err != nil {
		s.t.Fatal(err)
	}
	s.t.Cleanup(func() {
		if child.live(s.t) {
			syscall.Kill(-pgid, syscall.SIGKILL)
		}
	})
	for deadline := time.Now().Add(10 * time.Second); leader.live(s.t); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			s.t.Fatal("leader failed to finish")
		}
	}
	if !child.live(s.t) {
		s.t.Fatal("retry child died before abort")
	}
	sink.Abort()
	if child.live(s.t) {
		s.t.Error("discarded attempt left child alive before retry")
	}
	return respond("retry", message("done")), r.Input, nil
}

func testSnapshotDiscarded(t *testing.T) {
	l := newLifecycleRun(t)
	rq := &snapshotRetry{t: t, root: l.w.root}
	res, err := loop.Run(context.Background(), l.rd, []any{userMessage("go")}, rq, loop.Hooks{})
	if err != nil || res.Ending != loop.EndNoCall {
		t.Fatalf("retry: %+v %v", res, err)
	}
}
