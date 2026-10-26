package main

import (
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

func TestExternalExecutorWiring(t *testing.T) {
	ex, err := externalExecutor(project.Role{Executor: project.ExecutorClaudeCode, Model: "m", Effort: "e"})
	if err != nil || ex == nil {
		t.Fatalf("claude-code: %v %v", ex, err)
	}
	if ex, err := externalExecutor(project.Role{Executor: "codex"}); ex != nil || err == nil {
		t.Fatalf("an unknown executor is refused: %v %v", ex, err)
	} else if se, ok := sys.AsError(err); !ok || se.Class != "executor" || se.Reason != executor.ReasonUnavailable {
		t.Fatalf("error %v", err)
	}
}
