package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/internal/research"
)

// loopSource is the clean checkout the pin was synchronized from; KOGEN_LOOP_SOURCE names
// another checkout of the same commit.
const loopSource = "/Users/kogen-runner/src/loop-1b8ef1f"

// TestLoopPinKnobsProvenance compares the complete vendored file set and bytes with the clean
// kogen-loop checkout, and holds the exact pin and its evidence note.
func TestLoopPinKnobsProvenance(t *testing.T) {
	src := os.Getenv("KOGEN_LOOP_SOURCE")
	if src == "" {
		src = loopSource
	}
	raw, err := os.ReadFile("loop-pin.json")
	if err != nil {
		t.Fatal(err)
	}
	var pin map[string]any
	if err := json.Unmarshal(raw, &pin); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"module": "kogen-loop", "protocol": "kogen-loop/v1", "library": "loop/v1",
		"digest":      "a93251d1f3c8a1692cc2c5cedb380afec6d8c09c72a68c8030cd54edb38ddbd4",
		"files":       float64(136),
		"source_head": "e5054c849478ddd0ed1bd2bc38f768f3cd7bd200", "source_state": "clean",
	}
	if !reflect.DeepEqual(pin, want) {
		t.Fatalf("loop-pin.json = %v, want %v", pin, want)
	}

	// The byte comparison needs a clean checkout at the pinned head; TestLoopPin already
	// recomputes the vendored digest everywhere, so other machines skip only this part.
	if st, err := os.Stat(filepath.Join(src, "go.mod")); err != nil || st.IsDir() {
		t.Skipf("no kogen-loop checkout at %s (set KOGEN_LOOP_SOURCE to a clean checkout of %s); pin verified, byte comparison skipped", src, want["source_head"])
	}
	if out, err := exec.Command("git", "-C", src, "rev-parse", "HEAD").Output(); err != nil || strings.TrimSpace(string(out)) != want["source_head"] {
		t.Skipf("kogen-loop checkout %s is not at %s; pin verified, byte comparison skipped", src, want["source_head"])
	}
	git := func(args ...string) string {
		out, err := exec.Command("git", append([]string{"-C", src}, args...)...).Output()
		if err != nil {
			t.Fatalf("git %v in %s: %v", args, src, err)
		}
		return string(out)
	}
	if head := strings.TrimSpace(git("rev-parse", "HEAD")); head != want["source_head"] {
		t.Fatalf("the checkout %s is at %s, not %s", src, head, want["source_head"])
	}
	if dirty := git("status", "--porcelain", "--untracked-files=all"); dirty != "" {
		t.Fatalf("the checkout %s is not clean:\n%s", src, dirty)
	}
	var files []string
	for _, f := range strings.Split(strings.TrimSpace(git("ls-files", "--cached", "--others", "--exclude-standard")), "\n") {
		if !strings.HasPrefix(f, ".kogen/") && !strings.HasPrefix(f, "features/") {
			files = append(files, f)
		}
	}
	slices.Sort(files)
	files = slices.Compact(files)

	root := filepath.Join("third_party", "kogen-loop")
	var vendored []string
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		vendored = append(vendored, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(vendored)
	if !slices.Equal(files, vendored) {
		t.Fatalf("vendored file set differs from the checkout:\nonly in the checkout: %v\nonly vendored: %v",
			difference(files, vendored), difference(vendored, files))
	}
	for _, f := range files {
		a, err := os.ReadFile(filepath.Join(src, f))
		if err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(a, b) {
			t.Errorf("%s differs from the clean checkout", f)
		}
	}

	note, err := os.ReadFile(filepath.Join("..", "docs", "evidence", "k-pin-knobs", "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, part := range []string{
		"4afed06da64e348a5a65db6e550f81b65cbe0235", "abd53fa2b3d947b51f3f5dfe34169871605d1bc8d7be99f5eb4f01e0334c6567",
		"123", "c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6", "L-DOCRANGE", "L-TTL", "kogen/loop-knobs-repin",
		"docs/evidence/k5-loop-repin/", "docs/evidence/k5b-loop-repin/",
	} {
		if !strings.Contains(string(note), part) {
			t.Errorf("the evidence note does not mention %q", part)
		}
	}
	for _, earlier := range []string{"k5-loop-repin", "k5b-loop-repin"} {
		if b, err := os.ReadFile(filepath.Join("..", "docs", "evidence", earlier, "README.md")); err != nil || len(b) == 0 {
			t.Errorf("the earlier note %s is gone: %v", earlier, err)
		}
	}
}

func difference(a, b []string) []string {
	var out []string
	for _, x := range a {
		if !slices.Contains(b, x) {
			out = append(out, x)
		}
	}
	return out
}

// knobServer is a local provider that counts its requests and refuses each one, keeping the
// raw bodies.
type knobServer struct {
	srv    *httptest.Server
	count  atomic.Int64
	bodies [][]byte
}

func newKnobServer(t *testing.T) *knobServer {
	t.Helper()
	k := &knobServer{}
	k.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		k.bodies = append(k.bodies, body)
		k.count.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"code":"invalid_request_error","message":"scripted refusal","type":"invalid_request_error"}}`)
	}))
	t.Cleanup(k.srv.Close)
	return k
}

// knobHome is a home with a saved Anthropic key.
func knobHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

func knobSession(t *testing.T, k *knobServer) *sys.Session {
	t.Helper()
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + knobHome(t), "KOGEN_PROVIDER_URL=" + k.srv.URL, "KOGEN_AUTH_URL=" + k.srv.URL}
	return sys.NewWith(env, t.TempDir())
}

func setKnobs(t *testing.T, s research.Settings) {
	t.Helper()
	old := research.Current
	research.Current = s
	t.Cleanup(func() { research.Current = old })
}

func knobInt(v int) *int { return &v }

// TestLoopKnobsInvalidStartup holds the loop's own boundaries: each invalid setting stops with
// the loop's error before any provider request, at each entry; each adjacent valid setting is
// accepted; an authority target is refused by the request preflight.
func TestLoopKnobsInvalidStartup(t *testing.T) {
	type tc struct {
		name string
		s    research.Settings
		bad  string // the library's error text, empty when valid
	}
	tl := func(bound, head int) research.Settings {
		return research.Settings{Tools: research.ToolSettings{ResultBound: bound, ResultHead: head}}
	}
	doc := func(result, body int) research.Settings {
		return research.Settings{Documentation: research.DocumentationSettings{ResultBound: result, BodyBound: body}}
	}
	budget := func(n int) research.Settings { return research.Settings{InputBudgetBytes: n} }
	response := func(d time.Duration) research.Settings {
		return research.Settings{Client: research.ClientSettings{ResponseBudget: d}}
	}
	cases := []tc{
		{"zero", research.Settings{}, ""},
		// Tools.ResultBound and ResultHead: bound at least 128, head below it, 64 bytes left for the marker and tail.
		{"ResultBound negative", tl(-1, 0), "tools: ResultBound -1 is negative"},
		{"ResultHead negative", tl(0, -1), "tools: ResultHead -1 is negative"},
		{"ResultBound below the minimum", tl(127, 0), "tools: ResultBound 127 is below the minimum 128"},
		{"the named counterexample: the default head is not below the bound", tl(1000, 0), "tools: ResultHead 4096 must be less than ResultBound 1000"},
		{"head equal to the bound", tl(200, 200), "tools: ResultHead 200 must be less than ResultBound 200"},
		{"head above the default bound", tl(0, 16384), "tools: ResultHead 16384 must be less than ResultBound 16384"},
		{"one byte short of the tail", tl(200, 137), "leaves 63 bytes remaining, need at least 64"},
		{"the tail exactly", tl(200, 136), ""},
		{"the default head with the least bound", tl(4160, 0), ""},
		{"the default head one byte short", tl(4159, 0), "leaves 63 bytes remaining, need at least 64"},
		{"a head of the default bound less the tail", tl(0, 16320), ""},
		{"a head one above that", tl(0, 16321), "leaves 63 bytes remaining, need at least 64"},
		{"a bound above the default", tl(16385, 0), ""},
		// Documentation.ResultBound and BodyBound: each at least 1024, the result bound at most the body bound.
		{"documentation result negative", doc(-1, 0), "tools: Documentation.ResultBound -1 is negative"},
		{"documentation body negative", doc(0, -1), "tools: Documentation.BodyBound -1 is negative"},
		{"documentation result below the minimum", doc(1023, 0), "tools: Documentation.ResultBound 1023 is below the minimum 1024"},
		{"documentation result at the minimum", doc(1024, 0), ""},
		{"documentation body below the minimum", doc(0, 1023), "tools: Documentation.BodyBound 1023 is below the minimum 1024"},
		{"documentation body under the default result", doc(0, 1024), "tools: Documentation.ResultBound 16384 must not exceed BodyBound 1024"},
		{"documentation body one under the default result", doc(0, 16383), "tools: Documentation.ResultBound 16384 must not exceed BodyBound 16383"},
		{"documentation body equal to the default result", doc(0, 16384), ""},
		{"documentation bounds equal", doc(1024, 1024), ""},
		{"documentation result above the body", doc(1025, 1024), "tools: Documentation.ResultBound 1025 must not exceed BodyBound 1024"},
		// InputBudgetBytes: zero or [65536, 524288].
		{"input budget negative", budget(-1), "InputBudgetBytes -1 is invalid: must be 0 (default) or in [65536, 524288]"},
		{"input budget one", budget(1), "InputBudgetBytes 1 is invalid: must be 0 (default) or in [65536, 524288]"},
		{"input budget below the minimum", budget(65535), "InputBudgetBytes 65535 is invalid: must be 0 (default) or in [65536, 524288]"},
		{"input budget at the minimum", budget(65536), ""},
		{"input budget above the minimum", budget(65537), ""},
		{"input budget at the ceiling", budget(524288), ""},
		{"input budget below the ceiling", budget(524287), ""},
		{"input budget above the ceiling", budget(524289), "InputBudgetBytes 524289 is invalid: must be 0 (default) or in [65536, 524288]"},
		// Client.ResponseBudget: zero or [1s, 30m].
		{"response budget negative", response(-time.Second), "response budget must be zero or between 1s and 30m0s"},
		{"response budget one nanosecond", response(1), "response budget must be zero or between 1s and 30m0s"},
		{"response budget below a second", response(999 * time.Millisecond), "response budget must be zero or between 1s and 30m0s"},
		{"response budget a second", response(time.Second), ""},
		{"response budget the default", response(30 * time.Minute), ""},
		{"response budget above the default", response(30*time.Minute + 1), "response budget must be zero or between 1s and 30m0s"},
		// AuthorityBoundary depends on its request: startup accepts any value.
		{"authority boundary zero", research.Settings{AuthorityBoundary: knobInt(0)}, ""},
		{"authority boundary negative", research.Settings{AuthorityBoundary: knobInt(-1)}, ""},
		{"authority boundary beyond any message", research.Settings{AuthorityBoundary: knobInt(99)}, ""},
	}
	t.Run("startup validation", func(t *testing.T) {
		k := newKnobServer(t)
		sess := knobSession(t, k)
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				setKnobs(t, c.s)
				err := research.Validate(context.Background(), sess)
				switch {
				case c.bad == "" && err != nil:
					t.Fatalf("valid setting refused: %v", err)
				case c.bad != "" && (err == nil || !strings.Contains(err.Error(), c.bad)):
					t.Fatalf("error %v, want %q", err, c.bad)
				}
			})
		}
		if n := k.count.Load(); n != 0 {
			t.Fatalf("%d provider requests", n)
		}
	})

	t.Run("every entry stops before any provider request", func(t *testing.T) {
		k := newKnobServer(t)
		wd, _ := os.Getwd()
		dir := t.TempDir()
		if err := os.Chdir(dir); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chdir(wd) })
		t.Setenv("HOME", t.TempDir())
		t.Setenv("KOGEN_PROVIDER_URL", k.srv.URL)
		t.Setenv("KOGEN_AUTH_URL", k.srv.URL)
		request := filepath.Join(t.TempDir(), "request.md")
		os.WriteFile(request, []byte("Add is_even.\n"), 0o644)
		setKnobs(t, tl(1000, 0))
		hash := strings.Repeat("a", 64)
		for _, args := range [][]string{
			{"init"},
			{"intent", "shape", "is-even", request},
			{"intent", "refine", "is-even", hash, request},
			{"intent", "build", "is-even"},
			{"intent", "resume", "abcdef12"},
		} {
			code, out := runCaptured(t, args...)
			if code != 70 || !strings.Contains(out, "tools: ResultHead 4096 must be less than ResultBound 1000") {
				t.Errorf("kogen %v = %d %q", args, code, out)
			}
		}
		if n := k.count.Load(); n != 0 {
			t.Fatalf("%d provider requests", n)
		}
	})

	t.Run("an authority target is refused by the request preflight before transport", func(t *testing.T) {
		k := newKnobServer(t)
		sess := knobSession(t, k)
		role := provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}
		send := func(boundary *int) error {
			setKnobs(t, research.Settings{AuthorityBoundary: boundary})
			if err := research.Validate(context.Background(), sess); err != nil {
				t.Fatalf("startup refused an authority boundary: %v", err)
			}
			client := provider.NewClient("kogen dev+12345678 (test)")
			client.Sleep = func(context.Context, time.Duration) error { return nil }
			req := research.Request(provider.Request{
				Role: role, Instructions: "policy", CacheID: "knob-authority",
				Input: []any{map[string]any{"role": "user", "content": "authority"}, map[string]any{"role": "user", "content": "task"}},
			})
			_, err := research.Respond(context.Background(), client, sess, req, nil)
			return err
		}
		for _, bad := range []int{-1, 1, 99} {
			err := send(knobInt(bad))
			if err == nil || !strings.Contains(err.Error(), "invalid authority boundary") {
				t.Fatalf("authority %d: %v", bad, err)
			}
			if n := k.count.Load(); n != 0 {
				t.Fatalf("authority %d: %d provider requests", bad, n)
			}
		}
		// Index 0 is inside the first user message: the request is sent and the stub refuses it.
		if err := send(knobInt(0)); err == nil || strings.Contains(err.Error(), "invalid authority boundary") {
			t.Fatalf("authority 0: %v", err)
		}
		if k.count.Load() == 0 {
			t.Fatal("a valid authority boundary was not sent")
		}
	})
}

// priorDocumentation is the documentation tool definition of the previous pin.
const priorDocumentation = `{"description":"Shape documentation lookup discovers sources and retrieves current authoritative documentation.","name":"documentation","parameters":{"additionalProperties":false,"properties":{"base":{"description":"Optional origin. When present, every request in this call uses that origin and no other host.","type":"string"},"operation":{"enum":["search","fetch"],"type":"string"},"query":{"type":"string"},"url":{"type":"string"}},"required":["operation"],"type":"object"},"strict":false,"type":"function"}`

// TestLoopKnobsZeroCompatibility holds that all-zero settings change nothing: the source of the
// settings is zero, every request byte equals the previous pin's but the documentation tool
// definition text that the new pin changed, and every helper equals the newly pinned library's
// default byte for byte. The four entry paths (Shape, Refine, Review, native Build) run their
// own unchanged golden, request and checkpoint tests with the zero source.
func TestLoopKnobsZeroCompatibility(t *testing.T) {
	t.Run("the source of the settings is zero", func(t *testing.T) {
		if !reflect.DeepEqual(research.Current, research.Settings{}) {
			t.Fatalf("research.Current = %+v", research.Current)
		}
		if research.Current.AuthorityBoundary != nil {
			t.Fatal("the authority boundary is not disabled")
		}
	})

	t.Run("tool definitions change only in the documentation text", func(t *testing.T) {
		raw, err := os.ReadFile("agent/testdata/defs_golden.json")
		if err != nil {
			t.Fatal(err)
		}
		var golden map[string]any
		if err := json.Unmarshal(raw, &golden); err != nil {
			t.Fatal(err)
		}
		for name, def := range golden {
			got := jsonValue(t, agent.Defs(name)[0])
			if !reflect.DeepEqual(got, def) {
				t.Errorf("%s: %v differs from the golden", name, got)
			}
		}
		// The previous pin's documentation definition plus what L-DOCRANGE added, and nothing else.
		var prior map[string]any
		if err := json.Unmarshal([]byte(priorDocumentation), &prior); err != nil {
			t.Fatal(err)
		}
		prior["description"] = prior["description"].(string) + " A fetch may pass offset, a byte index into the page body, and find, text that starts the body at its first matching heading or line; the result reports body_total and next_offset for reading the rest."
		props := prior["parameters"].(map[string]any)["properties"].(map[string]any)
		props["offset"] = map[string]any{"type": "integer"}
		props["find"] = map[string]any{"type": "string"}
		if got := jsonValue(t, agent.Defs(tools.DocumentationTool)[0]); !reflect.DeepEqual(got, any(prior)) {
			t.Errorf("documentation definition = %v, want %v", got, prior)
		}
	})

	t.Run("requests and cuts equal the previous pin's", func(t *testing.T) {
		raw, err := os.ReadFile("testdata/loop_knobs_golden.json")
		if err != nil {
			t.Fatal(err)
		}
		var golden struct {
			Requests []any
			Cuts     []any
		}
		if err := json.Unmarshal(raw, &golden); err != nil {
			t.Fatal(err)
		}
		client := provider.NewClient("kogen dev+12345678 (test)")
		research.ApplyClient(client)
		got := knobNormalize(knobFixtureRequests(research.CutText, research.Request, func(r provider.Request) map[string]any { return client.Body(r) }))
		if !reflect.DeepEqual(got, any(golden.Requests)) {
			gotJSON, _ := json.Marshal(got)
			wantJSON, _ := json.Marshal(golden.Requests)
			t.Fatalf("requests differ from the previous pin's (%d and %d bytes)", len(gotJSON), len(wantJSON))
		}
		for i, text := range knobFixtureRaw() {
			if got := knobNormalize(research.CutText(text)); got != golden.Cuts[i] {
				t.Errorf("cut %d = %v, want %v", i, got, golden.Cuts[i])
			}
		}
		if _, ok := knobNormalize(map[string]any{"name": "documentation", "parameters": map[string]any{}}).(string); !ok {
			t.Fatal("the normalization does not set the documentation definition apart")
		}
	})

	t.Run("helpers equal the newly pinned library defaults byte for byte", func(t *testing.T) {
		for i, text := range knobFixtureRaw() {
			if got, want := research.CutText(text), tools.Cut(text); got != want {
				t.Errorf("cut %d: %d bytes, library %d", i, len(got), len(want))
			}
			out := tools.Output{Text: text}
			if got, want := research.Cut(out), out.Cut(); !reflect.DeepEqual(got, want) {
				t.Errorf("output cut %d differs", i)
			}
		}
		typed := tools.Output{Parts: []any{map[string]any{"type": "input_text", "text": strings.Repeat("x", 20000)}}}
		if got := research.Cut(typed); !reflect.DeepEqual(got, typed) {
			t.Error("typed parts changed")
		}
		if got := research.ApplyTools(&tools.Tools{}); !reflect.DeepEqual(got, &tools.Tools{}) {
			t.Errorf("zero settings set tool options: %+v", got)
		}
		if got := research.InputBudget(); got != tools.InputBudgetBytes {
			t.Errorf("input budget %d", got)
		}
		client := provider.NewClient("kogen dev+12345678 (test)")
		client.ResponseBudget = 42 * time.Second
		if research.ApplyClient(client).ResponseBudget != 42*time.Second || research.ApplyClient(provider.NewClient("")).ResponseBudget != 0 {
			t.Error("zero settings changed a client's response budget")
		}
		for _, role := range knobFixtureRoles {
			req := provider.Request{Role: role, Instructions: "policy", Input: knobFixtureInput(tools.Cut), Tools: agent.AsAny(agent.Defs(knobFixtureEveryTool...)), CacheID: "knob-fixture-cache"}
			if got := research.Request(req); !reflect.DeepEqual(got, req) {
				t.Errorf("%s: the request changed", role.Provider)
			}
			c := provider.NewClient("kogen dev+12345678 (test)")
			body := c.Body(research.Request(req))
			want, _ := tools.Measure(c.Body(req), role)
			got, err := research.Measure(body, role)
			if err != nil || got != want {
				t.Errorf("%s: measurement %+v, library %+v (%v)", role.Provider, got, want, err)
			}
		}
		k := newKnobServer(t)
		sess := knobSession(t, k)
		if err := research.Validate(context.Background(), sess); err != nil {
			t.Fatal(err)
		}
		if k.count.Load() != 0 {
			t.Fatal("startup validation sent a request")
		}
		if _, err := (loop.FailOverBudget{}).Prepare(context.Background(), loop.Request{Role: provider.Role{Provider: "none"}}); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("the request sent equals the library's byte for byte", func(t *testing.T) {
		role := provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}
		send := func(use func(ctx context.Context, c *provider.Client, s *sys.Session, req provider.Request) error) []byte {
			k := newKnobServer(t)
			sess := knobSession(t, k)
			client := provider.NewClient("kogen dev+12345678 (test)")
			client.Sleep = func(context.Context, time.Duration) error { return nil }
			req := provider.Request{Role: role, Instructions: "policy", Input: knobFixtureInput(tools.Cut), Tools: agent.AsAny(agent.Defs(knobFixtureEveryTool...)), CacheID: "knob-fixture-cache"}
			use(context.Background(), client, sess, req)
			if len(k.bodies) == 0 {
				t.Fatal("nothing was sent")
			}
			return k.bodies[0]
		}
		direct := send(func(ctx context.Context, c *provider.Client, s *sys.Session, req provider.Request) error {
			_, err := c.Respond(ctx, s, req, nil)
			return err
		})
		wrapped := send(func(ctx context.Context, c *provider.Client, s *sys.Session, req provider.Request) error {
			_, err := research.Respond(ctx, c, s, research.Request(req), nil)
			return err
		})
		if !bytes.Equal(direct, wrapped) {
			t.Fatalf("sent %d bytes, library %d", len(wrapped), len(direct))
		}
	})
}

func jsonValue(t *testing.T, v any) any {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
