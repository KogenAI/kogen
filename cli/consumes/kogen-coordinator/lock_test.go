package consumes

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/KogenAI/kogen-coordinator/git"
)

// kogen cli/facts.go reads the owner of the Build lock at .kogen/local/build.lock.
var _ func(string) (string, string, bool) = git.LockOwner

// lockBody is the content of a Build lock written by the current Kogen: a header, the owner's
// pid and its token.
func lockBody(pid, token string) string {
	return "kogen-build-lock 1\npid " + pid + "\ntoken " + token + "\n"
}

// TestLockOwnerReadsTheDiagnosticsAndWhetherARunningProcessHoldsIt: an absent lock has no owner
// and is not held. A lock file records the pid and the token; it is held while a process has
// the kernel lock on it (the Build) and not once that ended, though pid and token stay readable,
// so kogen's alive check needs the lock held and both to match.
func TestLockOwnerReadsTheDiagnosticsAndWhetherARunningProcessHoldsIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".kogen", "local", "build.lock")
	if pid, token, held := git.LockOwner(path); pid != "" || token != "" || held {
		t.Fatalf("LockOwner without a lock = %q %q %v", pid, token, held)
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(lockBody("4242", "tok-abc123")), 0o644); err != nil {
		t.Fatal(err)
	}
	if pid, token, held := git.LockOwner(path); pid != "4242" || token != "tok-abc123" || held {
		t.Fatalf("LockOwner of an unheld lock = %q %q %v, want 4242 tok-abc123 false", pid, token, held)
	}

	owner, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	if err := syscall.Flock(int(owner.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if pid, token, held := git.LockOwner(path); pid != "4242" || token != "tok-abc123" || !held {
		t.Fatalf("LockOwner of a held lock = %q %q %v, want 4242 tok-abc123 true", pid, token, held)
	}

	if err := syscall.Flock(int(owner.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	if _, _, held := git.LockOwner(path); held {
		t.Fatal("LockOwner still reports the lock held after its owner let go")
	}
}

// TestLockOwnerReadsALockOfAnEarlierKogen: a plain pid file carries no token, and a process that
// is not running does not hold it.
func TestLockOwnerReadsALockOfAnEarlierKogen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "build.lock")
	if err := os.WriteFile(path, []byte("987654321\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if pid, token, held := git.LockOwner(path); pid != "987654321" || token != "" || held {
		t.Fatalf("LockOwner = %q %q %v, want 987654321, no token, not held", pid, token, held)
	}
}
