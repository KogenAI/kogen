package git

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"kogen-loop/sys"
)

// BuildLockPath is the Build lock of the repository at root (AUT-4).
func BuildLockPath(root string) string { return filepath.Join(root, ".kogen/local/build.lock") }

// LockStatus is the outcome of Lock.Acquire.
type LockStatus int

const (
	Acquired     LockStatus = iota // the lock is ours
	RemovedStale                   // ours after removing a lock an earlier Kogen left behind
	Held                           // a running process owns it
)

// LockResult is what Acquire found: the status and, for RemovedStale and Held, the
// owner's pid as the lock records it.
type LockResult struct {
	Status LockStatus
	PID    string
}

// lockHeader starts the content of a lock written by this Kogen.
const lockHeader = "kogen-build-lock 1"

// Lock is an exclusive advisory lock (flock) on a regular file, held while the owner runs.
// The kernel releases it when the owner ends in any way, SIGKILL included, so a lock is
// never left behind. The file also records the owner's pid and a token as diagnostics:
//
//	kogen-build-lock 1
//	pid <pid>
//	token <token>
//
// Locks left by earlier Kogen versions (a directory holding an owner file, or a plain pid
// file) carry no kernel lock: they are held while their pid runs and removed otherwise.
type Lock struct {
	Path string

	mu    sync.Mutex
	f     *os.File
	token string
	alive func(pid int) bool // nil: kill -0
}

// NewLock returns an unacquired lock at path.
func NewLock(path string) *Lock { return &Lock{Path: path} }

// Token is the owner token this value wrote, "" when it holds no lock.
func (l *Lock) Token() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.token
}

// Acquire takes the lock without waiting. The value owns the lock only after Acquired or
// RemovedStale; Release on any other value does nothing.
func (l *Lock) Acquire() (LockResult, error) {
	if err := os.MkdirAll(filepath.Dir(l.Path), 0o755); err != nil {
		return LockResult{}, err
	}
	res := LockResult{Status: Acquired}
	if st, err := os.Lstat(l.Path); err == nil && st.IsDir() {
		pid, alive, err := l.legacyDirectory(true)
		if err != nil {
			return LockResult{}, err
		}
		if alive {
			return LockResult{Status: Held, PID: pid}, nil
		}
		res = LockResult{Status: RemovedStale, PID: pid}
	}
	for attempt := 0; attempt < 100; attempt++ {
		f, err := os.OpenFile(l.Path, os.O_RDWR|os.O_CREATE, 0o644)
		if err != nil {
			return LockResult{}, err
		}
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			pid := lockPID(f)
			f.Close()
			if errors.Is(err, syscall.EWOULDBLOCK) {
				return LockResult{Status: Held, PID: pid}, nil
			}
			return LockResult{}, fmt.Errorf("lock %s: %w", l.Path, err)
		}
		// The previous owner may have removed the file between our open and flock: the
		// lock only counts on the inode the path still names.
		if !sameFile(f, l.Path) {
			f.Close()
			continue
		}
		content, _ := readLock(f)
		if pid, legacy := legacyPID(content); legacy && pid != "" {
			if l.isAlive(pid) && pid != strconv.Itoa(os.Getpid()) {
				f.Close()
				return LockResult{Status: Held, PID: pid}, nil
			}
			res = LockResult{Status: RemovedStale, PID: pid}
		}
		token := newToken()
		body := fmt.Sprintf("%s\npid %d\ntoken %s\n", lockHeader, os.Getpid(), token)
		if err := f.Truncate(0); err != nil {
			f.Close()
			return LockResult{}, err
		}
		if _, err := f.WriteAt([]byte(body), 0); err != nil {
			f.Close()
			return LockResult{}, err
		}
		l.mu.Lock()
		l.f, l.token = f, token
		l.mu.Unlock()
		return res, nil
	}
	return LockResult{}, fmt.Errorf("lock %s: the lock file keeps changing", l.Path)
}

