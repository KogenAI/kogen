package claudecode

import (
	"context"
	"testing"

	"kogen/executor"
)

func TestUsageLimitClassification(t *testing.T) {
	for _, tc := range []struct {
		name, assistant, text string
		isError               bool
		want                  string
	}{
		{"assistant", "rate_limit", "", true, "executor/usage_limit"},
		{"synthetic quota", "", "quota exceeded", true, "executor/usage_limit"},
		{"warning then success", "rate_limit", "done", false, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, fakeConfig{Script: oneRound(finishRound), AssistantError: tc.assistant, Result: map[string]any{"is_error": tc.isError, "terminal_reason": "api_error", "result": tc.text}})
			s := h.startOK()
			_, err := s.Round(context.Background(), executor.Input{})
			if tc.want == "" {
				if err != nil {
					t.Fatal(err)
				}
			} else {
				wantError(t, err, tc.want)
			}
		})
	}
}

func TestUsageLimitOtherErrors(t *testing.T) {
	for _, tc := range []struct {
		name, assistant, want string
		cfg                   fakeConfig
	}{
		{"unfinished tool", "rate_limit", "executor/protocol", fakeConfig{UnfinishedTool: true, Result: map[string]any{"is_error": true, "terminal_reason": "api_error"}}},
		{"auth diagnostic", "", "executor/failed", fakeConfig{Result: map[string]any{"is_error": true, "terminal_reason": "api_error", "result": "Failed to authenticate: rate limit"}}},
		{"generic", "", "executor/failed", fakeConfig{Result: map[string]any{"is_error": true, "terminal_reason": "api_error"}}},
		{"authentication", "authentication_failed", "executor/failed", fakeConfig{Result: map[string]any{"is_error": true, "terminal_reason": "api_error"}}},
		{"overloaded", "overloaded", "executor/failed", fakeConfig{Result: map[string]any{"is_error": true, "terminal_reason": "api_error"}}},
		{"exit", "", "executor/failed", fakeConfig{NoResult: true, ExitCode: 1}},
		{"malformed", "", "executor/protocol", fakeConfig{TrailingKind: "malformed"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.cfg.Script = oneRound(finishRound)
			tc.cfg.AssistantError = tc.assistant
			h := newHarness(t, tc.cfg)
			s := h.startOK()
			_, err := s.Round(context.Background(), executor.Input{})
			wantError(t, err, tc.want)
		})
	}
}
