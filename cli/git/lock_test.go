package git

import (
	"bytes"
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

	"kogen/sys"
)

// The helper process takes the lock, reports ready, and waits to be killed.
func init() {
	if p := os.Getenv("KOGEN_LOCK_HELPER"); p != "" {
		l := NewLock(p)
		if res, err := l.Acquire(); err != nil || res.Status == Held {
			os.Exit(3)
		}
		os.WriteFile(p+".ready", []byte("ok"), 0o644)
		time.Sleep(time.Minute)
		os.Exit(0)
	}
}

func lockPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), ".kogen", "local", "build.lock")
}

func startHolder(t *testing.T, path string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), "KOGEN_LOCK_HELPER="+path)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 200; i++ {
		if _, err := os.Stat(path + ".ready"); err == nil {
			return cmd
		}
		time.Sleep(25 * time.Millisecond)
	}
	cmd.Process.Kill()
	t.Fatal("the helper did not take the lock")
	return nil
}

func TestAcquireCreatesTheLocalFolderAndTakesAFreeLock(t *testing.T) {
	path := lockPath(t)
	l := NewLock(path)
	res, err := l.Acquire()
	if err != nil || res.Status != Acquired {
		t.Fatalf("Acquire = %+v, %v", res, err)
	}
	b, _ := os.ReadFile(path)
	want := "kogen-build-lock 1\npid " + strconv.Itoa(os.Getpid()) + "\ntoken " + l.Token() + "\n"
	if string(b) != want || len(l.Token()) != 24 {
		t.Fatalf("lock content %q, want %q", b, want)
	}
	l.Release()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("Release left the lock file")
	}
	l.Release() // repeated release does nothing
}

func TestAcquireRefusesALiveLockAndHeldObservesIt(t *testing.T) {
	path := lockPath(t)
	first := NewLock(path)
	if res, _ := first.Acquire(); res.Status != Acquired {
		t.Fatal(res)
	}
	defer first.Release()
	second := NewLock(path)
	res, err := second.Acquire()
	if err != nil || res.Status != Held || res.PID != strconv.Itoa(os.Getpid()) {
		t.Fatalf("second Acquire = %+v, %v", res, err)
	}
	second.Release() // must not remove the first owner's lock
	if held, _ := NewLock(path).Held(); !held {
		t.Fatal("Held = false for a held lock")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("the losing contender removed the owner's lock")
	}
}

// AUT-4: the kernel drops the lock of a killed owner, so the next Build takes it without
// a stale-lock path or notice.
func TestAKilledOwnersLockIsTakenWithoutANotice(t *testing.T) {
	path := lockPath(t)
	os.MkdirAll(filepath.Dir(path), 0o755)
	cmd := startHolder(t, path)
	if held, _ := NewLock(path).Held(); !held {
		cmd.Process.Kill()
		t.Fatal("the helper's lock is not held")
	}
	res, _ := NewLock(path).Acquire()
	if res.Status != Held || res.PID != strconv.Itoa(cmd.Process.Pid) {
		cmd.Process.Kill()
		t.Fatalf("while the helper runs: %+v", res)
	}
	cmd.Process.Signal(syscall.SIGKILL)
	cmd.Wait()
	var out bytes.Buffer
	s := sys.NewWith(nil, t.TempDir())
	s.Stderr = &out
	l, err := AcquireBuild(filepath.Dir(filepath.Dir(filepath.Dir(path))), s)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Release()
	if out.Len() != 0 {
		t.Fatalf("notice after a killed owner: %q", out.String())
	}
}

func TestLocksLeftByAnEarlierKogen(t *testing.T) {
	alive := strconv.Itoa(os.Getppid())
	for _, c := range []struct {
		name, pid string
		dir       bool
		status    LockStatus
	}{
		{"pid file of a dead process", "987654321", false, RemovedStale},
		{"pid file of a running process", alive, false, Held},
		{"directory of a dead process", "987654321", true, RemovedStale},
		{"directory of a running process", alive, true, Held},
	} {
		t.Run(c.name, func(t *testing.T) {
			path := lockPath(t)
			os.MkdirAll(filepath.Dir(path), 0o755)
			if c.dir {
				os.Mkdir(path, 0o755)
				os.WriteFile(filepath.Join(path, "0123abcd"), []byte(c.pid+"\n"), 0o644)
			} else {
				os.WriteFile(path, []byte(c.pid+"\n"), 0o644)
			}
			if held, _ := NewLock(path).Held(); held != (c.status == Held) {
				t.Fatalf("Held = %v", held)
			}
			l := NewLock(path)
			res, err := l.Acquire()
			defer l.Release()
			if err != nil || res.Status != c.status || res.PID != c.pid {
				t.Fatalf("Acquire = %+v, %v", res, err)
			}
		})
	}
}

func TestAcquireBuildMessages(t *testing.T) {
	root := t.TempDir()
	path := BuildLockPath(root)
	os.MkdirAll(filepath.Dir(path), 0o755)
	os.WriteFile(path, []byte("987654321\n"), 0o644)
	var out bytes.Buffer
	s := sys.NewWith(nil, root)
	s.Stderr = &out
	l, err := AcquireBuild(root, s)
	if err != nil || out.String() != "kogen: removed the lock of a Build that is no longer running\n" {
		t.Fatalf("stale: %v %q", err, out.String())
	}
	_, err = AcquireBuild(root, s)
	e, ok := sys.AsError(err)
	if !ok || e.Error() != "environment/build_running: a Build is running in this repository (pid "+strconv.Itoa(os.Getpid())+")" || e.Exit != 3 {
		t.Fatalf("held: %v", err)
	}
	l.Release()
}

func TestLockOwnerDiagnostics(t *testing.T) {
	path := lockPath(t)
	if pid, token, held := LockOwner(path); pid != "" || token != "" || held {
		t.Fatal("owner of a missing lock")
	}
	l := NewLock(path)
	l.Acquire()
	pid, token, held := LockOwner(path)
	if pid != strconv.Itoa(os.Getpid()) || token != l.Token() || !held {
		t.Fatalf("LockOwner = %q %q %v", pid, token, held)
	}
	l.Release()
}

func TestLockAcquireContendersNeverBothWin(t *testing.T) {
	path := lockPath(t)
	for round := 0; round < 20; round++ {
		var wins atomic.Int32
		var wg sync.WaitGroup
		var locks []*Lock
		var mu sync.Mutex
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				l := NewLock(path)
				if res, err := l.Acquire(); err == nil && res.Status != Held {
					wins.Add(1)
					mu.Lock()
					locks = append(locks, l)
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
		if wins.Load() != 1 {
			t.Fatalf("round %d: %d winners", round, wins.Load())
		}
		for _, l := range locks {
			l.Release()
		}
	}
}

func TestProcessAliveIsKillZero(t *testing.T) {
	if !processAlive(os.Getpid()) || processAlive(987654321) {
		t.Fatal("processAlive")
	}
	if strings.TrimSpace("x") == "" {
		t.Fatal()
	}
}
