package build

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/executor"
)

// Observation only: it is mounted as a test with go -overlay and changes no production source.
// It raises `timeout: 600` to `timeout: 1800` with no profile through the native and the
// external review routes and records what each reviewer was sent.
func TestK14LimitRaiseObservation(t *testing.T) {
	const before, after = "timeout: 600\n", "timeout: 1800\n"
	seed := func(e *env) {
		e.write("ci.yml", before)
		e.run("git", "add", "ci.yml")
		e.run("git", "commit", "-qm", "add ci")
	}
	obs := map[string]any{}

	{
		e := newEnv(t)
		seed(e)
		f := e.prov
		f.then(f.calls("write_file", map[string]any{"path": "ci.yml", "content": after}, "finish", map[string]any{"summary": "raised the timeout"}))
		f.then(submit(f, "approve"))
		a := e.reviewed()
		var instructions, material string
		n := 0
		for _, req := range f.requests() {
			tools, _ := json.Marshal(req["tools"])
			if strings.Contains(string(tools), `"name":"submit_review"`) {
				if n == 0 {
					instructions, material = requestInstructions(req), requestText(req)
				}
				n++
			}
		}
		obs["native"] = map[string]any{"exit": a.exit, "requests": n, "instructions": instructions, "material": material, "output": a.shown()}
	}

	{
		e := newEnv(t)
		seed(e)
		e.useLineup("")
		f := newLineupExec(t)
		f.build = func(n int, root string, in executor.Input) (executor.RoundResult, error) {
			if err := os.WriteFile(filepath.Join(root, "ci.yml"), []byte(after), 0o644); err != nil {
				return executor.RoundResult{}, err
			}
			return executor.RoundResult{Ending: executor.EndFinish, Claim: "raised the timeout"}, nil
		}
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
		a := e.build(withLineup(f))
		tasks := f.starts[executor.RoleReview]
		ext := map[string]any{"exit": a.exit, "requests": len(tasks), "output": a.shown()}
		if len(tasks) > 0 {
			ext["stable"], ext["dynamic"] = tasks[0].Brief.Stable, tasks[0].Brief.Dynamic
		}
		obs["external"] = ext
	}

	b, err := json.Marshal(obs)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_K14_OUTPUT"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}
