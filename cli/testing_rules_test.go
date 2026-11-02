package main

import (
	"os"
	"testing"

	"github.com/KogenAI/kogen-executor/agent"
)

func TestTheTestingRulesUsersReadAreTheOnesEmbedded(t *testing.T) {
	docs, err := os.ReadFile("../docs/testing-rules.md")
	if err != nil {
		t.Fatal(err)
	}
	if string(docs) != agent.Prompt(agent.TestingRules) {
		t.Error("docs/testing-rules.md and agent/prompts/testing-rules.md differ: copy the docs file over the embedded one")
	}
}
