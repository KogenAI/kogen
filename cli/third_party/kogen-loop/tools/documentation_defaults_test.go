package tools

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

// The fixed documentation limits keep the exact result bytes: ordinary outcomes unchanged,
// a long untrusted body fitted into 16384 bytes with its marker and a next offset.
func TestDocumentationDefaultResults(t *testing.T) {
	marker := "UNTRUSTED-DIRECTIVE-7b9acb97"
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
		switch {
		case strings.Contains(r.URL.RawQuery, "q=hit"):
			fmt.Fprintf(w, `{"sources":[{"url":"%s/a","title":"A"}]}`, base)
		case strings.Contains(r.URL.Path, "/hostile"):
			io.WriteString(w, marker+"\n")
		case strings.Contains(r.URL.Path, "/big"):
			io.WriteString(w, strings.Repeat("a", 20_000)+marker)
		default:
			io.WriteString(w, "fact\n")
		}
	})
	base := origin.URL
	norm := func(s string) string { return strings.ReplaceAll(s, base, "BASE") }
	cases := []struct {
		name string
		args map[string]any
		want string
	}{
		{"search", map[string]any{"operation": "search", "query": "hit", "base": base},
			`{"body":"","error":"","operation":"search","query":"hit","sources":[{"title":"A","url":"BASE/a"}],"status":"retrieved","truncated":false,"untrusted":false,"url":""}`},
		{"fetch", map[string]any{"operation": "fetch", "url": base + "/a", "base": base},
			`{"body":"fact\n","body_total":5,"error":"","operation":"fetch","query":"","sources":[],"status":"retrieved","truncated":false,"untrusted":true,"url":"BASE/a"}`},
		{"hostile", map[string]any{"operation": "fetch", "url": base + "/hostile", "base": base},
			`{"body":"` + marker + `\n","body_total":29,"error":"documentation response untrusted","operation":"fetch","query":"","sources":[],"status":"untrusted","truncated":false,"untrusted":true,"url":"BASE/hostile"}`},
		{"big", map[string]any{"operation": "fetch", "url": base + "/big", "base": base},
			`{"body":"` + marker + strings.Repeat("a", (20000+len(marker))/2) + `","body_total":20028,"error":"documentation response untrusted","next_offset":10014,"operation":"fetch","query":"","sources":[],"status":"untrusted","truncated":true,"untrusted":true,"url":"BASE/big"}`},
	}
	for _, c := range cases {
		if got := norm(Documentation{}.Lookup(c.args)); got != c.want {
			t.Errorf("%s: got %s want %s", c.name, got, c.want)
		}
	}
	if got := docFit(docResult{Operation: "fetch", Status: "retrieved", Body: strings.Repeat("b", 40_000)}); len(got.Body) >= docOutputLimit || !got.Truncated {
		t.Errorf("docFit %d", len(got.Body))
	}
}
