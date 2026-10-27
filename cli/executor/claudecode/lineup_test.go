package claudecode

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"kogen/executor"
	"kogen/executor/conformance"
)

const lineupSchema = `{"type":"object","properties":{"verdict":{"type":"string"}}}`

var lineupRoles = []string{executor.RoleShape, executor.RoleBuild, executor.RoleReview}

// roleHarness is a harness whose task performs role.
func roleHarness(t *testing.T, role string, cfg fakeConfig) *harness {
	t.Helper()
	h := newHarness(t, cfg)
	h.task.Role = role
	if role != executor.RoleBuild {
		h.task.Schema = json.RawMessage(lineupSchema)
	}
	return h
}

func structuredRound(structured string) conformance.RoundScript {
	r := finishRound
	r.Structured = json.RawMessage(structured)
	return r
}

func hasArg(args []string, a string) bool { return slices.Contains(args, a) }

func argAfter(args []string, a string) string {
	for i, x := range args {
		if x == a && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

// TestClaudeLineupRoleProtocol: kogen.executor/v2 describes every role separately and truthfully;
// Shape and Review request schema-constrained output and consume only the final result's
// structured_output object; Build keeps its textual claim.
func TestClaudeLineupRoleProtocol(t *testing.T) {
	t.Parallel()
	t.Run("descriptor", func(t *testing.T) {
		d := New(newHarness(t, fakeConfig{}).f.options()).Describe()
		if d.Contract != "kogen.executor/v2" {
			t.Fatalf("contract %q", d.Contract)
		}
		for _, role := range lineupRoles {
			if err := d.ValidateRole(role); err != nil {
				t.Fatalf("%s: %v", role, err)
			}
			c, ok := d.For(role)
			if !ok || c.Resume != executor.ResumeNone || !c.Continuation || c.Usage != executor.UsageHarness || c.Images || c.Probe || c.Workers || c.Blocker != (role == executor.RoleBuild) {
				t.Fatalf("%s capabilities %+v", role, c)
			}
			if want := role != executor.RoleBuild; c.Structured != want {
				t.Fatalf("%s structured %v", role, c.Structured)
			}
			joined := strings.Join(c.Limitations, "|")
			for _, must := range []string{"exact persistent resume", "typed images", "scratch probe", "working-window"} {
				if !strings.Contains(joined, must) {
					t.Errorf("%s limitations omit %q: %v", role, must, c.Limitations)
				}
			}
		}
		if s, _ := d.For(executor.RoleShape); !strings.Contains(strings.Join(s.Limitations, "|"), "no Shape workers") {
			t.Errorf("shape limitations %v", s.Limitations)
		}
		// The aggregate is still the Build claim; no role is inferred from it.
		if !reflect.DeepEqual(d.Capabilities.Roles, []string{executor.RoleBuild}) {
			t.Fatalf("aggregate roles %v", d.Capabilities.Roles)
		}
		if err := (executor.Descriptor{Name: "x", Contract: "kogen.executor/v1", Capabilities: d.Capabilities}).ValidateRole("build"); err == nil {
			t.Fatal("a v1 descriptor was accepted")
		}
		if err := (executor.Descriptor{Name: "x", Contract: executor.Contract, Capabilities: d.Capabilities}).ValidateRole(executor.RoleReview); err == nil {
			t.Fatal("a Build-only descriptor was accepted for Review")
		}
	})

	t.Run("structured roles need a schema", func(t *testing.T) {
		for _, role := range []string{executor.RoleShape, executor.RoleReview} {
			h := newHarness(t, fakeConfig{})
			h.task.Role = role
			_, err := h.start(h.f.options())
			wantError(t, err, "executor/unavailable")
			h.task.Schema = json.RawMessage(`[1]`)
			_, err = h.start(h.f.options())
			wantError(t, err, "executor/unavailable")
		}
		h := newHarness(t, fakeConfig{})
		h.task.Role = "planner"
		_, err := h.start(h.f.options())
		wantError(t, err, "executor/unavailable")
	})

	t.Run("argv and the final structured object", func(t *testing.T) {
		body := strings.Repeat("Ünï ✓ a long file body\n", 20000) // far over the Build claim limit
		sub := map[string]any{"files": []any{map[string]any{"path": "a.js", "content": body}}, "n": 2}
		raw, _ := json.Marshal(sub)
		for _, role := range []string{executor.RoleShape, executor.RoleReview} {
			t.Run(role, func(t *testing.T) {
				h := roleHarness(t, role, fakeConfig{Script: conformance.Script{Rounds: []conformance.RoundScript{structuredRound(string(raw)), structuredRound(`{"verdict":"approve"}`)}}})
				s := h.startOK()
				res, err := s.Round(context.Background(), executor.Input{})
				if err != nil {
					t.Fatal(err)
				}
				var got map[string]any
				if err := json.Unmarshal(res.Structured, &got); err != nil || got["files"].([]any)[0].(map[string]any)["content"] != body || got["n"].(float64) != 2 {
					t.Fatalf("structured submission clipped or altered (%d bytes, %v)", len(res.Structured), err)
				}
				a1 := h.f.argv(1)
				if argAfter(a1, "--json-schema") != lineupSchema || argAfter(a1, "--session-id") != s.Handle().SessionID {
					t.Fatalf("round 1 argv %v", a1)
				}
				for _, bad := range []string{"--resume", "--continue", "--fork-session", "--bare"} {
					if hasArg(a1, bad) {
						t.Fatalf("round 1 has %s", bad)
					}
				}
				if got := argAfter(a1, "--append-system-prompt"); got != constraintsFor(role) || got == Constraints {
					t.Fatalf("constraints %q", got)
				}
				if !strings.HasPrefix(string(h.f.prompt(1)), constraintsFor(role)+"\n\nSTABLE brief") {
					t.Fatalf("prompt %q", h.f.prompt(1)[:80])
				}
				res2, err := s.Round(context.Background(), executor.Input{Feedback: "feedback"})
				if err != nil || string(res2.Structured) != `{"verdict":"approve"}` {
					t.Fatalf("round 2 %v %s", err, res2.Structured)
				}
				a2 := h.f.argv(2)
				if argAfter(a2, "--resume") != s.Handle().SessionID || argAfter(a2, "--json-schema") != lineupSchema || hasArg(a2, "--session-id") || hasArg(a2, "--continue") || hasArg(a2, "--fork-session") {
					t.Fatalf("round 2 argv %v", a2)
				}
				if res.Handle.Role != role {
					t.Fatalf("handle role %q", res.Handle.Role)
				}
			})
		}
	})

	t.Run("a text claim is never a submission", func(t *testing.T) {
		for _, role := range []string{executor.RoleShape, executor.RoleReview} {
			for name, result := range map[string]map[string]any{
				"absent":      {},
				"null":        {"structured_output": nil},
				"string":      {"structured_output": "approve"},
				"array":       {"structured_output": []any{1}},
				"text object": {"result": `{"verdict":"approve"}`},
			} {
				t.Run(role+" "+name, func(t *testing.T) {
					h := roleHarness(t, role, fakeConfig{Script: oneRound(finishRound), Result: result})
					s := h.startOK()
					_, err := s.Round(context.Background(), executor.Input{})
					wantError(t, err, "executor/protocol")
				})
			}
		}
	})

	t.Run("an error result carries no submission", func(t *testing.T) {
		r := structuredRound(`{"verdict":"approve"}`)
		r.HarnessError = true
		h := roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(r)})
		_, err := h.startOK().Round(context.Background(), executor.Input{})
		wantError(t, err, "executor/failed")
		r = structuredRound(`{"verdict":"approve"}`)
		r.End = "no_call"
		h = roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(r)})
		res, err := h.startOK().Round(context.Background(), executor.Input{})
		if err != nil || res.Ending != executor.EndNoCall || len(res.Structured) != 0 {
			t.Fatalf("turn limit: %v %+v", err, res)
		}
	})

	t.Run("build keeps its claim, asks for the build schema and may report a blocker", func(t *testing.T) {
		h := roleHarness(t, executor.RoleBuild, fakeConfig{Script: oneRound(finishRound)})
		res, err := h.startOK().Round(context.Background(), executor.Input{})
		if err != nil || res.Ending != executor.EndFinish || res.Claim != "done" || len(res.Structured) != 0 || res.Blocker != nil ||
			argAfter(h.f.argv(1), "--json-schema") != BuildSchema {
			t.Fatalf("%v %+v %v", err, res, h.f.argv(1))
		}
		if argAfter(h.f.argv(1), "--append-system-prompt") != Constraints {
			t.Fatal("Build constraints changed")
		}
		for name, c := range map[string]struct {
			structured any
			want       *executor.BlockerClaim
			ending     executor.Ending
		}{
			"null":       {map[string]any{"blocker": nil}, nil, executor.EndFinish},
			"summary":    {map[string]any{"summary": "x"}, nil, executor.EndFinish},
			"valid":      {map[string]any{"blocker": map[string]any{"paths": []any{"a"}, "reason": "r", "evidence": "e"}}, &executor.BlockerClaim{Paths: []string{"a"}, Reason: "r", Evidence: "e"}, executor.EndBlocker},
			"extra key":  {map[string]any{"blocker": map[string]any{"paths": []any{"a"}, "reason": "r", "evidence": "e", "x": 1}}, &executor.BlockerClaim{}, executor.EndBlocker},
			"missing":    {map[string]any{"blocker": map[string]any{"paths": []any{"a"}, "reason": "r"}}, &executor.BlockerClaim{}, executor.EndBlocker},
			"wrong type": {map[string]any{"blocker": map[string]any{"paths": "a", "reason": "r", "evidence": "e"}}, &executor.BlockerClaim{}, executor.EndBlocker},
		} {
			raw, _ := json.Marshal(c.structured)
			r := finishRound
			r.Structured = raw
			h := roleHarness(t, executor.RoleBuild, fakeConfig{Script: oneRound(r)})
			res, err := h.startOK().Round(context.Background(), executor.Input{})
			if err != nil || res.Ending != c.ending || res.Claim != "done" || !reflect.DeepEqual(res.Blocker, c.want) {
				t.Fatalf("%s: %v %+v", name, err, res)
			}
		}
	})

	t.Run("shape and review never end with a blocker", func(t *testing.T) {
		for _, role := range []string{executor.RoleShape, executor.RoleReview} {
			h := roleHarness(t, role, fakeConfig{Script: oneRound(structuredRound(`{"blocker":{"paths":["a"],"reason":"r","evidence":"e"}}`))})
			res, err := h.startOK().Round(context.Background(), executor.Input{})
			if err != nil || res.Ending != executor.EndFinish || res.Blocker != nil {
				t.Fatalf("%s: %v %+v", role, err, res)
			}
		}
	})
}

