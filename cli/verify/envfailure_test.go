package verify

import "testing"

func TestEnvFailure(t *testing.T) {
	timedOut := "ok  \tkogen/verify\t1.204s\npanic: test timed out after 10m0s\n\trunning tests:\n\t\tTestSlow (10m0s)\n\nFAIL\tkogen/build\t600.214s\nFAIL\n"
	for _, c := range []struct {
		name   string
		result CommandResult
		want   string
	}{
		{"timed out go test", CommandResult{Name: "go-test", Status: 1, Output: timedOut}, "panic: test timed out after 10m0s"},
		{"indented line, first of two", CommandResult{Status: 2, Output: "x\n  \tpanic: test timed out after 1s \r\npanic: test timed out after 2s\n"}, "panic: test timed out after 1s"},
		{"ordinary failure", CommandResult{Status: 1, Output: "--- FAIL: TestAppIsReady (0.00s)\nFAIL\n"}, ""},
		{"zero status", CommandResult{Status: 0, Output: timedOut}, ""},
		{"not at the line start", CommandResult{Status: 1, Output: "log: panic: test timed out after 10m0s\n"}, ""},
	} {
		got, ok := EnvFailure(c.result)
		if got != c.want || ok != (c.want != "") {
			t.Errorf("%s: EnvFailure = %q, %v; want %q", c.name, got, ok, c.want)
		}
	}
}
