package provider

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const deadPID = 2147483647

func lockOwner(t *testing.T, lock string) string {
	t.Helper()
	path := lock
	if st, err := os.Stat(lock); err == nil && st.IsDir() {
		entries, err := os.ReadDir(lock)
		if err != nil || len(entries) != 1 {
			t.Fatalf("lock directory entries = %v, %v", entries, err)
		}
		path = filepath.Join(lock, entries[0].Name())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(data))
}

// lock_test: AUT-4/GPT-6 concurrent stale recovery preserves the live owner.
func TestConcurrentStaleRecoveryPreservesTheLiveOwner(t *testing.T) {
	for _, format := range []string{"pid_file", "directory"} {
		t.Run(format, func(t *testing.T) {
			root := t.TempDir()
			lock := filepath.Join(root, "build.lock")
			if format == "pid_file" {
				os.WriteFile(lock, []byte(strconv.Itoa(deadPID)+"\n"), 0o644)
			} else {
				os.Mkdir(lock, 0o755)
				os.WriteFile(filepath.Join(lock, "dead-owner"), []byte(strconv.Itoa(deadPID)+"\n"), 0o644)
			}
			type contender struct {
				pid    int
				atTest chan struct{}
				goOn   chan struct{}
				lock   *Lock
				err    error
				done   chan struct{}
			}
			mk := func(pid int) *contender {
				return &contender{pid: pid, atTest: make(chan struct{}), goOn: make(chan struct{}), done: make(chan struct{})}
			}
			a, b := mk(1001), mk(1002)
			for _, c := range []*contender{a, b} {
				c := c
				locker := Locker{PID: c.pid, Alive: func(pid int) bool {
					if pid != deadPID {
						return true
					}
					select {
					case <-c.atTest:
					default:
						close(c.atTest)
					}
					<-c.goOn
					return false
				}}
				go func() {
					c.lock, c.err = locker.Acquire(lock)
					close(c.done)
				}()
			}
			for _, c := range []*contender{a, b} {
				select {
				case <-c.atTest:
				case <-time.After(5 * time.Second):
					t.Fatal("contender never reached the liveness check")
				}
			}
			close(a.goOn)
			<-a.done
			if a.err != nil || a.lock.Stale != strconv.Itoa(deadPID) {
				t.Fatalf("A = %+v, %v", a.lock, a.err)
			}
			if got := lockOwner(t, lock); got != "1001" {
				t.Fatalf("owner = %s", got)
			}
			close(b.goOn)
			<-b.done
			var held *HeldError
			if !errors.As(b.err, &held) || held.PID != "1001" {
				t.Fatalf("B = %v, %v", b.lock, b.err)
			}
			b.lock.Release() // a nil handle owns nothing
			if got := lockOwner(t, lock); got != "1001" {
				t.Fatalf("owner after B's release = %s", got)
			}
			a.lock.Release()
			if _, err := os.Lstat(lock); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("lock remains: %v", err)
			}
		})
	}
}

// lock_test: release cannot remove a later acquisition, including a repeated release.
func TestReleaseCannotRemoveALaterAcquisition(t *testing.T) {
	lock := filepath.Join(t.TempDir(), "build.lock")
	l := Locker{}
	first, err := l.Acquire(lock)
	if err != nil {
		t.Fatal(err)
	}
	first.Release()
	second, err := Locker{PID: os.Getpid()}.Acquire(lock)
	if err != nil {
		t.Fatal(err)
	}
	first.Release() // repeated: no effect
	if got := lockOwner(t, lock); got != strconv.Itoa(os.Getpid()) {
		t.Fatalf("owner = %s", got)
	}
	second.Release()
	if _, err := os.Lstat(lock); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("lock remains")
	}
}

func TestAcquireHeldByLiveProcessAndObserve(t *testing.T) {
	lock := filepath.Join(t.TempDir(), "sub", "x.lock")
	l := Locker{}
	a, err := l.Acquire(lock)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Release()
	var held *HeldError
	if _, err := l.Acquire(lock); !errors.As(err, &held) || held.PID != strconv.Itoa(os.Getpid()) {
		t.Fatalf("err = %v", err)
	}
	if !l.Held(lock) {
		t.Fatal("Held = false for a live owner")
	}
	if l.Held(filepath.Join(t.TempDir(), "none.lock")) {
		t.Fatal("Held = true for no lock")
	}
}

func TestStaleLocksOfDeadOrCorruptOwnersAreReplaced(t *testing.T) {
	for _, content := range []string{strconv.Itoa(deadPID) + "\n", "not-a-pid\n", "\n"} {
		lock := filepath.Join(t.TempDir(), "x.lock")
		os.WriteFile(lock, []byte(content), 0o644)
		l, err := Locker{}.Acquire(lock)
		if err != nil {
			t.Fatalf("%q: %v", content, err)
		}
		l.Release()
	}
	// A real exited process: its PID is no longer alive.
	dead := Locker{Alive: func(pid int) bool { return syscall.Kill(pid, 0) == nil }}
	if dead.alive("0") || dead.alive("-4") || dead.alive("") {
		t.Fatal("non-positive PIDs are never alive")
	}
}
