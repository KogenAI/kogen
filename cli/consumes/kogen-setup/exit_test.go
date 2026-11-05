package consumes

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/sys"
)

// TestInitSucceedsWithExitZero: kogen prints the readiness report only for a nil error and exit
// 0. Init gives both for the first commit of an empty repository, for a configured project and
// for a project that is already initialized.
func TestInitSucceedsWithExitZero(t *testing.T) {
	t.Run("empty repository", func(t *testing.T) {
		f := newInitFx(t, false)
		f.mustRun()
		if f.head() == "" || !f.exists(".kogen/project.yaml") {
			t.Fatalf("no first commit with .kogen/project.yaml: head %q", f.head())
		}
		if got := f.git("log", "-1", "--format=%s"); got != "Initial commit\n" {
			t.Fatalf("subject = %q", got)
		}
	})
	t.Run("configured", func(t *testing.T) {
		f := newInitFx(t, true, nothing())
		f.write("README.md", "x\n")
		f.commitAll("first")
		f.mustRun()
		if got := f.git("log", "-1", "--format=%s"); got != "Add Kogen configuration\n" {
			t.Fatalf("subject = %q", got)
		}
		if !strings.Contains(f.read(".gitignore"), ".kogen/local/") {
			t.Fatalf(".gitignore = %q", f.read(".gitignore"))
		}
	})
	t.Run("already initialized", func(t *testing.T) {
		f := newInitFx(t, true, nothing())
		f.write("README.md", "x\n")
		f.commitAll("first")
		f.mustRun()
		head := f.head()
		out := f.mustRun()
		if !strings.HasPrefix(out, "Kogen is already initialized in "+f.repo+"\n") {
			t.Fatalf("stdout = %q", out)
		}
		if f.head() != head || f.requests() != 1 {
			t.Fatalf("HEAD %s (was %s), requests %d", f.head(), head, f.requests())
		}
	})
}

// TestInitRefusalsAreSysErrorsWithTheirExit: a refusal is a *sys.Error and Init's exit is that
// error's Exit, which kogen's exitFor prints with Render and returns. Nothing is committed.
func TestInitRefusalsAreSysErrorsWithTheirExit(t *testing.T) {
	cases := []struct {
		name, class, reason string
		exit                int
		script              []reply
		arrange             func(f *initFx) string // returns the directory to run in ("" = the repository)
	}{
		{"not a Git repository", "environment", "not_a_git_repo", 3, nil, func(f *initFx) string {
			plain := filepath.Join(f.base, "plain")
			os.MkdirAll(plain, 0o755)
			return plain
		}},
		{"no Git identity", "environment", "git_identity_missing", 3, nil, func(f *initFx) string {
			f.git("config", "--unset", "user.name")
			return ""
		}},
		{"files not committed yet", "environment", "no_commits", 3, nil, func(f *initFx) string {
			f.write("app.txt", "x\n")
			return ""
		}},
		{"uncommitted .gitignore", "environment", "dirty_tree", 5, nil, func(f *initFx) string {
			f.write(".gitignore", "a\n")
			f.commitAll("first")
			f.write(".gitignore", "b\n")
			return ""
		}},
		{"not signed in", "provider", "login", 4, nil, func(f *initFx) string {
			os.RemoveAll(filepath.Join(f.home, ".kogen"))
			f.write("README.md", "x\n")
			f.commitAll("first")
			return ""
		}},
		{"two answers without a valid call", "provider", "init_invalid", 4, []reply{text("hello"), text("again")}, func(f *initFx) string {
			f.write("README.md", "x\n")
			f.commitAll("first")
			return ""
		}},
		{"commit refused", "environment", "commit_failed", 3, []reply{nothing()}, func(f *initFx) string {
			f.write("README.md", "x\n")
			f.commitAll("first")
			f.hook("pre-commit", "exit 1")
			return ""
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newInitFx(t, true, c.script...)
			dir := c.arrange(f)
			head := f.head()
			exit, out, err := f.run(dir)
			e, ok := sys.AsError(err)
			if !ok {
				t.Fatalf("exit %d, error %v (%T); want *sys.Error %s/%s", exit, err, err, c.class, c.reason)
			}
			if e.Class != c.class || e.Reason != c.reason || e.Exit != c.exit || exit != c.exit {
				t.Fatalf("exit %d, error %s (exit %d); want %s/%s (exit %d)", exit, e.Error(), e.Exit, c.class, c.reason, c.exit)
			}
			if !strings.HasPrefix(e.Render(), c.class+"/"+c.reason+": ") {
				t.Fatalf("Render = %q", e.Render())
			}
			if f.head() != head {
				t.Fatalf("HEAD moved from %q to %q", head, f.head())
			}
			if strings.Contains(out, "Commit: ") {
				t.Fatalf("stdout names a commit: %q", out)
			}
		})
	}
}