// Held reports whether a running process holds the lock, without taking it.
func (l *Lock) Held() (bool, error) {
	st, err := os.Lstat(l.Path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return false, nil
	case err != nil:
		return false, err
	case st.IsDir():
		_, alive, err := l.legacyDirectory(false)
		return alive, err
	}
	f, err := os.Open(l.Path)
	if err != nil {
		return false, nil
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		return errors.Is(err, syscall.EWOULDBLOCK), nil
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	content, _ := readLock(f)
	if pid, legacy := legacyPID(content); legacy && pid != "" {
		return l.isAlive(pid), nil
	}
	return false, nil
}

// Release removes the lock file and drops the lock this value holds. Repeated calls do nothing.
func (l *Lock) Release() {
	l.mu.Lock()
	f := l.f
	l.f, l.token = nil, ""
	l.mu.Unlock()
	if f == nil {
		return
	}
	if sameFile(f, l.Path) {
		os.Remove(l.Path)
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	f.Close()
}

// LockOwner reads the diagnostics of the lock at path: the owner's pid and token ("" when
// absent or written by an earlier Kogen) and whether a running process holds it.
func LockOwner(path string) (pid, token string, held bool) {
	held, _ = NewLock(path).Held()
	f, err := os.Open(path)
	if err != nil {
		return "", "", held
	}
	defer f.Close()
	content, _ := readLock(f)
	if p, legacy := legacyPID(content); legacy {
		return p, "", held
	}
	for _, line := range strings.Split(content, "\n") {
		if v, ok := strings.CutPrefix(line, "pid "); ok {
			pid = v
		}
		if v, ok := strings.CutPrefix(line, "token "); ok {
			token = v
		}
	}
	return pid, token, held
}

// legacyDirectory reads a directory lock of an earlier Kogen; with remove, a dead owner's
// lock is removed.
func (l *Lock) legacyDirectory(remove bool) (pid string, alive bool, err error) {
	entries, err := os.ReadDir(l.Path)
	if err != nil {
		return "", false, err
	}
	if len(entries) == 1 {
		owner := filepath.Join(l.Path, entries[0].Name())
		b, _ := os.ReadFile(owner)
		pid = strings.TrimSpace(string(b))
		if l.isAlive(pid) {
			return pid, true, nil
		}
		if !remove {
			return pid, false, nil
		}
		os.Remove(owner)
	}
	if !remove {
		return pid, false, nil
	}
	// Never remove recursively: only an empty directory goes.
	if err := os.Remove(l.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return pid, false, err
	}
	return pid, false, nil
}

func readLock(f *os.File) (string, error) {
	b, err := io.ReadAll(io.NewSectionReader(f, 0, 4096))
	return string(b), err
}

// legacyPID returns the pid of a plain pid-file lock; legacy is false for this Kogen's format.
func legacyPID(content string) (pid string, legacy bool) {
	if content == "" || strings.HasPrefix(content, lockHeader+"\n") {
		return "", false
	}
	return strings.TrimSpace(content), true
}

func lockPID(f *os.File) string {
	content, _ := readLock(f)
	if p, legacy := legacyPID(content); legacy {
		return p
	}
	sc := bufio.NewScanner(strings.NewReader(content))
	for sc.Scan() {
		if v, ok := strings.CutPrefix(sc.Text(), "pid "); ok {
			return v
		}
	}
	return ""
}

func sameFile(f *os.File, path string) bool {
	a, err1 := f.Stat()
	b, err2 := os.Stat(path)
	return err1 == nil && err2 == nil && os.SameFile(a, b)
}

func newToken() string {
	b := make([]byte, 12)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (l *Lock) isAlive(pid string) bool {
	n, err := strconv.Atoi(pid)
	if err != nil || n <= 0 {
		return false
	}
	if l.alive != nil {
		return l.alive(n)
	}
	return processAlive(n)
}

// processAlive is `kill -0`: the process exists (even one we may not signal).
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// AcquireBuild takes the repository's Build lock (AUT-4). A running owner is
// environment/build_running (exit 3). A lock an earlier Kogen left behind for a process
// that no longer runs is removed with a notice on stderr. The caller releases the lock.
func AcquireBuild(root string, s *sys.Session) (*Lock, error) {
	l := NewLock(BuildLockPath(root))
	res, err := l.Acquire()
	if err != nil {
		return nil, err
	}
	switch res.Status {
	case RemovedStale:
		s.Progress("kogen: removed the lock of a Build that is no longer running")
	case Held:
		return nil, sys.Fail("environment", "build_running", "a Build is running in this repository (pid "+res.PID+")", 3)
	}
	return l, nil
}
