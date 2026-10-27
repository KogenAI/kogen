package build

import (
	"context"
	"testing"

	"kogen/executor"
)

func countEvents(evs []map[string]any, name string) int {
	n := 0
	for _, ev := range evs {
		if ev["event"] == name {
			n++
		}
	}
	return n
}

func TestExternalNoProgressStopsOnThirdIdenticalRed(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useExecutor("    max_rounds: 6\n")
	reviews := 0
	f := newFakeExecutor(t, externalWritesApp("red\n", harnessUsage(1, 0, 1, 0)))
	a := e.build(withExecutor(f, &reviews))
	if a.exit != 1 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	contains(t, "stdout", a.out.String(), "candidate/executor_round_limit")
	eq(t, "rounds", len(f.seen()), 3)
	eq(t, "reviews", reviews, 0)
	id := e.onlyRun()
	evs := e.events(id)
	eq(t, "events", countEvents(evs, "executor_no_progress"), 1)
	eq(t, "outcome", e.result(id)["outcome"], any("executor_round_limit"))
}

func TestExternalNoProgressResetsWhenTheTreeChanges(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useExecutor("    max_rounds: 4\n")
	reviews := 0
	f := newFakeExecutor(t, func(n int, ctx context.Context, root string, in executor.Input) (executor.RoundResult, error) {
		content := "red\n"
		if n%2 == 0 {
			content = "red\nextra\n"
		}
		return externalWritesApp(content, harnessUsage(1, 0, 1, 0))(n, ctx, root, in)
	})
	a := e.build(withExecutor(f, &reviews))
	if a.exit != 1 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	eq(t, "rounds", len(f.seen()), 4)
	eq(t, "events", countEvents(e.events(e.onlyRun()), "executor_no_progress"), 0)
}
