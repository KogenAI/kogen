package tools

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestLDocboundDefaults(t *testing.T) {
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
	zero, explicit := Documentation{}, Documentation{ResultBound: 16384, BodyBound: 8388608}
	if err := explicit.Validate(); err != nil {
		t.Fatal(err)
	}
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
	}
	for _, c := range cases {
		got := norm(zero.Lookup(c.args))
		if got != c.want {
			t.Errorf("%s: got %s want %s", c.name, got, c.want)
		}
		if e := norm(explicit.Lookup(c.args)); e != got {
			t.Errorf("%s: explicit defaults differ:\n%s\n%s", c.name, e, got)
		}
	}
	big := map[string]any{"operation": "fetch", "url": base + "/big", "base": base}
	z, e := norm(zero.Lookup(big)), norm(explicit.Lookup(big))
	wantBig := `{"body":"` + marker + strings.Repeat("a", (20000+len(marker))/2) + `","body_total":20028,"error":"documentation response untrusted","next_offset":10014,"operation":"fetch","query":"","sources":[],"status":"untrusted","truncated":true,"untrusted":true,"url":"BASE/big"}`
	if z != wantBig || e != wantBig {
		t.Errorf("truncated default output differs from snapshot: zero %d, explicit %d, want %d bytes", len(z), len(e), len(wantBig))
	}
	if got := docFit(docResult{Operation: "fetch", Status: "retrieved", Body: strings.Repeat("b", 40_000)}); len(got.Body) >= 16384 || !got.Truncated {
		t.Errorf("docFit default %d", len(got.Body))
	}
}

func docEncodedLen(t *testing.T, text string) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal([]byte(text), &out); err != nil || !utf8.ValidString(text) {
		t.Fatalf("not valid JSON/UTF-8: %v", err)
	}
	return out
}

func TestLDocboundResultBound(t *testing.T) {
	marker := "UNTRUSTED-DIRECTIVE-7b9acb97"
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
		if strings.Contains(r.URL.RawQuery, "q=") {
			var parts []string
			for i := 0; i < 20; i++ {
				parts = append(parts, fmt.Sprintf(`{"url":"%s/s%d","title":"%s"}`, base, i, strings.Repeat("t", 500)))
			}
			io.WriteString(w, `{"sources":[`+strings.Join(parts, ",")+`]}`)
			return
		}
		io.WriteString(w, strings.Repeat("é", 6000)+marker+strings.Repeat("é", 6000))
	})
	base := origin.URL
	tl, err := New(Tools{Root: t.TempDir(), Enabled: []string{DocumentationTool}, Documentation: Documentation{ResultBound: 8192}})
	if err != nil {
		t.Fatal(err)
	}
	out, err := tl.Run(DocumentationTool, map[string]any{"operation": "fetch", "url": base + "/x", "base": base})
	if err != nil || len(out.Text) > 8192 {
		t.Fatalf("err %v len %d", err, len(out.Text))
	}
	got := docEncodedLen(t, out.Text)
	if got["status"] != "untrusted" || got["truncated"] != true || got["untrusted"] != true || !strings.Contains(got["body"].(string), marker) {
		t.Errorf("%v", got)
	}
	search, err := tl.Run(DocumentationTool, map[string]any{"operation": "search", "query": "q", "base": base})
	if err != nil || len(search.Text) > 8192 {
		t.Fatalf("search err %v len %d", err, len(search.Text))
	}
	result := docEncodedLen(t, search.Text)
	sources := result["sources"].([]any)
	if result["status"] != "retrieved" || result["truncated"] != true || len(sources) == 0 || len(sources) >= 20 {
		t.Fatalf("search fitting: %v sources, status %v, truncated %v", len(sources), result["status"], result["truncated"])
	}
	for i, source := range sources {
		if source.(map[string]any)["url"] != fmt.Sprintf("%s/s%d", base, i) {
			t.Fatalf("source %d is not retained in order: %v", i, source)
		}
	}
	// Hostile marker survives fitting.
	r := Documentation{ResultBound: 8192}.fit(docOf("fetch", "untrusted", "", base, nil, strings.Repeat("x", 30000), true, docUntrusted))
	if !strings.Contains(r.Body, marker) {
		t.Errorf("marker lost")
	}
	// Ordered source-prefix retention: sources drop last-first.
	var many []docSource
	for i := 0; i < 20; i++ {
		many = append(many, docSource{fmt.Sprintf("https://e.example/%03d", i), strings.Repeat("t", 100)})
	}
	f := Documentation{ResultBound: 2048}.fit(docOf("search", "retrieved", "q", "", many, "", false, ""))
	if len(f.Sources) == 0 || len(f.Sources) >= 20 || !f.Truncated {
		t.Fatalf("sources %d", len(f.Sources))
	}
	for i, s := range f.Sources {
		if s != many[i] {
			t.Fatalf("source %d not a prefix element", i)
		}
	}
	// Boundary: size at the bound and adjacent bounds.
	for _, pad := range []int{-1, 0, 1} {
		base := docResult{Operation: "fetch", Status: "retrieved", Body: ""}
		b, _ := encodeJSON(base.value())
		base.Body = strings.Repeat("a", 8192-len(b)+pad)
		enc, _ := encodeJSON(base.value())
		fit := Documentation{ResultBound: 8192}.fit(base)
		fb, _ := encodeJSON(fit.value())
		if len(fb) > 8192 {
			t.Errorf("pad %d: %d bytes", pad, len(fb))
		}
		if len(enc) <= 8192 && (fit.Truncated || fit.Body != base.Body) {
			t.Errorf("pad %d: fitting result changed", pad)
		}
		if len(enc) > 8192 && !fit.Truncated {
			t.Errorf("pad %d: oversized not truncated", pad)
		}
	}
	// Oversized metadata is trimmed UTF-8-safely; keys, status, error and marker stay.
	long := strings.Repeat("é", 20000)
	md := Documentation{ResultBound: 8192}.encode(docOf("fetch", "untrusted", long, long, nil, marker, true, docUntrusted))
	m := docEncodedLen(t, md)
	if len(md) > 8192 || m["status"] != "untrusted" || m["error"] != docUntrusted || !strings.Contains(m["body"].(string), marker) {
		t.Errorf("metadata fit %d %v", len(md), m)
	}
	// Default (zero) output is not metadata-trimmed.
	if d := (Documentation{}).encode(docOf("fetch", "retrieved", strings.Repeat("q", 40000), "", nil, "", false, "")); len(d) <= 16384 {
		t.Errorf("default output unexpectedly trimmed")
	}
}

