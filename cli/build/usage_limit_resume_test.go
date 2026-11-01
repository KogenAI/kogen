package build

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen/executor"
	"kogen/project"
)

func TestUsageLimitResumeSafety(t *testing.T) {
	e := newEnv(t)
	e.useExecutor("")
	start := e.head()
	calls := 0
	reviews := 0
	f := newFakeExecutor(t, func(n int, ctx context.Context, root string, in executor.Input) (executor.RoundResult, error) {
		calls++
		switch calls {
		case 1:
			return externalWritesApp("red\n", harnessUsage(5, 1, 2, 0.1))(n, ctx, root, in)
		case 2, 3:
			if err := os.WriteFile(filepath.Join(root, "partial.txt"), []byte("partial"), 0644); err != nil {
				t.Fatal(err)
			}
			return executor.RoundResult{}, executor.Fail(executor.ReasonUsageLimit, "synthetic limit")
		default:
			return externalWritesApp("candidate\n", harnessUsage(5, 1, 2, 0.1))(n, ctx, root, in)
		}
	})
	inject := func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { return f, nil }
		in.Reviewer = countingReviewer{approveWithoutReview{}, &reviews}
	}
	a := e.build(withExecutor(f, &reviews))
	if a.exit == 0 || calls != 2 || !strings.Contains(a.shown(), "executor/usage_limit") {
		t.Fatalf("first stop %d %d %s", a.exit, calls, a.shown())
	}
	id := e.onlyRun()
	old := e.runFiles(id)
	if e.head() != start || e.read("partial.txt") != "partial" {
		t.Fatal("lost candidate")
	}
	_, st := e.checkpoint(id)
	if st["round"] != float64(2) || st["pass"] != float64(1) {
		t.Fatalf("state %v", st)
	}
	// A changed candidate must be refused before creating a run or changing custody.
	e.write("app.txt", "drift\n")
	before := e.state()
	r := e.resume(id, inject)
	if r.exit == 0 || !strings.Contains(r.shown(), "candidate/resume_refused") || !reflect.DeepEqual(before, e.state()) || calls != 2 {
		t.Fatalf("drift refusal: %s", r.shown())
	}
	e.write("app.txt", "red\n")
	r = e.resume(id, inject)
	if r.exit == 0 || calls != 3 || !strings.Contains(r.shown(), "executor/usage_limit") {
		t.Fatalf("second stop %d %d %s", r.exit, calls, r.shown())
	}
	var child string
	for _, x := range e.runIDs() {
		if x != id {
			child = x
		}
	}
	if child == "" {
		t.Fatal("missing child")
	}
	if !reflect.DeepEqual(old, e.runFiles(id)) {
		t.Fatal("prior evidence changed")
	}
	_, st = e.checkpoint(child)
	if st["round"] != float64(2) || st["pass"] != float64(1) {
		t.Fatalf("repeated stop %v", st)
	}
	r = e.resume(child, inject)
	if r.exit != 0 || calls != 4 || reviews != 1 {
		t.Fatalf("resume %d calls %d reviews %d: %s", r.exit, calls, reviews, r.shown())
	}
	if !strings.Contains(r.errs.String(), "fresh conversation") || !strings.Contains(f.tasks[2].Brief.Dynamic, "Previous verification feedback") {
		t.Fatalf("missing fresh-session feedback stdout=%s stderr=%s dynamic=%s", r.shown(), r.errs, f.tasks[2].Brief.Dynamic)
	}
	if e.gitOut("rev-list", "--count", start+"..HEAD") != "1" {
		t.Fatal("delivery not one commit")
	}
}
