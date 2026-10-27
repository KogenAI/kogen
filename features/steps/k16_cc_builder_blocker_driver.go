package build

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/executor/claudecode"
	"kogen/project"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real Build over the real Claude Code adapter, against a scripted fake `claude`
// shell program (never the real claude binary).

type k16Undeclared struct{ executor.Executor }

// Describe is the real descriptor with the Blocker capability removed.
func (k k16Undeclared) Describe() executor.Descriptor {
	d := k.Executor.Describe()
	d.Capabilities.Blocker = false
	rc := map[string]executor.RoleCapabilities{}
	for r, c := range d.RoleCapabilities {
		c.Blocker = false
		rc[r] = c
	}
	d.RoleCapabilities = rc
	return d
}

const k16Script = `#!/bin/sh
state="$KOGEN_K16_STATE"
case "$1" in
--version) echo "2.1.306 (Claude Code)"; exit 0;;
auth) echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0;;
esac
n=$(cat "$state/calls" 2>/dev/null || echo 0)
n=$((n+1))
echo $n > "$state/calls"
cat > "$state/prompt-$n"
sid=
prev=
for a in "$@"; do
  if [ "$prev" = --session-id ] || [ "$prev" = --resume ]; then sid=$a; fi
  prev=$a
done
cwd=$(pwd -P)
printf '{"type":"system","subtype":"init","cwd":"%s","session_id":"%s","mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","apiKeySource":"none","claude_code_version":"2.1.306"}\n' "$cwd" "$sid"
if [ -f "$state/round-$n.sh" ]; then sh "$state/round-$n.sh"; fi
sed "s/@SID@/$sid/" "$state/result-$n.json"
`

type k16Round struct {
	action     string
	structured any
}

func k16Fake(t *testing.T, base []string, rounds []k16Round) (claudecode.Options, string) {
	t.Helper()
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "claude")
	if err := os.WriteFile(bin, []byte(k16Script), 0o755); err != nil {
		t.Fatal(err)
	}
	for i, r := range rounds {
		n := i + 1
		if r.action != "" {
			if err := os.WriteFile(filepath.Join(state, fmt.Sprintf("round-%d.sh", n)), []byte(r.action+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		res := map[string]any{
			"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "session_id": "@SID@",
			"result": "round finished", "terminal_reason": "completed", "permission_denials": []any{},
		}
		if r.structured != nil {
			res["structured_output"] = r.structured
		}
		b, err := json.Marshal(res)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(state, fmt.Sprintf("result-%d.json", n)), append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	env := append(append([]string{}, base...), "PATH="+os.Getenv("PATH"), "KOGEN_K16_STATE="+state)
	return claudecode.Options{Binary: bin, HookCommand: []string{"/bin/true"}, Env: env}, state
}

func TestK16Observation(t *testing.T) {
	mode := os.Getenv("KOGEN_K16_MODE")
	out := map[string]any{"mode": mode}
	write := func() {
		raw, err := json.Marshal(out)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(os.Getenv("KOGEN_K16_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if mode == "static" {
		opts, _ := k16Fake(t, os.Environ(), nil)
		d := claudecode.New(opts).Describe()
		out["capabilities_blocker"] = d.Capabilities.Blocker
		roles := map[string]any{}
		for _, r := range []string{executor.RoleBuild, executor.RoleShape, executor.RoleReview} {
			c, ok := d.For(r)
			roles[r] = map[string]any{"served": ok, "blocker": c.Blocker}
		}
		out["roles"] = roles
		out["constraints"] = map[string]any{"build": claudecode.Constraints, "shape": claudecode.ShapeConstraints, "review": claudecode.ReviewConstraints}
		write()
		return
	}

	e := newEnv(t)
	e.useExecutor("    max_rounds: 2\n")
	start := e.head()
	indexPath := filepath.Join(e.root, ".git/index")
	indexBefore, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	approvalPath := project.ApprovalPath(e.root, testSlug)
	approvalBefore, err := os.ReadFile(approvalPath)
	if err != nil {
		t.Fatal(err)
	}

	block := map[string]any{
		"paths":    []any{stepsFile},
		"reason":   "The protected step file runs a wrapper that turns exit 2 into 1, so four scenarios can never pass.",
		"evidence": "Observed acceptance run: the scenario expects exit 2 and the step reports exit 1 from the wrapper.",
	}
	red := "printf 'red\\n' > app.txt"
	rounds := []k16Round{{action: red, structured: map[string]any{"blocker": block}}}
	wrapExec := func(x executor.Executor) executor.Executor { return x }
	switch mode {
	case "protected-step-file":
	case "unprotected-path":
		rounds[0].structured = map[string]any{"blocker": map[string]any{"paths": []any{"app.txt"}, "reason": block["reason"], "evidence": block["evidence"]}}
	case "moved-head":
		rounds[0].action = red + "\ngit commit --allow-empty -qm moved"
	case "undeclared-blocker":
		wrapExec = func(x executor.Executor) executor.Executor { return k16Undeclared{x} }
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	// Later rounds plain-finish, so an implementation that ignores the blocker fails by assertion,
	// not because the fake ran out of script.
	for len(rounds) < 3 {
		rounds = append(rounds, k16Round{})
	}
	opts, state := k16Fake(t, e.git, rounds)
	x := wrapExec(claudecode.New(opts))
	a := e.build(func(in *Input) {
		in.External = func(role project.Role) (executor.Executor, error) { return x, nil }
	})

	out["exit"] = a.exit
	out["stdout"] = a.out.String()
	out["err_class"], out["err_reason"] = "", ""
	if se, ok := sys.AsError(a.err); ok {
		out["err_class"], out["err_reason"] = se.Class, se.Reason
	}
	calls, _ := os.ReadFile(filepath.Join(state, "calls"))
	out["calls"] = strings.TrimSpace(string(calls))
	if p, err := os.ReadFile(filepath.Join(state, "prompt-2")); err == nil {
		out["prompt2"] = string(p)
	} else {
		out["prompt2"] = ""
	}
	id := e.onlyRun()
	_, st := e.checkpoint(id)
	out["blocker"] = st["blocker"]
	out["outcome"] = fmt.Sprint(e.result(id)["outcome"])
	out["app_before_recover"] = e.read("app.txt")
	indexAfter, _ := os.ReadFile(indexPath)
	approvalAfter, aerr := os.ReadFile(approvalPath)
	out["index_same"] = string(indexAfter) == string(indexBefore)
	out["approval_same"] = aerr == nil && string(approvalAfter) == string(approvalBefore)
	out["head_same"] = e.head() == start
	if mode == "protected-step-file" {
		output := filepath.Join(physical(t, t.TempDir()), "archive")
		r := e.recover(id, output)
		out["recover_exit"] = r.exit
		out["recover_shown"] = r.shown()
		out["recover_state"] = ""
		if r.exit == 0 {
			out["recover_state"] = e.jsonFile(filepath.Join(e.root, ".kogen/local/recoveries", id+".json"))["state"]
		}
		out["app_after_recover"] = e.read("app.txt")
	}
	write()
}
