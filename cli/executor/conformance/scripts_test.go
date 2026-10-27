package conformance

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"kogen/executor"
)

// TestScriptsParse keeps every script strictly decodable and named after its file.
func TestScriptsParse(t *testing.T) {
	s, err := Scripts()
	if err != nil {
		t.Fatal(err)
	}
	if len(s) < 11 {
		t.Fatalf("%d scripts, want the 11 required by the contract", len(s))
	}
}

// TestClaudeLineupRoleScripts: the role scripts every Claude Code driver performs name their
// role, are limited to the executor that implements them, and each structured role either ends
// with the exact submission it expects or stops with executor/protocol and no round.
func TestClaudeLineupRoleScripts(t *testing.T) {
	scripts, err := Scripts()
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]Script{}
	for _, s := range scripts {
		byName[s.Name] = s
	}
	for _, name := range []string{"shape_structured", "review_structured_feedback", "shape_missing_structured", "review_missing_structured"} {
		s, ok := byName[name]
		if !ok {
			t.Fatalf("missing role script %s", name)
		}
		if s.Only != executor.ClaudeCode || s.RoleOf() == executor.RoleBuild || !executor.IsRole(s.RoleOf()) {
			t.Errorf("%s: only %q role %q", name, s.Only, s.Role)
		}
		switch {
		case strings.HasSuffix(name, "_missing_structured"):
			if s.Expect.Error != "executor/protocol" || len(s.Expect.Rounds) != 0 || len(s.Rounds) != 1 || len(s.Rounds[0].Structured) != 0 {
				t.Errorf("%s must stop as a protocol failure without completing a round: %+v", name, s.Expect)
			}
		default:
			if len(s.Expect.Rounds) != len(s.Rounds) || s.Expect.Error != "" {
				t.Fatalf("%s: %d rounds expected, %d scripted", name, len(s.Expect.Rounds), len(s.Rounds))
			}
			for i, r := range s.Rounds {
				var a, b any
				if json.Unmarshal(r.Structured, &a) != nil || json.Unmarshal(s.Expect.Rounds[i].Structured, &b) != nil || !reflect.DeepEqual(a, b) {
					t.Errorf("%s round %d: scripted %s, expected %s", name, i+1, r.Structured, s.Expect.Rounds[i].Structured)
				}
			}
		}
	}
	// Every existing Build script keeps no role and no submission.
	for _, s := range scripts {
		if s.Role == "" {
			for _, r := range s.Rounds {
				if len(r.Structured) != 0 {
					t.Errorf("build script %s carries a structured submission", s.Name)
				}
			}
		}
	}
}
