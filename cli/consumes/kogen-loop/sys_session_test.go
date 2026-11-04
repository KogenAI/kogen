package consumes

import (
	"context"
	"io"
	"os"
	"slices"
	"testing"

	"kogen-loop/sys"
)

// Signatures kogen's callers use: cli/engine.go, cli/native.go, cli/main.go and
// cli/readiness/readiness.go.
var (
	_ func() *sys.Session                                                 = sys.New
	_ func([]string)                                                      = sys.MaybeSupervise
	_ func()                                                              = sys.EnableSupervisor
	_ func([]int)                                                         = sys.Terminate
	_ func(string, string, string, int) *sys.Error                        = sys.Fail
	_ func(error) (*sys.Error, bool)                                      = sys.AsError
	_ func(*sys.Session) context.Context                                  = (*sys.Session).Context
	_ func(*sys.Session, string)                                          = (*sys.Session).Debug
	_ func(*sys.Session) error                                            = (*sys.Session).Err
	_ func(*sys.Session, string) string                                   = (*sys.Session).Getenv
	_ func(*sys.Session) []int                                            = (*sys.Session).Groups
	_ func(*sys.Session, string)                                          = (*sys.Session).Out
	_ func(*sys.Session, string)                                          = (*sys.Session).Puts
	_ func(*sys.Session, string, string, sys.Options) (sys.Result, error) = (*sys.Session).Run
	_ func(*sys.Session) func()                                           = (*sys.Session).WatchSignals
	_ func(*sys.Error) string                                             = (*sys.Error).Render
	_ func(*sys.Interrupted) int                                          = (*sys.Interrupted).ExitCode
)

// TestNewTakesTheProcessEnvironmentAndDirectory: sys.New is the session kogen's runEngine makes:
// its Env is the process's environment (here with TestMain's HOME), its Cwd the working
// directory, and nothing has been interrupted or started.
func TestNewTakesTheProcessEnvironmentAndDirectory(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	s := sys.New()
	if s.Cwd != cwd {
		t.Fatalf("Cwd = %q, want %q", s.Cwd, cwd)
	}
	if !slices.Equal(s.Env, os.Environ()) {
		t.Fatalf("Env differs from the process environment")
	}
	if s.Getenv("HOME") != os.Getenv("HOME") || s.Getenv("HOME") == "" {
		t.Fatalf("Getenv(HOME) = %q, want %q", s.Getenv("HOME"), os.Getenv("HOME"))
	}
	if err := s.Err(); err != nil {
		t.Fatalf("Err = %v before any interrupt", err)
	}
	if s.Context().Err() != nil {
		t.Fatalf("Context is done before any interrupt")
	}
	if got := s.Groups(); len(got) != 0 {
		t.Fatalf("Groups = %v before any command", got)
	}
}

// TestGetenvReadsTheSessionsEnvironment: Getenv is the caller's value for a name, "" when the
// name is not set, with the whole text after the first "=" as the value, and the last of two
// settings of one name wins (kogen's callers add their own HOME after the process's).
func TestGetenvReadsTheSessionsEnvironment(t *testing.T) {
	f := newFixture(t)
	f.s.Env = []string{"A=1", "B=x=y", "A=2", "EMPTY="}
	for name, want := range map[string]string{"A": "2", "B": "x=y", "EMPTY": "", "MISSING": ""} {
		if got := f.s.Getenv(name); got != want {
			t.Fatalf("Getenv(%q) = %q, want %q", name, got, want)
		}
	}
}

// TestOutAndPutsWriteToStandardOutput: Out writes its text unchanged, Puts one line, both to
// the standard output the process had when sys.New made the session.
func TestOutAndPutsWriteToStandardOutput(t *testing.T) {
	f := newFixture(t)
	f.s.Out("a")
	f.s.Puts("b")
	f.s.Out("c\n")
	f.s.Puts("")
	if got := f.out(); got != "ab\nc\n\n" {
		t.Fatalf("standard output = %q", got)
	}
	if f.stderr.Len() != 0 {
		t.Fatalf("standard error = %q", f.stderr.String())
	}
}

// TestStderrIsWhereKogenWritesNotices: Stderr is an io.Writer the caller can replace, and the
// session writes its debug lines there.
func TestStderrIsWhereKogenWritesNotices(t *testing.T) {
	f := newFixture(t)
	var w io.Writer = f.s.Stderr
	io.WriteString(w, "kogen: notice\n")
	if got := f.stderr.String(); got != "kogen: notice\n" {
		t.Fatalf("standard error = %q", got)
	}
}

// TestDebugWritesOnlyWhenTheCallerAsksForDebugLogging: a "[debug] " line on standard error when
// KOGEN_LOG_LEVEL=debug is in the session's environment, nothing otherwise.
func TestDebugWritesOnlyWhenTheCallerAsksForDebugLogging(t *testing.T) {
	quiet := newFixture(t)
	quiet.s.Debug("kogen init in " + quiet.s.Cwd)
	if quiet.stderr.Len() != 0 {
		t.Fatalf("debug line without KOGEN_LOG_LEVEL: %q", quiet.stderr.String())
	}
	loud := newFixture(t, "KOGEN_LOG_LEVEL=debug")
	loud.s.Debug("kogen init in /work")
	if got := loud.stderr.String(); got != "[debug] kogen init in /work\n" {
		t.Fatalf("debug line = %q", got)
	}
	if loud.out() != "" {
		t.Fatalf("standard output = %q", loud.out())
	}
}
