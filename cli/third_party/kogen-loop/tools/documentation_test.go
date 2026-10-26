package tools

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func lookup(t *testing.T, d Documentation, args map[string]any) (map[string]any, string) {
	t.Helper()
	text := d.Lookup(args)
	var out map[string]any
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("lookup result is not JSON: %v\n%s", err, text)
	}
	return out, text
}

// fixtureOrigin serves the documentation fixture of test/kogen/documentation_test.exs and
// records the requests it receives.
type fixtureOrigin struct {
	*httptest.Server
	mu       sync.Mutex
	requests []*http.Request
}

func newFixtureOrigin(t *testing.T, handler func(w http.ResponseWriter, r *http.Request, base string)) *fixtureOrigin {
	t.Helper()
	f := &fixtureOrigin{}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.requests = append(f.requests, r.Clone(r.Context()))
		f.mu.Unlock()
		handler(w, r, "http://"+r.Host)
	}))
	t.Cleanup(f.Close)
	return f
}

func standardFixture(w http.ResponseWriter, r *http.Request, base string) {
	query := r.URL.RawQuery
	switch {
	case strings.Contains(query, "q=cache%20controls"):
		fmt.Fprintf(w, `{"sources":[{"url":"%s/cache-controls","title":"Cache controls"}]}`, base)
	case strings.Contains(query, "q=empty"):
		io.WriteString(w, `{"sources":[]}`)
	case strings.Contains(query, "q=missing-provider"):
		w.WriteHeader(http.StatusUnsupportedMediaType)
	case strings.Contains(r.URL.Path, "/cache-controls"):
		io.WriteString(w, "DOC-FACT-7b9acb97\n")
	case strings.Contains(r.URL.Path, "/hostile"):
		io.WriteString(w, "UNTRUSTED-DIRECTIVE-7b9acb97\n")
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

// Ports ExUnit "a pinned base separates search from fetch and keeps honest failures".
func TestAPinnedBaseSeparatesSearchFromFetchAndKeepsHonestFailures(t *testing.T) {
	origin := newFixtureOrigin(t, standardFixture)
	base := origin.URL
	d := Documentation{UserAgent: "kogen/1.2.3"}

	search, _ := lookup(t, d, map[string]any{"operation": "search", "query": "cache controls", "base": base})
	origin.mu.Lock()
	first := origin.requests[0]
	origin.mu.Unlock()
	if got := first.Header.Get("User-Agent"); got != "kogen/1.2.3" {
		t.Errorf("user agent %q", got)
	}
	if first.Header.Get("Authorization") != "" || first.Header.Get("Cookie") != "" {
		t.Errorf("credentials sent: %v", first.Header)
	}
	if search["status"] != "retrieved" || search["operation"] != "search" || search["query"] != "cache controls" ||
		search["url"] != "" || search["body"] != "" || search["untrusted"] != false {
		t.Errorf("search %v", search)
	}
	sources, _ := search["sources"].([]any)
	if len(sources) != 1 || sources[0].(map[string]any)["url"] != base+"/cache-controls" || sources[0].(map[string]any)["title"] != "Cache controls" {
		t.Errorf("sources %v", sources)
	}

	fetch, _ := lookup(t, d, map[string]any{"operation": "fetch", "url": base + "/cache-controls", "base": base})
	if fetch["status"] != "retrieved" || fetch["operation"] != "fetch" || fetch["untrusted"] != true ||
		fetch["url"] != base+"/cache-controls" || !strings.Contains(fetch["body"].(string), "DOC-FACT-7b9acb97") || fetch["error"] != "" {
		t.Errorf("fetch %v", fetch)
	}

	hostile, _ := lookup(t, d, map[string]any{"operation": "fetch", "url": base + "/hostile", "base": base})
	if hostile["status"] != "untrusted" || hostile["untrusted"] != true || hostile["error"] != "documentation response untrusted" ||
		!strings.Contains(hostile["body"].(string), "UNTRUSTED-DIRECTIVE-7b9acb97") || hostile["url"] != base+"/hostile" {
		t.Errorf("hostile %v", hostile)
	}

	missing, _ := lookup(t, d, map[string]any{"operation": "search", "query": "missing-provider", "base": base})
	if missing["status"] != "unsupported" || missing["error"] != "documentation source unsupported" ||
		len(missing["sources"].([]any)) != 0 || missing["body"] != "" {
		t.Errorf("missing %v", missing)
	}
}

func TestA200SearchWithNoFixtureSourcesStaysRetrieved(t *testing.T) {
	origin := newFixtureOrigin(t, standardFixture)
	got, _ := lookup(t, Documentation{}, map[string]any{"operation": "search", "query": "empty", "base": origin.URL})
	if got["status"] != "retrieved" || got["untrusted"] != false || len(got["sources"].([]any)) != 0 || got["body"] != "" || got["error"] != "" {
		t.Errorf("result %v", got)
	}
}

func TestConnectionRefusalOnThePinnedOriginIsUnreachable(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	base := "http://" + l.Addr().String()
	l.Close()
	got, _ := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": base + "/missing", "base": base})
	if got["status"] != "unreachable" || got["error"] != "documentation source unreachable" || got["body"] != "" ||
		len(got["sources"].([]any)) != 0 || got["url"] != base+"/missing" {
		t.Errorf("result %v", got)
	}
}

func TestAFetchURLOutsideThePinnedOriginIsUnsupportedAndNotRequested(t *testing.T) {
	got, _ := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": "http://127.0.0.1:9999/secret", "base": "http://127.0.0.1:9"})
	if got["status"] != "unsupported" || got["error"] != "documentation source unsupported" || got["body"] != "" || got["url"] != "http://127.0.0.1:9999/secret" {
		t.Errorf("result %v", got)
	}
}

func TestABasePrefixedURLWhoseHostIsCarriedInUserinfoIsNotRequested(t *testing.T) {
	got, _ := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": "http://127.0.0.1:9@evil.example/secret", "base": "http://127.0.0.1:9"})
	if got["status"] != "unsupported" || got["error"] != "documentation source unsupported" || got["body"] != "" {
		t.Errorf("result %v", got)
	}
}

func TestARedirectOffThePinnedOriginIsNotFollowed(t *testing.T) {
	var hits int
	var mu sync.Mutex
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
		mu.Lock()
		hits++
		mu.Unlock()
		port := strings.TrimPrefix(base, "http://127.0.0.1:")
		w.Header().Set("Location", "http://127.0.0.1:"+port+"@127.0.0.1:1/secret")
		w.WriteHeader(http.StatusFound)
	})
	got, _ := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": origin.URL + "/start", "base": origin.URL})
	if got["status"] != "unsupported" || got["error"] != "documentation source unsupported" || got["body"] != "" || got["url"] != origin.URL+"/start" {
		t.Errorf("result %v", got)
	}
	if hits != 1 {
		t.Errorf("the origin was asked %d times", hits)
	}
}

