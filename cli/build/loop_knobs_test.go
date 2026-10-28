package build

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen/internal/research"
)

// The research settings reach the native builder and the independent review. These tests are
// serial: they change the process-wide settings and restore them.

func setKnobs(t *testing.T, s research.Settings) {
	t.Helper()
	old := research.Current
	research.Current = s
	t.Cleanup(func() { research.Current = old })
}

func knobInt(v int) *int { return &v }

// knobShell is a shell command whose output is far over any result bound under test.
const knobShell = "head -c 30000 /dev/zero | tr '\\000' a"

var knobMarker = regexp.MustCompile(`\n\[\.\.\. (\d+) bytes omitted \.\.\.\]\n`)

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

// knobOutput is the one delivered tool result that was cut.
func knobOutput(t *testing.T, outputs []string) string {
	t.Helper()
	for _, o := range outputs {
		if strings.Contains(o, "bytes omitted") {
			return o
		}
	}
	t.Fatalf("no cut tool result among %d", len(outputs))
	return ""
}

// anthropicRole makes the role of the fixture's Build an Anthropic one with a saved key and
// approves the changed configuration.
func anthropicRole(e *env, role string) {
	e.t.Helper()
	cfgPath := filepath.Join(e.root, ".kogen/project.yaml")
	cfg, err := os.ReadFile(cfgPath)
	if err != nil {
		e.t.Fatal(err)
	}
	re := regexp.MustCompile(`(?m)^  ` + role + `:\n(    .*\n)+`)
	if !re.Match(cfg) {
		e.t.Fatalf("no %s role in:\n%s", role, cfg)
	}
	writeFile(e.t, cfgPath, string(re.ReplaceAll(cfg, []byte("  "+role+": {provider: anthropic, model: claude-sonnet-5-5, effort: high}\n"))), 0o644)
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "anthropic "+role+" role")
	e.approve()
	dir := filepath.Join(e.home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		e.t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		e.t.Fatal(err)
	}
}

// knobMarks counts the cache_control locations of an Anthropic request's messages and says
// whether the first content block of the first message carries one.
func knobMarks(body map[string]any) (total int, first bool) {
	var walk func(v any) int
	walk = func(v any) int {
		n := 0
		switch x := v.(type) {
		case []any:
			for _, e := range x {
				n += walk(e)
			}
		case map[string]any:
			if x["cache_control"] != nil {
				n++
			}
			for _, e := range x {
				n += walk(e)
			}
		}
		return n
	}
	messages, _ := body["messages"].([]any)
	if len(messages) == 0 {
		return 0, false
	}
	head, _ := messages[0].(map[string]any)
	blocks, _ := head["content"].([]any)
	if len(blocks) > 0 {
		block, _ := blocks[0].(map[string]any)
		first = block["cache_control"] != nil
	}
	return walk(messages), first
}

func bigDiagnostic() *Diagnostic {
	text := strings.Repeat("diagnostic line\n", 6400)
	return &Diagnostic{Text: text, SourcePath: "/diagnostic/label.txt", SHA256: digestOf(text)}
}

