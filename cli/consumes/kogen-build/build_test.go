package consumes

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-build/build"
	"kogen-loop/sys"
)

// landScript writes the candidate and finishes; the independent review then approves.
func (e *env) landScript() {
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}))
	f.then(f.submitReview("approve"))
}

// TestBuildLandsOneCommitAndReturnsExitZero: a landed Build is exit 0 and a nil error, reported on
// stdout by the "landed" line, with exactly one commit that carries the Intent trailer. The
// client of the Deps asked the model and the tools of the Deps reached the acceptance command.
func TestBuildLandsOneCommitAndReturnsExitZero(t *testing.T) {
	e := newEnv(t)
	e.landScript()
	start := e.head()
	a := e.build()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.out)
	}
	id := buildID(t, a.out.String())
	re := regexp.MustCompile(`^building fixture\nlanded fixture [0-9a-f]{8} \(Build ` + id + `\)\n  checks: acceptance 2/2, model not applicable\n  review: approved\n`)
	if !re.MatchString(a.out.String()) {
		t.Fatalf("stdout %q", a.out)
	}
	equal(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	equal(t, "message", e.gitOut("log", "-1", "--format=%B"), "Preserve the fixture\n\nKogen-Intent: fixture")
	equal(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "candidate")
	equal(t, "status", e.gitOut("status", "--porcelain"), "")
	// Deps.Client sent one builder request and one review request; Deps.Tools.Node is the Node the
	// acceptance command ran with.
	equal(t, "requests", len(e.prov.requests()), 2)
	seen, err := os.ReadFile(filepath.Join(e.aux, "node-seen"))
	if err != nil || string(seen) != e.deps().Tools.Node {
		t.Fatalf("acceptance ran with KOGEN_NODE %q (%v), want %q", seen, err, e.deps().Tools.Node)
	}
}

// TestBuildCarriesTheDiagnosticIntoTheBuildersConversation: the optional Input.Context, a
// Diagnostic that kogen reads from `--context <file>`, reaches the builder with its text and its
// source label, and the Build still lands.
func TestBuildCarriesTheDiagnosticIntoTheBuildersConversation(t *testing.T) {
	e := newEnv(t)
	e.landScript()
	const text = "operator diagnostic: the previous attempt stopped at app.txt\n"
	source := filepath.Join(e.aux, "diagnostic.txt")
	a := e.build(func(in *build.Input) {
		in.Context = &build.Diagnostic{Text: text, SourcePath: source, SHA256: sha256Hex(text)}
	})
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.out)
	}
	first := e.prov.requests()[0]
	contains(t, "builder request", first, "operator diagnostic: the previous attempt stopped at app.txt")
	contains(t, "builder request", first, source)
}

// TestBuildRefusesInvalidDiagnosticData: diagnostic data that is not nonblank UTF-8 text with an
// absolute source label and its own SHA-256 is refused before any run or request exists, as
// intent/context_unavailable with exit 2.
func TestBuildRefusesInvalidDiagnosticData(t *testing.T) {
	const text = "data\n"
	good := func() *build.Diagnostic {
		return &build.Diagnostic{Text: text, SourcePath: "/fixture/diagnostic.txt", SHA256: sha256Hex(text)}
	}
	cases := map[string]func(d *build.Diagnostic){
		"wrong checksum":   func(d *build.Diagnostic) { d.SHA256 = strings.Repeat("0", 64) },
		"relative label":   func(d *build.Diagnostic) { d.SourcePath = "diagnostic.txt" },
		"no label":         func(d *build.Diagnostic) { d.SourcePath = "" },
		"blank text":       func(d *build.Diagnostic) { d.Text, d.SHA256 = " \n", sha256Hex(" \n") },
		"invalid UTF-8":    func(d *build.Diagnostic) { d.Text = "\xff"; d.SHA256 = sha256Hex(d.Text) },
		"over 262144 byte": func(d *build.Diagnostic) { d.Text = strings.Repeat("x", 262145); d.SHA256 = sha256Hex(d.Text) },
	}
	for name, corrupt := range cases {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t)
			d := good()
			corrupt(d)
			a := e.build(func(in *build.Input) { in.Context = d })
			refusal := asRefusal(t, a.err)
			if refusal.Exit != 2 || a.exit != 2 || !strings.HasPrefix(refusal.Render(), "intent/context_unavailable: ") {
				t.Fatalf("exit %d, error %q (exit %d)", a.exit, refusal.Render(), refusal.Exit)
			}
			if len(e.runIDs()) != 0 || len(e.prov.requests()) != 0 {
				t.Fatalf("runs %v, requests %d", e.runIDs(), len(e.prov.requests()))
			}
		})
	}
}

