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
	"kogen/internal/research"
)

// setKnobs makes s the research settings for one test. Callers are serial (serialTmp first),
// so no other test reads the settings while they are changed.
func setKnobs(t *testing.T, s research.Settings) {
	t.Helper()
	old := research.Current
	research.Current = s
	t.Cleanup(func() { research.Current = old })
}

func knobInt(v int) *int { return &v }

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

// knobTools runs one entry under each tool-result setting.
func knobTools(t *testing.T, e knobEntry) {
	probe := shpAnswer(shpCall("p1", "probe", map[string]any{"command": probeBig}))
	t.Run("zero keeps 16384 and 4096", func(t *testing.T) {
		serialTmp(t)
		r := e.run(t, probe, "Clarify the draft.")
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
		knobCut(t, "probe result", shpOutputs(r.reqs[1])["p1"], 16384, 4096)
	})
	for _, c := range []struct {
		name        string
		settings    research.Settings
		bound, head int
	}{
		{name: "ResultBound alone", settings: research.Settings{Tools: research.ToolSettings{ResultBound: 8192}}, bound: 8192, head: 4096},
		{name: "ResultHead alone", settings: research.Settings{Tools: research.ToolSettings{ResultHead: 1024}}, bound: 16384, head: 1024},
		{name: "both", settings: research.Settings{Tools: research.ToolSettings{ResultBound: 2000, ResultHead: 500}}, bound: 2000, head: 500},
	} {
		t.Run(c.name, func(t *testing.T) {
			serialTmp(t)
			setKnobs(t, c.settings)
			r := e.run(t, probe, "Clarify the draft.")
			if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
				t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
			}
			knobCut(t, "probe result", shpOutputs(r.reqs[1])["p1"], c.bound, c.head)
		})
	}
}

// knobDocumentation runs one entry under each documentation setting.
func knobDocumentation(t *testing.T, e knobEntry) {
	fetch := func(origin *httptest.Server) shpStep {
		return shpAnswer(shpCall("d1", "documentation", map[string]any{"operation": "fetch", "url": origin.URL + "/big", "base": origin.URL}))
	}
	t.Run("zero keeps the full page within 16384", func(t *testing.T) {
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
			t.Fatalf("zero must not shrink the result: %d bytes", len(out))
		}
	})
	t.Run("Documentation.ResultBound", func(t *testing.T) {
		serialTmp(t)
		setKnobs(t, research.Settings{Documentation: research.DocumentationSettings{ResultBound: 2048}})
		origin := docBigOrigin(t)
		r := e.run(t, fetch(origin), "Clarify the draft.")
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
		out := shpOutputs(r.reqs[1])["d1"]
		shpContains(t, "total", out, `"body_total":44000`)
		if len(out) > 2048 || len(out) < 1024 || !strings.Contains(out, `"truncated":true`) {
			t.Fatalf("%d bytes: %.200q", len(out), out)
		}
	})
	t.Run("Documentation.BodyBound", func(t *testing.T) {
		serialTmp(t)
		setKnobs(t, research.Settings{Documentation: research.DocumentationSettings{BodyBound: 20000}})
		origin := docBigOrigin(t)
		r := e.run(t, fetch(origin), "Clarify the draft.")
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
		shpContains(t, "the page was read to the bound only", shpOutputs(r.reqs[1])["d1"], `"body_total":20000`)
	})
}

// knobInput runs one entry with a request of about 108 KB under the input ceiling.
func knobInput(t *testing.T, e knobEntry) {
	big := strings.Repeat("Clarify. ", 12000)
	t.Run("zero sends the request", func(t *testing.T) {
		serialTmp(t)
		r := e.run(t, shpAnswer(shpCall("p1", "probe", map[string]any{"command": "true"})), big)
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
	})
	t.Run("InputBudgetBytes lowers the ceiling before transport", func(t *testing.T) {
		serialTmp(t)
		setKnobs(t, research.Settings{InputBudgetBytes: 65536})
		r := e.run(t, shpAnswer(shpCall("p1", "probe", map[string]any{"command": "true"})), big)
		e1 := shpWantError(t, r.err, "candidate", "context_budget_exceeded", "ceiling 65536", 1)
		shpEq(t, "exit", r.exit, 1)
		shpEq(t, "requests", len(r.reqs), 0)
		shpContains(t, "unsent input is retained", e1.Detail, "retained in working-context custody")
	})
	t.Run("InputBudgetBytes at the library maximum changes nothing", func(t *testing.T) {
		serialTmp(t)
		setKnobs(t, research.Settings{InputBudgetBytes: 524288})
		r := e.run(t, shpAnswer(shpCall("p1", "probe", map[string]any{"command": "true"})), big)
		if r.err != nil || r.exit != 0 || len(r.reqs) < 2 {
			t.Fatalf("exit %d err %v requests %d", r.exit, r.err, len(r.reqs))
		}
	})
}