func TestASameOriginRedirectDoesNotForwardUserinfo(t *testing.T) {
	var landed *http.Request
	var mu sync.Mutex
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
		if r.URL.Path == "/start" {
			w.Header().Set("Location", "http://user:secret@"+r.Host+"/landed")
			w.WriteHeader(http.StatusFound)
			return
		}
		mu.Lock()
		landed = r.Clone(r.Context())
		mu.Unlock()
		io.WriteString(w, "land")
	})
	got, _ := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": origin.URL + "/start", "base": origin.URL})
	mu.Lock()
	defer mu.Unlock()
	if landed == nil || landed.URL.Path != "/landed" || landed.Header.Get("Authorization") != "" || strings.Contains(landed.RequestURI, "secret") {
		t.Fatalf("followed request %+v", landed)
	}
	if got["status"] != "retrieved" || got["body"] != "land" || got["url"] != origin.URL+"/start" {
		t.Errorf("result %v", got)
	}
}

func TestAnInvalidUTF8BodyThatContainsTheUntrustedMarkerStaysUntrusted(t *testing.T) {
	payload := "\xffUNTRUSTED-DIRECTIVE-7b9acb97\x80"
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) { io.WriteString(w, payload) })
	got, _ := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": origin.URL + "/hostile", "base": origin.URL})
	if got["status"] != "untrusted" || got["untrusted"] != true || got["error"] != "documentation response untrusted" ||
		!strings.Contains(got["body"].(string), "UNTRUSTED-DIRECTIVE-7b9acb97") {
		t.Errorf("result %v", got)
	}
}

func TestALargeUntrustedBodyStaysClassifiedAndFitsTheToolOutput(t *testing.T) {
	payload := strings.Repeat("a", 20_000) + "UNTRUSTED-DIRECTIVE-7b9acb97"
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) { io.WriteString(w, payload) })
	got, text := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": origin.URL + "/hostile", "base": origin.URL})
	if got["status"] != "untrusted" || !strings.Contains(got["body"].(string), "UNTRUSTED-DIRECTIVE-7b9acb97") || got["truncated"] != true || len(text) > 16_384 {
		t.Errorf("status %v truncated %v bytes %d", got["status"], got["truncated"], len(text))
	}
}

