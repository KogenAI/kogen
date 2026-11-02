package build

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real Build against the scripted fake provider or a scripted fake external executor
// (never a live model) and a configured check named go-test whose output depends on app.txt:
// "baseline" and "ready" pass, a value starting with "ordinary" fails like an ordinary test
// failure, anything else fails like a Go test binary that timed out. Nothing sleeps.

const kefpTimedOut = "ok  \tkogen/verify\t1.204s\n" +
	"panic: test timed out after 10m0s\n" +
	"\trunning tests:\n\t\tTestSlowSuite (10m0s)\n\n" +
	"goroutine 34 [running]:\ntesting.(*M).startAlarm.func1()\n\t/usr/local/go/src/testing/testing.go:2484 +0x30c\n" +
	"FAIL\tkogen/build\t600.214s\nFAIL\n"

const kefpOrdinary = "--- FAIL: TestAppIsReady (0.00s)\n    app_test.go:9: app.txt is not ready\nFAIL\nFAIL\tkogen/app\t0.012s\nFAIL\n"

// kefpWrites are the app.txt contents the fake builder writes, one per round.
var kefpWrites = map[string][]string{
	"native-env":          {"slow-1", "slow-2", "slow-3", "slow-4", "slow-5"},
	"native-ordinary":     {"ordinary-1", "ordinary-2", "ready"},
	"native-not-in-a-row": {"slow-1", "ordinary-2", "slow-3", "slow-4", "slow-5", "slow-6", "slow-7"},
	"external-env":        {"slow-1", "slow-2", "slow-3", "slow-4", "slow-5", "slow-6"},
}

// kefpLastInput is the text the builder received last in a request: a user message or the
// output that answers its finish call.
func kefpLastInput(req map[string]any) string {
	items, _ := req["input"].([]any)
	if len(items) == 0 {
		return ""
	}
	it, _ := items[len(items)-1].(map[string]any)
	if s, ok := it["output"].(string); ok {
		return s
	}
	switch c := it["content"].(type) {
	case string:
		return c
	case []any:
		var parts []string
		for _, p := range c {
			if m, ok := p.(map[string]any); ok {
				if s, ok := m["text"].(string); ok {
					parts = append(parts, s)
				}
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func kefpObserve(t *testing.T, mode string) map[string]any {
	writes := kefpWrites[mode]
	out := map[string]any{"mode": mode}
	aux := physical(t, t.TempDir())
	timedOut, ordinary := filepath.Join(aux, "timed-out.txt"), filepath.Join(aux, "ordinary.txt")
	writeFile(t, timedOut, kefpTimedOut, 0o644)
	writeFile(t, ordinary, kefpOrdinary, 0o644)
	script := filepath.Join(aux, "go-test.sh")
	writeFile(t, script, "#!/bin/sh\n"+
		"if grep -qx baseline app.txt || grep -qx ready app.txt; then echo 'ok  \tkogen/app\t0.010s'; exit 0; fi\n"+
		"if grep -q '^ordinary' app.txt; then cat '"+ordinary+"'; exit 1; fi\n"+
		"cat '"+timedOut+"'; exit 1\n", 0o755)
	command := "sh '" + script + "'"
	e := newEnv(t, func(c *project.Config) { c.Checks = []project.Check{{Name: "go-test", Run: command}} })
	out["command"] = command
	start := e.head()
	if mode == "external-env" {
		e.useExecutor("    max_rounds: 6\n")
		start = e.head()
		f := newFakeExecutor(t, func(n int, ctx context.Context, root string, in executor.Input) (executor.RoundResult, error) {
			if n <= len(writes) {
				if err := os.WriteFile(filepath.Join(root, "app.txt"), []byte(writes[n-1]+"\n"), 0o644); err != nil {
					return executor.RoundResult{}, err
				}
			}
			return executor.RoundResult{Ending: executor.EndFinish, Claim: "done"}, nil
		})
		reviews := 0
		a := e.build(withExecutor(f, &reviews))
		out["exit"], out["stdout"] = a.exit, a.out.String()
		inputs := []string{}
		for i, in := range f.seen() {
			if i > 0 {
				inputs = append(inputs, in.Feedback)
			}
		}
		out["rounds"], out["inputs"] = len(f.seen()), inputs
		kefpErr(out, a.err)
	} else {
		f := e.prov
		for i, w := range writes {
			f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": w + "\n"}, "finish", map[string]any{"summary": "round " + itoa(i+1)}))
		}
		a := e.build()
		out["exit"], out["stdout"] = a.exit, a.out.String()
		reqs := f.requests()
		inputs := []string{}
		for i, r := range reqs {
			if i > 0 { // the first request is the brief
				inputs = append(inputs, kefpLastInput(r))
			}
		}
		out["rounds"], out["inputs"] = len(reqs), inputs
		kefpErr(out, a.err)
	}
	id := e.onlyRun()
	res := e.result(id)
	out["outcome"], out["passes"], out["still_failing"] = res["outcome"], res["passes"], res["still_failing"]
	events := eventsNamed(e.events(id), "host_or_base_failure")
	if events == nil {
		events = []map[string]any{}
	}
	out["events"] = events
	out["head_same"] = e.head() == start
	out["candidate"] = e.read("app.txt")
	return out
}

func kefpErr(out map[string]any, err error) {
	out["error"] = ""
	if se, ok := sys.AsError(err); ok {
		out["error"] = se.Render()
	} else if err != nil {
		out["error"] = err.Error()
	}
}

func TestKEnvFailureParkObservation(t *testing.T) {
	dir := os.Getenv("KOGEN_KEFP_OUTPUT")
	if dir == "" {
		t.Fatal("KOGEN_KEFP_OUTPUT is not set")
	}
	for _, mode := range []string{"native-env", "native-ordinary", "native-not-in-a-row", "external-env"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			raw, err := json.Marshal(kefpObserve(t, mode))
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, mode+".json"), raw, 0o600); err != nil {
				t.Fatal(err)
			}
		})
	}
}
