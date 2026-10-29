package shape

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

// docBigOrigin serves a 44000-byte page at /big and a source list for any search.
func docBigOrigin(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/big") {
			for i := 0; i < 4000; i++ {
				fmt.Fprintf(w, "line %05d\n", i)
			}
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// probeBig is a probe whose output is far over any result bound under test.
const probeBig = "head -c 30000 /dev/zero | tr '\\000' a"

// knobText is everything a command told the user: its output and its error.
func knobText(f *shpFx, err error) string {
	text := f.Stdout.String()
	if e, ok := sys.AsError(err); ok {
		text += e.Render()
	} else if err != nil {
		text += err.Error()
	}
	return text
}

var knobMarker = regexp.MustCompile(`\n\[\.\.\. (\d+) bytes omitted \.\.\.\]\n`)

// knobCut asserts a delivered tool result was cut once to bound bytes keeping about head bytes.
func knobCut(t *testing.T, what, out string, bound, head int) {
	t.Helper()
	loc := knobMarker.FindStringIndex(out)
	if loc == nil {
		t.Fatalf("%s: no omission marker in %d bytes: %.200q", what, len(out), out)
	}
	if len(out) > bound || len(out) < bound-64 {
		t.Fatalf("%s: %d bytes delivered, want about %d", what, len(out), bound)
	}
	if loc[0] > head || loc[0] < head-3 {
		t.Fatalf("%s: marker after %d bytes, want the head of %d", what, loc[0], head)
	}
}

// knobEntry is a scripted Shape or Refine whose next request carries the result of one tool call.
type knobEntry struct {
	name string
	// run runs the entry with the model's first answer replaced by call and returns what the
	// provider saw and the command ended with. request is the user text.
	run func(t *testing.T, call shpStep, request string) knobResult
}

type knobResult struct {
	reqs   []map[string]any
	exit   int
	err    error
	stdout string
}

func knobShapeEntry(t *testing.T, call shpStep, request string) knobResult {
	f := newShpFx(t, call, shpSubmit("c1", shpFiles()), shpAck("c2"))
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: request, Client: f.Client})
	return knobResult{f.Prov.requests(), exit, err, knobText(f, err)}
}

func knobRefineEntry(t *testing.T, call shpStep, request string) knobResult {
	f := newRefFx(t, refOpts{red: true}, call, refSubmit("c1", refIntentPath, shpIntentMD))
	f.remove(".kogen/local/readiness/is-even.json")
	f.newSession()
	exit, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0, Request: request, Client: f.Client})
	return knobResult{f.Prov.requests(), exit, err, knobText(f.shpFx, err)}
}

var knobEntries = []knobEntry{{"shape", knobShapeEntry}, {"refine", knobRefineEntry}}

// knobTools runs one entry with a tool result over the default bound.
func knobTools(t *testing.T, e knobEntry) {
	probe := shpAnswer(shpCall("p1", "probe", map[string]any{"command": probeBig}))
	t.Run("a result is cut at 16384 bytes with a 4096-byte head", func(t *testing.T) {
		serialTmp(t)
		r := e.run(t, probe, "Clarify the draft.")
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
		knobCut(t, "probe result", shpOutputs(r.reqs[1])["p1"], 16384, 4096)
	})
}

// knobDocumentation runs one entry with a documentation page over the result bound.
func knobDocumentation(t *testing.T, e knobEntry) {
	fetch := func(origin *httptest.Server) shpStep {
		return shpAnswer(shpCall("d1", "documentation", map[string]any{"operation": "fetch", "url": origin.URL + "/big", "base": origin.URL}))
	}
	t.Run("the page is cut within 16384 bytes", func(t *testing.T) {
		serialTmp(t)
		origin := docBigOrigin(t)
		r := e.run(t, fetch(origin), "Clarify the draft.")
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
		out := shpOutputs(r.reqs[1])["d1"]
		shpContains(t, "total", out, `"body_total":44000`)
		if len(out) > 16384 || !strings.Contains(out, `"truncated":true`) {
			t.Fatalf("%d bytes: %.200q", len(out), out)
		}
		if len(out) < 8192 {
			t.Fatalf("the result shrank below the default: %d bytes", len(out))
		}
	})
}