// TestBuildRefusalsBeforeARunAreSysErrorsWithTheirExit: a start check that fails is a *sys.Error
// whose Exit is Build's exit, which kogen's exitFor prints with Render and returns. Its lines end
// with the notice that no run was created, and no run and no model request exist.
func TestBuildRefusalsBeforeARunAreSysErrorsWithTheirExit(t *testing.T) {
	cases := []struct {
		name, want string
		exit       int
		prep       func(e *env)
	}{
		{"not approved", "intent/not_approved: fixture is not approved; review it with kogen intent approve fixture\n", 5, func(e *env) {
			os.Remove(filepath.Join(e.root, ".kogen/local/approvals/fixture.json"))
		}},
		{"changed since approval", "intent/changed_since_approval: fixture changed after approval", 1, func(e *env) {
			e.write(".kogen/intents/fixture/acceptance.feature", testFeature+"  # changed\n")
		}},
		{"no intent", "intent/not_found: ", 2, func(e *env) { os.RemoveAll(filepath.Join(e.root, ".kogen/intents")) }},
		{"dirty tree", "environment/dirty_tree: 1 changed path(s) are not part of an Intent; commit, stash or discard them first\n  stray.txt\n", 5, func(e *env) {
			e.write("stray.txt", "x\n")
		}},
		{"no Git identity", "environment/git_identity_missing: ", 3, func(e *env) {
			e.run("git", "config", "--unset", "user.name")
			e.run("git", "config", "--unset", "user.email")
		}},
		{"Git operation in progress", "environment/git_operation_in_progress: a merge is in progress; finish or abort it first\n", 3, func(e *env) {
			e.write(".git/MERGE_HEAD", e.head()+"\n")
		}},
		{"not signed in", "provider/login: ", 4, func(e *env) { os.RemoveAll(filepath.Join(e.home, ".kogen")) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newEnv(t)
			c.prep(e)
			a := e.build()
			refusal := asRefusal(t, a.err)
			if a.exit != c.exit || refusal.Exit != c.exit {
				t.Fatalf("exit %d, error exit %d, want %d\n%s", a.exit, refusal.Exit, c.exit, a.shown())
			}
			contains(t, "rendering", refusal.Render(), c.want)
			if len(e.runIDs()) != 0 || len(e.prov.requests()) != 0 {
				t.Fatalf("runs %v, requests %d", e.runIDs(), len(e.prov.requests()))
			}
		})
	}
}

// TestBuildStoppedByTheProviderIsANonzeroExitWithoutAnError: once a run exists, every end that is
// not a landing and not an interrupt is reported by Build on stdout and returned as a nonzero
// exit code with a nil error; kogen returns that code as it is.
func TestBuildStoppedByTheProviderIsANonzeroExitWithoutAnError(t *testing.T) {
	e := newEnv(t) // the provider's script is empty: it refuses the builder's request
	start := e.head()
	a := e.build()
	if a.err != nil || a.exit == 0 {
		t.Fatalf("exit %d, err %v\n%s", a.exit, a.err, a.out)
	}
	contains(t, "stdout", a.out.String(), "failed fixture: refused (Build ")
	contains(t, "stdout", a.out.String(), "provider/refused: ")
	equal(t, "exit", a.exit, 4)
	id := buildID(t, a.out.String())
	if ids := e.runIDs(); len(ids) != 1 || ids[0] != id {
		t.Fatalf("runs %v, want [%s]", ids, id)
	}
	equal(t, "HEAD", e.head(), start)
}

// TestInterruptedBuildReturnsTheSignalsExitCode: an interrupt of the session while the model
// request is in flight is a *sys.Interrupted whose ExitCode is the signal's code, with the edits
// left in place and the Build id on stdout.
func TestInterruptedBuildReturnsTheSignalsExitCode(t *testing.T) {
	for signal, code := range map[string]int{"SIGINT": 130, "SIGTERM": 143, "SIGHUP": 129} {
		t.Run(signal, func(t *testing.T) {
			e := newEnv(t)
			opened := make(chan struct{})
			e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}), hang(opened))
			a, done := e.start()
			<-opened
			a.s.Interrupt(signal)
			<-done
			var in *sys.Interrupted
			if !errors.As(a.err, &in) || in.ExitCode() != code || a.exit != code {
				t.Fatalf("exit %d, error %v (%T), want *sys.Interrupted with %d", a.exit, a.err, a.err, code)
			}
			contains(t, "stdout", a.out.String(), "stopped fixture: interrupted (Build ")
			equal(t, "app.txt", e.read("app.txt"), "candidate\n")
			if err := a.s.Err(); err == nil {
				t.Fatal("the session records no interrupt")
			}
		})
	}
}
