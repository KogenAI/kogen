package shape

import (
	"encoding/json"
	"os"
	"testing"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// calls the real coverage rule (uncoveredDefects) on fixed defects, Decisions lines and questions.

func k25bDefect(kind, qa, qb, in, ra, rb string) map[string]any {
	return map[string]any{"kind": kind, "quote_a": qa, "quote_b": qb, "exposing_input": in, "result_a": ra, "result_b": rb}
}

func TestK25bCoverageObservation(t *testing.T) {
	undef := k25bDefect("undefined", "Rule C: sort numbers.", "parity", "is_even(3)", "", "")
	conflict := func(ra, rb string) map[string]any {
		return k25bDefect("conflict", "Example: is_even(0) returns True.", "Rule B: zero returns False.", "is_even(0)", ra, rb)
	}
	prec := k25bDefect("precedence", "Rule A", "Rule B", "is_even(0)", "True", "")
	q := func(text string) []map[string]any { return []map[string]any{{"question": text}} }
	cases := []struct {
		name      string
		defect    map[string]any
		decision  string
		questions []map[string]any
	}{
		{"undefined_colon", undef, "- parity: whether n % 2 == 0. (source: request)", nil},
		{"undefined_equals", undef, "- parity = n % 2. (source: request)", nil},
		{"undefined_means", undef, "- parity means n modulo 2. (source: request)", nil},
		{"undefined_is", undef, "- The parity is the remainder of n divided by 2. (source: request)", nil},
		{"undefined_mention_only", undef, "- Handle parity here. (source: request)", nil},
		{"undefined_marker_before_name", undef, "- It is so: parity matters. (source: request)", nil},
		{"undefined_other_name_defined", undef, "- oddness: n % 2 == 1. (source: request)", nil},
		{"undefined_question_both", undef, "", q("Rule C: sort numbers. What does parity mean?")},
		{"undefined_question_one", undef, "", q("Rule C: sort numbers. What do you mean?")},
		{"conflict_empty_result_b", conflict("True", ""), "- is_even(0) returns True. (source: request)", nil},
		{"conflict_empty_result_a", conflict("", "False"), "- is_even(0) returns True, not False. (source: request)", nil},
		{"conflict_both_results", conflict("True", "False"), "- is_even(0) returns True or False. (source: request)", nil},
		{"conflict_one_result", conflict("True", "False"), "- is_even(0) returns True. (source: request)", nil},
		{"conflict_no_exposing", conflict("True", ""), "- zero is special. (source: request)", nil},
		{"precedence_empty_result_b", prec, "- is_even(0) returns True. (source: request)", nil},
	}
	out := map[string]any{}
	for _, c := range cases {
		intent := "# T\n\n## Decisions\n"
		if c.decision != "" {
			intent += c.decision + "\n"
		}
		intent += "\n## Tests\n- x\n"
		out[c.name] = len(uncoveredDefects([]map[string]any{c.defect}, intent, c.questions))
	}
	raw, _ := json.Marshal(out)
	if err := os.WriteFile(os.Getenv("KOGEN_K25B_OUTPUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}