// knobInput runs one entry with a request of about 108 KB under the 524288-byte input budget.
func knobInput(t *testing.T, e knobEntry) {
	big := strings.Repeat("Clarify. ", 12000)
	t.Run("a request within the input budget is sent", func(t *testing.T) {
		serialTmp(t)
		r := e.run(t, shpAnswer(shpCall("p1", "probe", map[string]any{"command": "true"})), big)
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
	})
}

// knobAuthority runs one entry on an Anthropic role and requires the first request to carry
// no authority breakpoint in its first user message.
func knobAuthority(t *testing.T, name string) {
	serialTmp(t)
	var f *shpFx
	if name == "shape" {
		f = newShpFx(t)
		step := shpAnthropic(f)
		f.Prov.route = func(map[string]any) *shpStep { return &step }
		f.newSession()
		Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client})
	} else {
		r := newRefFx(t, refOpts{red: true})
		f = r.shpFx
		step := shpAnthropic(f)
		f.Prov.route = func(map[string]any) *shpStep { return &step }
		r.hash0 = r.hash()
		r.remove(".kogen/local/readiness/is-even.json")
		f.newSession()
		Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: r.hash0, Request: "Clarify the draft.", Client: f.Client})
	}
	reqs := f.Prov.requests()
	if len(reqs) == 0 {
		t.Fatal("no request reached the provider")
	}
	messages, _ := reqs[0]["messages"].([]any)
	if len(messages) == 0 {
		t.Fatal("no messages in the first request")
	}
	first, _ := messages[0].(map[string]any)
	blocks, _ := first["content"].([]any)
	for _, b := range blocks {
		if block, _ := b.(map[string]any); block["cache_control"] != nil {
			t.Fatal("the first user message carries a breakpoint")
		}
	}
}

func TestLoopKnobsShape(t *testing.T) {
	serialTmp(t)
	e := knobEntries[0]
	t.Run("tools", func(t *testing.T) { knobTools(t, e) })
	t.Run("documentation", func(t *testing.T) { knobDocumentation(t, e) })
	t.Run("input", func(t *testing.T) { knobInput(t, e) })
	t.Run("the first request carries no authority breakpoint", func(t *testing.T) { knobAuthority(t, "shape") })
	t.Run("client keeps the loop's response budget", func(t *testing.T) {
		serialTmp(t)
		f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
		f.newSession()
		if _, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client}); err != nil {
			t.Fatal(err)
		}
		shpEq(t, "response budget", f.Client.ResponseBudget, time.Duration(0))
	})
	t.Run("an injected client is left as it was", func(t *testing.T) {
		serialTmp(t)
		f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
		f.Client.ResponseBudget = 42 * time.Second
		f.newSession()
		if _, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client}); err != nil {
			t.Fatal(err)
		}
		shpEq(t, "response budget", f.Client.ResponseBudget, 42*time.Second)
	})
	t.Run("workers use the same bounds", func(t *testing.T) {
		serialTmp(t)
		f := newShpFx(t)
		sh := &shaping{s: f.S, repo: f.Repo, root: f.Root, client: f.Client}
		out, err := sh.agentTools(context.Background(), []string{"probe"}).Run("probe", map[string]any{"command": probeBig})
		if err != nil {
			t.Fatal(err)
		}
		shpEq(t, "text is whole before delivery", strings.Contains(out.Text, "bytes omitted"), false)
		knobCut(t, "delivered", out.Cut().Text, 16384, 4096)
	})
}

func TestLoopKnobsRefine(t *testing.T) {
	serialTmp(t)
	e := knobEntries[1]
	t.Run("tools", func(t *testing.T) { knobTools(t, e) })
	t.Run("documentation", func(t *testing.T) { knobDocumentation(t, e) })
	t.Run("input", func(t *testing.T) { knobInput(t, e) })
	t.Run("the first request carries no authority breakpoint", func(t *testing.T) { knobAuthority(t, "refine") })
	t.Run("client keeps the loop's response budget", func(t *testing.T) {
		serialTmp(t)
		f := newRefFx(t, refOpts{red: true}, shpAnswer(shpCall("p1", "probe", map[string]any{"command": "true"})), refSubmit("c1", refIntentPath, shpIntentMD))
		f.remove(".kogen/local/readiness/is-even.json")
		f.newSession()
		if _, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0, Request: "Clarify the draft.", Client: f.Client}); err != nil {
			t.Fatal(err)
		}
		shpEq(t, "response budget", f.Client.ResponseBudget, time.Duration(0))
	})
}
