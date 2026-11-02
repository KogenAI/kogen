package claudecode

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"kogen/executor"
)

// The first-round prompt length the executor reports is the length of the prompt the adapter
// writes to Claude Code's stdin, for every role and brief.
func TestFirstPromptBytesIsTheSentPrompt(t *testing.T) {
	briefs := []executor.Brief{
		{Stable: "STABLE brief", Dynamic: "DYNAMIC files"},
		{Stable: "", Dynamic: ""},
		{Stable: strings.Repeat("Ünï ✓ ", 5000), Dynamic: strings.Repeat("line\n", 70000)},
	}
	for _, role := range []string{executor.RoleShape, executor.RoleBuild, executor.RoleReview} {
		for i, brief := range briefs {
			h := roleHarness(t, role, fakeConfig{Script: oneRound(structuredRound(`{"verdict":"approve"}`))})
			h.task.Brief = brief
			sizer, ok := New(h.f.options()).(executor.PromptSizer)
			if !ok {
				t.Fatal("the Claude Code adapter does not report its first prompt size")
			}
			want := sizer.FirstPromptBytes(role, brief)
			if _, err := h.startOK().Round(context.Background(), executor.Input{}); err != nil {
				t.Fatalf("%s brief %d: %v", role, i, err)
			}
			if got := len(h.f.prompt(1)); got != want {
				t.Errorf("%s brief %d: reported %d bytes, sent %d", role, i, want, got)
			}
		}
	}
}

// Claude Code 2.1.312's refusal of an oversized prompt (Build 6eb946ca, round-1.jsonl): an
// is_error success result with terminal reason blocking_limit. It is a context result for every
// role, never an ordinary executor failure, and is not retried.
func TestPromptTooLongIsAContextResult(t *testing.T) {
	refusal := map[string]any{"subtype": "success", "is_error": true, "terminal_reason": "blocking_limit", "result": "Prompt is too long"}
	for _, role := range []string{executor.RoleShape, executor.RoleBuild, executor.RoleReview} {
		t.Run(role, func(t *testing.T) {
			h := roleHarness(t, role, fakeConfig{Script: oneRound(finishRound), AssistantError: "invalid_request", Result: refusal})
			s := h.startOK()
			_, err := s.Round(context.Background(), executor.Input{})
			e := wantError(t, err, "candidate/context_budget_exceeded")
			for _, want := range []string{
				"Claude Code refused the " + role + " prompt as too long", `terminal reason "blocking_limit"`, "Prompt is too long",
				"the round's prompt was " + strconv.Itoa(len(h.f.prompt(1))) + " bytes", "nothing was clipped or retried",
			} {
				if !strings.Contains(e.Detail, want) {
					t.Errorf("detail %q lacks %q", e.Detail, want)
				}
			}
			failed := h.eventsNamed("executor_round_failed")
			if len(failed) != 1 || failed[0]["reason"] != "context_budget_exceeded" {
				t.Fatalf("round failed events %v", failed)
			}
			if calls, _ := os.ReadFile(filepath.Join(h.f.cfg.State, "calls")); strings.TrimSpace(string(calls)) != "1" {
				t.Fatalf("invocations %q: a refused prompt is not retried", calls)
			}
		})
	}
}

func TestPromptTooLongClassification(t *testing.T) {
	for _, tc := range []struct {
		name, assistant string
		result          map[string]any
		want            string
	}{
		{"terminal reason alone", "", map[string]any{"is_error": true, "terminal_reason": "blocking_limit", "result": ""}, "candidate/context_budget_exceeded"},
		{"text alone", "", map[string]any{"is_error": true, "terminal_reason": "api_error", "result": "Prompt is too long"}, "candidate/context_budget_exceeded"},
		{"before the usage limit", "", map[string]any{"is_error": true, "terminal_reason": "blocking_limit", "result": "Prompt is too long: usage limit"}, "candidate/context_budget_exceeded"},
		{"not an error result", "", map[string]any{"is_error": false, "terminal_reason": "blocking_limit", "result": "Prompt is too long"}, ""},
		{"after the authentication check", "", map[string]any{"is_error": true, "terminal_reason": "api_error", "result": "Failed to authenticate: Prompt is too long"}, "executor/failed"},
		{"authentication assistant error", "authentication_failed", map[string]any{"is_error": true, "terminal_reason": "blocking_limit", "result": "Prompt is too long"}, "executor/failed"},
		{"another error", "", map[string]any{"is_error": true, "terminal_reason": "api_error", "result": "overloaded"}, "executor/failed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := roleHarness(t, executor.RoleReview, fakeConfig{Script: oneRound(structuredRound(`{"verdict":"approve"}`)), AssistantError: tc.assistant, Result: tc.result})
			_, err := h.startOK().Round(context.Background(), executor.Input{})
			if tc.want == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			wantError(t, err, tc.want)
		})
	}
}