func TestLoopKnobsNativeBuilder(t *testing.T) {
	t.Run("tools", func(t *testing.T) {
		for _, c := range []struct {
			name        string
			settings    research.Settings
			bound, head int
		}{
			{"zero keeps 16384 and 4096", research.Settings{}, 16384, 4096},
			{"ResultBound alone", research.Settings{Tools: research.ToolSettings{ResultBound: 8192}}, 8192, 4096},
			{"ResultHead alone", research.Settings{Tools: research.ToolSettings{ResultHead: 1024}}, 16384, 1024},
			{"both", research.Settings{Tools: research.ToolSettings{ResultBound: 2000, ResultHead: 500}}, 2000, 500},
		} {
			t.Run(c.name, func(t *testing.T) {
				setKnobs(t, c.settings)
				e := newEnv(t)
				e.prov.then(e.prov.calls("shell", map[string]any{"command": knobShell}))
				e.prov.then(landScript(e.prov)...)
				a := e.build()
				if a.exit != 0 {
					t.Fatalf("exit %d: %s", a.exit, a.shown())
				}
				knobCut(t, "shell result", knobOutput(t, e.prov.toolOutputs()), c.bound, c.head)
			})
		}
	})

	t.Run("documentation settings are accepted and leave the builder's tools alone", func(t *testing.T) {
		setKnobs(t, research.Settings{Documentation: research.DocumentationSettings{ResultBound: 2048, BodyBound: 4096}})
		e := newEnv(t)
		e.prov.then(landScript(e.prov)...)
		if a := e.build(); a.exit != 0 {
			t.Fatalf("exit %d: %s", a.exit, a.shown())
		}
	})

	t.Run("a setting the loop refuses stops before any request", func(t *testing.T) {
		setKnobs(t, research.Settings{Tools: research.ToolSettings{ResultBound: 1000}})
		e := newEnv(t)
		e.prov.then(landScript(e.prov)...)
		start := e.head()
		a := e.build()
		if a.err == nil || !strings.Contains(a.err.Error(), "tools: ResultHead 4096 must be less than ResultBound 1000") {
			t.Fatalf("exit %d err %v: %s", a.exit, a.err, a.shown())
		}
		eq(t, "requests", e.prov.count(), 0)
		eq(t, "head", e.head(), start)
		eq(t, "runs", len(e.runIDs()), 0)
	})

	t.Run("response budget reaches the client and bounds the wait", func(t *testing.T) {
		setKnobs(t, research.Settings{Client: research.ClientSettings{ResponseBudget: time.Second}})
		e := newEnv(t)
		opened := make(chan struct{})
		e.prov.then(hang(opened))
		t0 := time.Now()
		var client *provider.Client
		a := e.build(func(in *Input) { client = in.Deps.Client })
		if a.exit == 0 {
			t.Fatalf("a hung provider ended the Build with exit 0: %s", a.shown())
		}
		contains(t, "expiry", a.shown(), "response wait exceeded 1s")
		if time.Since(t0) > 15*time.Second {
			t.Fatalf("waited %s", time.Since(t0))
		}
		eq(t, "client response budget", client.ResponseBudget, time.Second)
	})

	t.Run("input budget", func(t *testing.T) {
		t.Run("zero sends the request", func(t *testing.T) {
			e := newEnv(t)
			e.prov.then(landScript(e.prov)...)
			if a := e.build(func(in *Input) { in.Context = bigDiagnostic() }); a.exit != 0 {
				t.Fatalf("exit %d: %s", a.exit, a.shown())
			}
		})
		t.Run("a lower ceiling stops an over-ceiling opening before transport", func(t *testing.T) {
			setKnobs(t, research.Settings{InputBudgetBytes: 65536})
			e := newEnv(t)
			e.prov.then(landScript(e.prov)...)
			a := e.build(func(in *Input) { in.Context = bigDiagnostic() })
			eq(t, "requests", e.prov.count(), 0)
			if a.exit == 0 {
				t.Fatalf("the Build landed: %s", a.shown())
			}
			contains(t, "ceiling", a.shown()+fmt.Sprint(a.err), "ceiling 65536")
			eq(t, "outcome", e.result(e.onlyRun())["outcome"], any("context_budget_exceeded"))
		})
	})

	t.Run("authority boundary", func(t *testing.T) {
		build := func(t *testing.T, boundary *int) (map[string]any, *attempt) {
			setKnobs(t, research.Settings{AuthorityBoundary: boundary})
			e := newEnv(t)
			anthropicRole(e, "build")
			e.prov.then(refused())
			a := e.build()
			reqs := e.prov.requests()
			if len(reqs) == 0 {
				return nil, a
			}
			return reqs[0], a
		}
		var base int
		t.Run("nil sends no authority breakpoint", func(t *testing.T) {
			body, _ := build(t, nil)
			if body == nil {
				t.Fatal("no request reached the provider")
			}
			var first bool
			base, first = knobMarks(body)
			if first {
				t.Fatal("the first block carries a breakpoint without the setting")
			}
		})
		t.Run("a target inside the first user message is marked in the sent request", func(t *testing.T) {
			body, _ := build(t, knobInt(0))
			if body == nil {
				t.Fatal("no request reached the provider")
			}
			n, first := knobMarks(body)
			if !first || n != base+1 {
				t.Fatalf("breakpoints %d (was %d), first message marked %v", n, base, first)
			}
		})
		t.Run("a target outside it is refused in request preflight before transport", func(t *testing.T) {
			body, a := build(t, knobInt(99))
			if body != nil {
				t.Fatalf("a request reached the provider")
			}
			contains(t, "refusal", a.shown()+fmt.Sprint(a.err), "invalid authority boundary: index 99 outside the first user message's")
		})
	})
}