func TestAnUnknownOperationAndANonHTTPURLAreUnsupported(t *testing.T) {
	unknown, _ := lookup(t, Documentation{}, map[string]any{"operation": "browse", "base": "http://127.0.0.1:9"})
	if unknown["status"] != "unsupported" || unknown["error"] != "documentation source unsupported" {
		t.Errorf("unknown %v", unknown)
	}
	fetch, _ := lookup(t, Documentation{}, map[string]any{"operation": "fetch", "url": "file:///etc/passwd"})
	if fetch["status"] != "unsupported" || fetch["url"] != "file:///etc/passwd" {
		t.Errorf("fetch %v", fetch)
	}
	if got, _ := lookup(t, Documentation{}, nil); got["status"] != "unsupported" || got["operation"] != "search" {
		t.Errorf("no arguments %v", got)
	}
}

func TestPublicSearchCopiesOnlyDecodedAnchorsInsideBAlgoResults(t *testing.T) {
	enc := func(s string) string { return b64(s) }
	good, outside, other := enc("https://docs.example/cache"), enc("https://outside.example/no"), enc("https://docs.example/other")
	html := `<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1` + good + `&amp;ntb=1">Cache controls</a></h2></li>
<li class="b_algo">no result link</li>
<h2><a href="https://www.bing.com/ck/a?u=a1` + outside + `">Outside</a></h2>
<div class="b_algo"><h2><a href="https://invented.example/doc">Invented</a></h2></div>
<div class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1` + other + `">Other</a></h2></div>
`
	got := BingSources(html)
	want := []docSource{{"https://docs.example/cache", "Cache controls"}, {"https://docs.example/other", "Other"}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("sources %v, want %v", got, want)
	}
}

func TestPublicSearchUsesTheConfiguredSearchPage(t *testing.T) {
	enc := b64("https://docs.example/cache")
	var query string
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
		query = r.URL.RawQuery
		fmt.Fprintf(w, `<li class="b_algo"><h2><a href="/ck/a?u=a1%s">Doc &amp; more</a></h2></li>`, enc)
	})
	got, _ := lookup(t, Documentation{PublicSearch: origin.URL + "/search?q="}, map[string]any{"operation": "search", "query": "go exec"})
	sources := got["sources"].([]any)
	if got["status"] != "retrieved" || len(sources) != 1 || sources[0].(map[string]any)["title"] != "Doc & more" {
		t.Errorf("result %v", got)
	}
	if query != "q=go%20exec&setlang=en" {
		t.Errorf("query %q", query)
	}
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func TestTheDocumentationToolRunsOnlyWhenEnabledAndNeverFailsTheCall(t *testing.T) {
	origin := newFixtureOrigin(t, standardFixture)
	tools := &Tools{Root: t.TempDir(), Enabled: []string{DocumentationTool}, Documentation: Documentation{UserAgent: "kogen/test"}}
	out, err := tools.Run(DocumentationTool, map[string]any{"operation": "fetch", "url": origin.URL + "/cache-controls", "base": origin.URL})
	if err != nil || out.Typed() || !strings.Contains(out.Text, `"status":"retrieved"`) {
		t.Fatalf("out %+v, err %v", out, err)
	}
	// An unreachable origin is a result, not an error.
	out, err = tools.Run(DocumentationTool, map[string]any{"operation": "search", "query": "x", "base": "http://127.0.0.1:1"})
	if err != nil || !strings.Contains(out.Text, `"status":"unreachable"`) {
		t.Fatalf("out %+v, err %v", out, err)
	}
	// Arguments that are not an object are the searched-nothing case, answered honestly.
	if got := (&Tools{Enabled: []string{DocumentationTool}, Documentation: Documentation{PublicSearch: origin.URL + "/search?q="}}).
		Documentation.Lookup(map[string]any{"__invalid__": true}); !strings.Contains(got, `"operation":"search"`) {
		t.Errorf("invalid arguments %s", got)
	}
	off := &Tools{Root: t.TempDir(), Enabled: []string{ReadFileTool}}
	if out, _ := off.Run(DocumentationTool, map[string]any{"operation": "search"}); out.Text != "error: unknown tool documentation" {
		t.Errorf("disabled documentation tool answered %q", out.Text)
	}
}