func TestBuildConstraintsCarryTheBlockerWords(t *testing.T) {
	t.Parallel()
	for _, w := range []string{
		"blocker field of your structured final result",
		"exact protected paths, a concrete reason and observed command/step/error evidence",
		"Do not change production semantics solely to accommodate a demonstrated bad fixture.",
		"stops as BUILDER-REPORTED build_blocked with candidate/index/approval preserved; it is not independently proven and grants no protected edits, automatic refinement or approval",
		"Plain blocked text does not stop the Build.",
		"Do not edit the protected paths named in the task",
	} {
		if !strings.Contains(Constraints, w) {
			t.Fatalf("missing %q", w)
		}
	}
	if strings.Contains(ShapeConstraints+ReviewConstraints, "blocker") {
		t.Fatal("shape/review constraints changed")
	}
}

// TestClaudeLineupRoleCustody: every role gets its own fresh session, the same stripping, auth,
// version and process custody, and nullable harness usage; Shape may not write at all.
func TestClaudeLineupRoleCustody(t *testing.T) {
	t.Parallel()
	t.Run("fresh independent sessions and inspectable identity", func(t *testing.T) {
		seen := map[string]string{}
		for _, role := range lineupRoles {
			h := roleHarness(t, role, fakeConfig{Script: oneRound(structuredRound(`{"verdict":"approve"}`))})
			s := h.startOK()
			id := s.Handle().SessionID
			if !uuidRe.MatchString(id) {
				t.Fatalf("%s session %q", role, id)
			}
			if prev, dup := seen[id]; dup {
				t.Fatalf("%s shares session %s with %s", role, id, prev)
			}
			seen[id] = role
			res, err := s.Round(context.Background(), executor.Input{})
			if err != nil {
				t.Fatal(err)
			}
			started := h.eventsNamed("executor_started")[0]
			if started["role"] != role || started["session_id"] != id || started["claude_code_version"] != "2.1.306 (Claude Code)" || started["model"] != "claude-sonnet-5-5" {
				t.Fatalf("%s started %v", role, started)
			}
			if auth := started["auth"].(map[string]any); auth["auth_method"] != "claude.ai" || auth["api_provider"] != "firstParty" {
				t.Fatalf("%s auth %v", role, auth)
			}
			ended := h.eventsNamed("executor_round_ended")[0]
			if ended["role"] != role || ended["model"] != "claude-sonnet-5-5" || res.Usage.Model != "claude-sonnet-5-5" {
				t.Fatalf("%s ended %v", role, ended)
			}
			if res.Usage.Source != executor.UsageHarness {
				t.Fatalf("usage %+v", res.Usage)
			}
		}
		if len(seen) != 3 {
			t.Fatalf("sessions %v", seen)
		}
	})

	t.Run("environment stripping, auth and version per role", func(t *testing.T) {
		for _, role := range lineupRoles {
			var extra []string
			for _, k := range stripEnv {
				extra = append(extra, k+"=must-not-reach-claude")
			}
			h := roleHarness(t, role, fakeConfig{Script: oneRound(structuredRound(`{}`))})
			s, err := h.start(h.f.options(extra...))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
				t.Fatal(err)
			}
			s.Close()
			for _, kv := range h.f.env(1) {
				k, _, _ := strings.Cut(kv, "=")
				if slices.Contains(stripEnv, k) {
					t.Errorf("%s: %s reached the child", role, k)
				}
			}
			for name, cfg := range map[string]fakeConfig{
				"logged out":   {Auth: `{"loggedIn":false}`},
				"api key":      {Auth: `{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}`},
				"bedrock":      {Auth: `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}`},
				"api key init": {Script: oneRound(conformance.RoundScript{End: "finish", APIKeyAuth: true})},
			} {
				h := roleHarness(t, role, cfg)
				s, err := h.start(h.f.options())
				if name == "api key init" {
					if err != nil {
						t.Fatal(err)
					}
					_, err = s.Round(context.Background(), executor.Input{})
					s.Close()
				}
				wantError(t, err, "executor/auth_refused")
			}
			old := roleHarness(t, role, fakeConfig{Version: "2.1.294 (Claude Code)"})
			_, err = old.start(old.f.options())
			wantError(t, err, "executor/unavailable")
			odd := roleHarness(t, role, fakeConfig{Version: "garbage\nmore"})
			_, err = odd.start(odd.f.options())
			wantError(t, err, "executor/unavailable")
		}
	})

	t.Run("usage stays nullable", func(t *testing.T) {
		r := structuredRound(`{}`)
		r.Usage = nil
		h := roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(r)})
		res, err := h.startOK().Round(context.Background(), executor.Input{})
		if err != nil || res.Usage.State != executor.UsageUnknown || res.Usage.Input != nil || res.Usage.Output != nil || res.Usage.CostUSD != nil {
			t.Fatalf("%v %+v", err, res.Usage)
		}
	})

	t.Run("shape is read-only, review keeps the protected paths", func(t *testing.T) {
		write := func(path string) conformance.RoundScript {
			r := structuredRound(`{}`)
			r.Actions = []conformance.Action{{Write: &conformance.WriteAction{Path: path, Content: "x\n"}}}
			return r
		}
		h := roleHarness(t, executor.RoleShape, fakeConfig{Script: oneRound(write("proposed.txt"))})
		if _, err := h.startOK().Round(context.Background(), executor.Input{}); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Lstat(filepath.Join(h.root, "proposed.txt")); err == nil {
			t.Fatal("the shaper wrote into the checkout")
		}
		recs, _ := readSentinels(filepath.Join(h.task.Dir, "hook-log.jsonl"), mustPolicyNonce(t, h.task.Dir))
		denied := 0
		for _, r := range recs {
			if r.Decision == "deny" {
				denied++
			}
		}
		if denied != 1 {
			t.Fatalf("hook decisions %v", recs)
		}
		h = roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(write("repair.txt"))})
		if _, err := h.startOK().Round(context.Background(), executor.Input{}); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Lstat(filepath.Join(h.root, "repair.txt")); err != nil {
			t.Fatalf("a reviewer repair outside the protected paths was refused: %v", err)
		}
		h = roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(write(conformance.ProtectedPath))})
		if _, err := h.startOK().Round(context.Background(), executor.Input{}); err != nil {
			t.Fatal(err)
		}
		if b, _ := os.ReadFile(filepath.Join(h.root, conformance.ProtectedPath)); string(b) != conformance.ProtectedContent {
			t.Fatalf("protected file changed: %q", b)
		}
	})

	t.Run("prompt bound is inclusive and never clips", func(t *testing.T) {
		h := roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(structuredRound(`{}`))})
		h.task.Brief.Stable = strings.Repeat("x", maxPromptBytes-len(ReviewConstraints)-len("\n\n")-len("\n\n"+h.task.Brief.Dynamic))
		if _, err := h.startOK().Round(context.Background(), executor.Input{}); err != nil {
			t.Fatalf("a prompt of exactly the bound was refused: %v", err)
		}
		if got := len(h.f.prompt(1)); got != maxPromptBytes {
			t.Fatalf("delivered %d bytes", got)
		}
		h = roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(structuredRound(`{}`))})
		h.task.Brief.Stable = strings.Repeat("x", maxPromptBytes)
		_, err := h.startOK().Round(context.Background(), executor.Input{})
		wantError(t, err, "candidate/context_budget_exceeded")
		if _, statErr := os.Stat(filepath.Join(h.f.cfg.State, "calls")); statErr == nil {
			t.Fatal("an oversized prompt reached Claude Code")
		}
	})
}

func mustPolicyNonce(t *testing.T, dir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, "hook-policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	var p policy
	if err := json.Unmarshal(b, &p); err != nil {
		t.Fatal(err)
	}
	return p.Nonce
}