func TestLoopKnobsReview(t *testing.T) {
	bigApp := "// candidate\n" + strings.Repeat("padding of the candidate source line\n", 1800)
	land := func(e *env) {
		e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": bigApp}, "finish", map[string]any{"summary": "done"}))
	}

	t.Run("tools", func(t *testing.T) {
		for _, c := range []struct {
			name        string
			settings    research.Settings
			bound, head int
		}{
			{"zero keeps 16384 and 4096", research.Settings{}, 16384, 4096},
			{"ResultBound alone", research.Settings{Tools: research.ToolSettings{ResultBound: 8192}}, 8192, 4096},
			{"ResultHead alone", research.Settings{Tools: research.ToolSettings{ResultHead: 1024}}, 16384, 1024},
			{"both", research.Settings{Tools: research.ToolSettings{ResultBound: 2000, ResultHead: 500}}, 2000, 500},
		} {
			t.Run(c.name, func(t *testing.T) {
				setKnobs(t, c.settings)
				e := newEnv(t)
				f := e.prov
				f.then(landScript(f)...)
				f.then(f.calls("shell", map[string]any{"command": knobShell}), submit(f, "approve"))
				if a := e.reviewed(); a.exit != 0 {
					t.Fatalf("exit %d: %s", a.exit, a.shown())
				}
				var outputs []string
				for _, req := range f.reviewRequests() {
					items, _ := req["input"].([]any)
					for _, it := range items {
						if m, _ := it.(map[string]any); m["type"] == "function_call_output" {
							outputs = append(outputs, fmt.Sprint(m["output"]))
						}
					}
				}
				knobCut(t, "reviewer shell result", knobOutput(t, outputs), c.bound, c.head)
			})
		}
	})

	t.Run("a setting the loop refuses stops before the review", func(t *testing.T) {
		setKnobs(t, research.Settings{Documentation: research.DocumentationSettings{BodyBound: 1023}})
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		a := e.reviewed()
		if a.err == nil || !strings.Contains(a.err.Error(), "tools: Documentation.BodyBound 1023 is below the minimum 1024") {
			t.Fatalf("exit %d err %v: %s", a.exit, a.err, a.shown())
		}
		eq(t, "requests", f.count(), 0)
	})

	t.Run("response budget bounds the review's wait", func(t *testing.T) {
		setKnobs(t, research.Settings{Client: research.ClientSettings{ResponseBudget: time.Second}})
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(hang(make(chan struct{})))
		t0 := time.Now()
		a := e.reviewed()
		if a.exit == 0 {
			t.Fatalf("a hung reviewer landed the Build: %s", a.shown())
		}
		contains(t, "expiry", a.shown(), "response wait exceeded 1s")
		eq(t, "review requests", len(f.reviewRequests()), 1)
		if time.Since(t0) > 20*time.Second {
			t.Fatalf("waited %s", time.Since(t0))
		}
	})

	t.Run("input budget", func(t *testing.T) {
		t.Run("zero keeps the candidate source inline", func(t *testing.T) {
			e := newEnv(t)
			f := e.prov
			land(e)
			f.then(submit(f, "approve"))
			if a := e.reviewed(); a.exit != 0 {
				t.Fatalf("exit %d: %s", a.exit, a.shown())
			}
			reqs := f.reviewRequests()
			eq(t, "review requests", len(reqs), 1)
			text := requestText(reqs[0])
			contains(t, "inline source", text, "padding of the candidate source line")
			lacks(t, "catalog", text, "Pinned complete candidate source evidence")
		})
		t.Run("a lower ceiling pins the source to parts before transport", func(t *testing.T) {
			setKnobs(t, research.Settings{InputBudgetBytes: 65536})
			e := newEnv(t)
			f := e.prov
			land(e)
			shared := readPinned(e, f)
			for i := 0; i < 120; i++ {
				f.then(shared)
			}
			if a := e.reviewed(); a.exit != 0 {
				t.Fatalf("exit %d: %s", a.exit, a.shown())
			}
			parts, _ := filepath.Glob(filepath.Join(e.root, ".kogen/local/runs/*/review-source/*/*.json"))
			if len(parts) == 0 {
				t.Fatal("the source was never pinned")
			}
			reqs := f.reviewRequests()
			if len(reqs) < 2 {
				t.Fatalf("review requests %d", len(reqs))
			}
			text := requestText(reqs[0])
			contains(t, "catalog", text, "Pinned complete candidate source evidence")
			lacks(t, "inline source", text, "padding of the candidate source line")
		})
	})

	t.Run("authority boundary", func(t *testing.T) {
		review := func(t *testing.T, boundary *int) (map[string]any, *attempt, *env) {
			setKnobs(t, research.Settings{AuthorityBoundary: boundary})
			e := newEnv(t)
			anthropicRole(e, "review")
			f := e.prov
			f.then(landScript(f)...)
			f.then(refused())
			a := e.reviewed()
			var first map[string]any
			for _, req := range f.requests() {
				if _, anth := req["messages"]; anth {
					first = req
					break
				}
			}
			return first, a, e
		}
		var base int
		t.Run("nil sends no authority breakpoint", func(t *testing.T) {
			body, _, _ := review(t, nil)
			if body == nil {
				t.Fatal("no review request reached the provider")
			}
			var first bool
			base, first = knobMarks(body)
			if first {
				t.Fatal("the first block carries a breakpoint without the setting")
			}
		})
		t.Run("a target inside the first user message is marked in the sent request", func(t *testing.T) {
			body, _, _ := review(t, knobInt(0))
			if body == nil {
				t.Fatal("no review request reached the provider")
			}
			n, first := knobMarks(body)
			if !first || n != base+1 {
				t.Fatalf("breakpoints %d (was %d), first message marked %v", n, base, first)
			}
		})
		t.Run("a target outside it is refused in request preflight before transport", func(t *testing.T) {
			body, a, _ := review(t, knobInt(99))
			if body != nil {
				t.Fatal("a review request reached the provider")
			}
			contains(t, "refusal", a.shown()+fmt.Sprint(a.err), "invalid authority boundary: index 99 outside the first user message's")
		})
	})
}