// knobAuthority runs one entry on an Anthropic role.
func knobAuthority(t *testing.T, name string) {
	marks := func(body map[string]any) (n int, first bool) {
		var walk func(v any) int
		walk = func(v any) int {
			switch x := v.(type) {
			case []any:
				n := 0
				for _, e := range x {
					n += walk(e)
				}
				return n
			case map[string]any:
				n := 0
				if x["cache_control"] != nil {
					n++
				}
				for _, e := range x {
					n += walk(e)
				}
				return n
			}
			return 0
		}
		messages, _ := body["messages"].([]any)
		if len(messages) > 0 {
			first, _ := messages[0].(map[string]any)
			return walk(messages), walk(first["content"]) > 0
		}
		return 0, false
	}
	run := func(t *testing.T, boundary *int) (map[string]any, string) {
		serialTmp(t)
		setKnobs(t, research.Settings{AuthorityBoundary: boundary})
		var f *shpFx
		var err error
		if name == "shape" {
			f = newShpFx(t)
			step := shpAnthropic(f)
			f.Prov.route = func(map[string]any) *shpStep { return &step }
			f.newSession()
			_, err = Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client})
		} else {
			r := newRefFx(t, refOpts{red: true})
			f = r.shpFx
			step := shpAnthropic(f)
			f.Prov.route = func(map[string]any) *shpStep { return &step }
			r.hash0 = r.hash()
			r.remove(".kogen/local/readiness/is-even.json")
			f.newSession()
			_, err = Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: r.hash0, Request: "Clarify the draft.", Client: f.Client})
		}
		reqs := f.Prov.requests()
		if len(reqs) == 0 {
			return nil, knobText(f, err)
		}
		return reqs[0], knobText(f, err)
	}
	var base int
	t.Run("nil sends no authority breakpoint", func(t *testing.T) {
		body, _ := run(t, nil)
		if body == nil {
			t.Fatal("no request reached the provider")
		}
		var first bool
		base, first = marks(body)
		if first {
			t.Fatalf("the first user message carries a breakpoint without the setting")
		}
	})
	t.Run("a target inside the first user message is marked in the sent request", func(t *testing.T) {
		body, _ := run(t, knobInt(0))
		if body == nil {
			t.Fatal("no request reached the provider")
		}
		n, first := marks(body)
		if !first || n != base+1 {
			t.Fatalf("breakpoints %d (was %d), first message marked %v", n, base, first)
		}
	})
	t.Run("a target outside it is refused in request preflight before transport", func(t *testing.T) {
		body, stdout := run(t, knobInt(99))
		if body != nil {
			t.Fatalf("a request reached the provider: %v", body["model"])
		}
		shpContains(t, "refusal", stdout, "invalid authority boundary: index 99 outside the first user message's")
	})
}

func TestLoopKnobsShape(t *testing.T) {
	serialTmp(t)
	e := knobEntries[0]
	t.Run("tools", func(t *testing.T) { knobTools(t, e) })
	t.Run("documentation", func(t *testing.T) { knobDocumentation(t, e) })
	t.Run("input", func(t *testing.T) { knobInput(t, e) })
	t.Run("authority", func(t *testing.T) { knobAuthority(t, "shape") })
	t.Run("client keeps the loop's response budget", func(t *testing.T) {
		serialTmp(t)
		f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
		f.newSession()
		if _, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client}); err != nil {
			t.Fatal(err)
		}
		shpEq(t, "response budget", f.Client.ResponseBudget, time.Duration(0))
	})
	t.Run("zero leaves an injected client as it was", func(t *testing.T) {
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
		setKnobs(t, research.Settings{Tools: research.ToolSettings{ResultBound: 2000, ResultHead: 500}})
		f := newShpFx(t)
		sh := &shaping{s: f.S, repo: f.Repo, root: f.Root, client: f.Client}
		out, err := sh.agentTools(context.Background(), []string{"probe"}).Run("probe", map[string]any{"command": probeBig})
		if err != nil {
			t.Fatal(err)
		}
		shpEq(t, "text is whole before delivery", strings.Contains(out.Text, "bytes omitted"), false)
		knobCut(t, "delivered", research.Cut(out).Text, 2000, 500)
	})
}

func TestLoopKnobsRefine(t *testing.T) {
	serialTmp(t)
	e := knobEntries[1]
	t.Run("tools", func(t *testing.T) { knobTools(t, e) })
	t.Run("documentation", func(t *testing.T) { knobDocumentation(t, e) })
	t.Run("input", func(t *testing.T) { knobInput(t, e) })
	t.Run("authority", func(t *testing.T) { knobAuthority(t, "refine") })
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