func TestLDocboundBodyBound(t *testing.T) {
	const limit = 8192
	for _, n := range []int{limit - 1, limit, limit + 1} {
		short := `{"sources":[{"url":"http://x/1","title":"one"}]}`
		later := `{"sources":[{"url":"http://x/late","title":"late"}]}`
		origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
			if strings.Contains(r.URL.RawQuery, "q=") {
				io.WriteString(w, short+strings.Repeat(" ", n-len(short))+later)
				return
			}
			io.WriteString(w, strings.Repeat("a", n))
		})
		d := Documentation{ResultBound: limit, BodyBound: limit}
		if err := d.Validate(); err != nil {
			t.Fatal(err)
		}
		_, body, err := d.get(origin.URL+"/f", origin.URL)
		if err != nil || len(body) != min(n, limit) || string(body) != strings.Repeat("a", min(n, limit)) {
			t.Errorf("n=%d read %d err %v", n, len(body), err)
		}
		// Read truncation: the later source is beyond the ceiling and never appears.
		res, _ := lookup(t, d, map[string]any{"operation": "search", "query": "q", "base": origin.URL})
		srcs := res["sources"].([]any)
		// The first n bytes are the valid short document; only a prefix that reaches past
		// n (a limit above n) pulls in the later bytes and breaks the JSON.
		wantSources := 0
		if n >= limit {
			wantSources = 1
		}
		if res["status"] != "retrieved" || len(srcs) != wantSources || res["truncated"] != false {
			t.Errorf("n=%d search %v", n, res)
		}
		// Result fitting is distinct: a body within the read ceiling is still fitted.
		fetch, text := lookup(t, d, map[string]any{"operation": "fetch", "url": origin.URL + "/f", "base": origin.URL})
		if len(text) > limit || fetch["status"] != "retrieved" || (n >= limit-300 && fetch["truncated"] != true) {
			t.Errorf("n=%d fetch len %d truncated %v", n, len(text), fetch["truncated"])
		}
	}
}

func TestLDocboundValidation(t *testing.T) {
	cases := []struct {
		name string
		d    Documentation
		ok   bool
	}{
		{"zero", Documentation{}, true},
		{"negative result", Documentation{ResultBound: -1}, false},
		{"negative body", Documentation{BodyBound: -1}, false},
		{"result 1023", Documentation{ResultBound: 1023}, false},
		{"result 1024", Documentation{ResultBound: 1024, BodyBound: 1024}, true},
		{"result 1025", Documentation{ResultBound: 1025, BodyBound: 2048}, true},
		{"body 1023", Documentation{BodyBound: 1023}, false},
		{"body 1024 with default result", Documentation{BodyBound: 1024}, false},
		{"body 1025 alone", Documentation{ResultBound: 1024, BodyBound: 1025}, true},
		{"equal", Documentation{ResultBound: 5000, BodyBound: 5000}, true},
		{"result one over body", Documentation{ResultBound: 5001, BodyBound: 5000}, false},
		{"result zero default", Documentation{BodyBound: 16384}, true},
		{"body zero default", Documentation{ResultBound: 8192}, true},
		{"valid 8192", Documentation{ResultBound: 8192, BodyBound: 8192}, true},
		{"result above default body", Documentation{ResultBound: 8388609}, false},
	}
	for _, c := range cases {
		err := c.d.Validate()
		if (err == nil) != c.ok {
			t.Errorf("%s: Validate %v", c.name, err)
		}
		tl, nerr := New(Tools{Documentation: c.d})
		if c.ok && (nerr != nil || tl == nil) || !c.ok && (nerr == nil || tl != nil) {
			t.Errorf("%s: New %v %v", c.name, tl, nerr)
		}
		if !c.ok && !strings.Contains(err.Error(), "Documentation.") {
			t.Errorf("%s: error does not name the option: %v", c.name, err)
		}
	}
}
