package buildprogram

import (
	"slices"
	"strings"

	"github.com/KogenAI/kogen-executor/agent"
)

// filler is a reviewer call whose long replayed arguments fill the working window.
func filler(f *fakeProvider, bytes int) handler {
	return f.calls("search_text", map[string]any{"query": strings.Repeat("x", bytes)})
}

// reviewBodies are the bodies of the reviewer's requests exactly as the provider received them.
func (f *fakeProvider) reviewBodies() [][]byte {
	var out [][]byte
	raw := f.rawRequests()
	for i, req := range f.requests() {
		if requestInstructions(req) == agent.Prompt(agent.Reviewer) {
			out = append(out, raw[i])
		}
	}
	return out
}

// runNotIn is the one run of the project that is not among seen: the run an explicit resume made.
func (e *env) runNotIn(seen ...string) string {
	e.t.Helper()
	var fresh []string
	for _, id := range e.runIDs() {
		if !slices.Contains(seen, id) {
			fresh = append(fresh, id)
		}
	}
	if len(fresh) != 1 {
		e.t.Fatalf("new runs %v, want one", fresh)
	}
	return fresh[0]
}
