package build

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
	"kogen/verify"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real Build over a scripted fake external executor (never the real claude binary).

// k19Reviewer approves like the stub and counts. With redo it also makes the candidate red again
// right after its first review, so the Build verifies a second time after a green pass.
type k19Reviewer struct {
	approveWithoutReview
	n    *int
	root string
	redo bool
}

func (r k19Reviewer) Review(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
	*r.n++
	ap, err := r.approveWithoutReview.Review(ctx, b, pass)
	if err == nil && r.redo && *r.n == 1 {
		if werr := os.WriteFile(filepath.Join(r.root, "app.txt"), []byte("red\n"), 0o644); werr != nil {
			return Approved{}, werr
		}
	}
	return ap, err
}

func TestK19Observation(t *testing.T) {
	mode := os.Getenv("KOGEN_K19_MODE")
	out := map[string]any{"mode": mode}

	maxRounds := "    max_rounds: 8\n"
	check := ""
	switch mode {
	case "identical":
		check = "echo broken"
	case "changing":
		maxRounds = "    max_rounds: 5\n"
	case "green-reset":
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	e := newEnv(t)
	// The check is green until the fake builder arms it (a marker outside the checkout, so no
	// candidate edit is involved); then it fails with the given text on every pass.
	armed := filepath.Join(e.aux, "armed")
	if mode != "green-reset" {
		if mode == "changing" {
			// The failing text changes on every pass: the counter lives outside the checkout.
			counter := filepath.Join(e.aux, "counter")
			check = "n=$(cat '" + counter + "' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '" + counter + "'; echo \"failure $n\""
		}
		name := map[string]string{"identical": "stuck", "changing": "moving"}[mode]
		cfg, err := project.LoadConfig(e.root)
		if err != nil {
			t.Fatal(err)
		}
		cfg.Checks = []project.Check{{Name: name, Run: "if [ -f '" + armed + "' ]; then " + check + "; exit 1; fi"}}
		e.writeConfig(cfg)
		e.run("git", "add", ".kogen/project.yaml")
		e.run("git", "commit", "-qm", "armed check")
		e.approve()
	}
	e.useExecutor(maxRounds)
	start := e.head()

	f := newFakeExecutor(t, func(n int, ctx context.Context, root string, in executor.Input) (executor.RoundResult, error) {
		if mode != "green-reset" {
			if n == 1 {
				if err := os.WriteFile(armed, []byte("x\n"), 0o644); err != nil {
					return executor.RoundResult{}, err
				}
			}
			return executor.RoundResult{Ending: executor.EndFinish, Claim: "done"}, nil
		}
		content := ""
		switch n {
		case 1:
			content = "red\n"
		case 3:
			content = "candidate\n"
		}
		if content != "" {
			if err := os.WriteFile(filepath.Join(root, "app.txt"), []byte(content), 0o644); err != nil {
				return executor.RoundResult{}, err
			}
		}
		return executor.RoundResult{Ending: executor.EndFinish, Claim: "done"}, nil
	})
	reviews := 0
	a := e.build(func(in *Input) {
		in.External = func(role project.Role) (executor.Executor, error) { return f, nil }
		in.Reviewer = k19Reviewer{n: &reviews, root: e.root, redo: mode == "green-reset"}
	})

	out["exit"] = a.exit
	out["stdout"] = a.out.String()
	out["err_class"], out["err_reason"] = "", ""
	if se, ok := sys.AsError(a.err); ok {
		out["err_class"], out["err_reason"] = se.Class, se.Reason
	}
	out["rounds"] = len(f.seen())
	out["reviews"] = reviews
	out["head_same"] = e.head() == start
	id := e.onlyRun()
	out["outcome"] = fmt.Sprint(e.result(id)["outcome"])
	events := e.events(id)
	np := eventsNamed(events, "executor_no_progress")
	if np == nil {
		np = []map[string]any{}
	}
	out["no_progress"] = np
	npAt, outcomeAt := -1, -1
	for i, ev := range events {
		switch ev["event"] {
		case "executor_no_progress":
			if npAt < 0 {
				npAt = i
			}
		case "outcome":
			outcomeAt = i
		}
	}
	out["no_progress_before_outcome"] = npAt >= 0 && outcomeAt > npAt
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_K19_OUTPUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}
