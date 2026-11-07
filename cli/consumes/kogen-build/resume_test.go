package consumes

import (
	"strings"
	"testing"
)

// interrupted stops a Build at its second model request, after the first one wrote the
// candidate, and returns the Build's id.
func (e *env) interrupted(t *testing.T) string {
	t.Helper()
	opened := make(chan struct{})
	e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}), hang(opened))
	a, done := e.start()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	equal(t, "interrupted exit", a.exit, 130)
	return buildID(t, a.out.String())
}

// TestResumeContinuesAStoppedBuildAndLandsWithExitZero: Resume takes the Build's id, runs as a new
// run with the Deps of its input (the client asks the model again), reports the landing on stdout
// and returns exit 0 with a nil error. Resuming the landed run is a successful no-op that names
// its commit.
func TestResumeContinuesAStoppedBuildAndLandsWithExitZero(t *testing.T) {
	e := newEnv(t)
	start := e.head()
	id := e.interrupted(t)
	equal(t, "HEAD", e.head(), start)
	before := len(e.prov.requests())

	e.prov.replace(e.prov.calls("finish", map[string]any{"summary": "done"}), e.prov.submitReview("approve"))
	r := e.resume(id)
	if r.exit != 0 || r.err != nil {
		t.Fatalf("exit %d err %v\n%s", r.exit, r.err, r.out)
	}
	contains(t, "stdout", r.out.String(), "resuming Build "+id+" as ")
	contains(t, "stdout", r.out.String(), "landed fixture ")
	if got := len(e.prov.requests()); got <= before {
		t.Fatalf("requests %d, want more than %d: the client did not ask the model", got, before)
	}
	equal(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	equal(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "candidate")

	child := ""
	for _, c := range e.runIDs() {
		if c != id {
			child = c
		}
	}
	commit := e.head()
	again := e.resume(child)
	if again.exit != 0 || again.err != nil {
		t.Fatalf("exit %d err %v\n%s", again.exit, again.err, again.out)
	}
	equal(t, "stdout", again.out.String(), "Build "+child+" already landed "+commit+"\n")
}

// TestResumeRefusalsAreSysErrorsWithTheirExit: a resume that cannot continue is a *sys.Error whose
// Exit is Resume's exit, with the notice that no run was created. An id that is not a Build id, or has
// no recorded Build, is candidate/resume_unsupported; a checkpoint whose HEAD moved is candidate/resume_refused. Both
// exit 1, and nothing is asked of the model.
func TestResumeRefusalsAreSysErrorsWithTheirExit(t *testing.T) {
	t.Run("unknown id", func(t *testing.T) {
		e := newEnv(t)
		for id, want := range map[string]string{
			"nothex":   "candidate/resume_unsupported: \"nothex\" is not a Build id; a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d; kogen intent list lists Build attempts",
			"00000000": "candidate/resume_unsupported: Build 00000000: no Build with this id in this checkout; kogen intent list lists Build attempts",
		} {
			r := e.resume(id)
			refusal := asRefusal(t, r.err)
			if r.exit != 1 || refusal.Exit != 1 || !strings.HasPrefix(refusal.Render(), want) {
				t.Fatalf("id %q: exit %d, error %q (exit %d), want prefix %q", id, r.exit, refusal.Render(), refusal.Exit, want)
			}
			contains(t, "rendering", refusal.Render(), "no newly created Build run")
		}
		equal(t, "runs", len(e.runIDs()), 0)
	})
	t.Run("HEAD moved", func(t *testing.T) {
		e := newEnv(t)
		id := e.interrupted(t)
		requests := len(e.prov.requests())
		e.run("git", "commit", "-q", "--allow-empty", "-m", "moved")
		r := e.resume(id)
		refusal := asRefusal(t, r.err)
		if r.exit != 1 || refusal.Exit != 1 || !strings.HasPrefix(refusal.Render(), "candidate/resume_refused: Build "+id+": HEAD moved") {
			t.Fatalf("exit %d, error %q (exit %d)", r.exit, refusal.Render(), refusal.Exit)
		}
		equal(t, "requests", len(e.prov.requests()), requests)
	})
}