func wantInterrupted(t *testing.T, exit int, err error, code int) {
	t.Helper()
	var in *sys.Interrupted
	if !errors.As(err, &in) || in.ExitCode() != code || exit != code {
		t.Fatalf("exit %d, error %v (%T); want *sys.Interrupted, exit %d", exit, err, err, code)
	}
}

// TestInitInterruptsExitWithTheSignalsCode: an interrupt of the session is a *sys.Interrupted
// whose exit is the signal's code (SIGINT 130, SIGTERM 143, SIGHUP 129), also while the model
// request is in flight. Nothing is written.
func TestInitInterruptsExitWithTheSignalsCode(t *testing.T) {
	for signal, code := range map[string]int{"SIGINT": 130, "SIGTERM": 143, "SIGHUP": 129} {
		t.Run(signal, func(t *testing.T) {
			f := newInitFx(t, true, nothing())
			f.write("README.md", "x\n")
			f.commitAll("first")
			head := f.head()
			s, _ := f.session("")
			s.Interrupt(signal)
			exit, err := f.runSession(s)
			wantInterrupted(t, exit, err, code)
			if f.exists(".kogen") || f.head() != head {
				t.Fatalf(".kogen written %v, HEAD %s (was %s)", f.exists(".kogen"), f.head(), head)
			}
		})
	}
	t.Run("during the model request", func(t *testing.T) {
		asked := make(chan struct{})
		f := newInitFx(t, true, func(w http.ResponseWriter, r *http.Request) {
			close(asked)
			<-r.Context().Done()
		})
		f.write("README.md", "x\n")
		f.commitAll("first")
		head := f.head()
		s, _ := f.session("")
		go func() {
			<-asked
			s.Interrupt("SIGTERM")
		}()
		exit, err := f.runSession(s)
		wantInterrupted(t, exit, err, 143)
		if f.exists(".kogen") || f.head() != head || f.status() != "" {
			t.Fatalf(".kogen written %v, HEAD %s (was %s), status %q", f.exists(".kogen"), f.head(), head, f.status())
		}
	})
}

// TestInitInternalFailureIsExit70: any other failure is exit 70 with an error that is neither a
// *sys.Error nor a *sys.Interrupted; kogen prints it as controller/internal_error. Here the
// .gitignore Init must write is a directory.
func TestInitInternalFailureIsExit70(t *testing.T) {
	f := newInitFx(t, false)
	if err := os.Mkdir(filepath.Join(f.repo, ".gitignore"), 0o755); err != nil {
		t.Fatal(err)
	}
	exit, _, err := f.run("")
	var in *sys.Interrupted
	if _, ok := sys.AsError(err); ok || err == nil || errors.As(err, &in) {
		t.Fatalf("error %v (%T), want an internal error", err, err)
	}
	if exit != 70 || f.head() != "" {
		t.Fatalf("exit %d, HEAD %q; want 70 and no commit", exit, f.head())
	}
}
