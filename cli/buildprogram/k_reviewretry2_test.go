package buildprogram

import (
	"slices"
	"strings"
)

// filler is a reviewer call whose long replayed arguments fill the working window.
func filler(f *fakeProvider, bytes int) handler {
	return f.calls("search_text", map[string]any{"query": strings.Repeat("x", bytes)})
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
