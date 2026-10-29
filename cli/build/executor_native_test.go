package build

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/executor"
	"kogen/executor/conformance"
	"kogen/git"
	"kogen/project"
)

// ---- the opening input ----

func TestNativeOpeningInputEqualsTheOpeningMessage(t *testing.T) {
	t.Parallel()
	// The native conversation opens with the brief as a user message of two input_text blocks,
	// byte for byte what the builder always opened with. The expected bytes come from the
	// reference data (testdata/context-golden.json, written from the Elixir implementation),
	// not from the code under test.
	raw, err := os.ReadFile("testdata/context-golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name          string     `json:"name"`
		ModelLine     string     `json:"model_line"`
		ModelQnt      *string    `json:"model_qnt"`
		Readme        *string    `json:"readme"`
		Setup         []string   `json:"setup"`
		Fix           []string   `json:"fix"`
		Checks        [][]string `json:"checks"`
		AcceptanceRun *string    `json:"acceptance_run"`
		Baseline      []string   `json:"baseline"`
		Stable        string     `json:"stable"`
		Dynamic       string     `json:"dynamic"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil || len(cases) == 0 {
		t.Fatalf("%v (%d cases)", err, len(cases))
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			dir := physical(t, t.TempDir())
			env := isolatedEnv()
			initGit(t, dir, env)
			intentMD := "# Add a \"greeting\" 2 \\ é\nSlug: fixture\nModel: " + c.ModelLine + "\n\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/s.js\n\n## Tests\n- one: unit\n"
			writeFile(t, filepath.Join(dir, ".kogen/intents/fixture/intent.md"), intentMD, 0o644)
			writeFile(t, filepath.Join(dir, ".kogen/intents/fixture/acceptance.feature"), "Feature: F\n  Scenario: S\n    Given a thing\n", 0o644)
			if c.ModelQnt != nil {
				writeFile(t, filepath.Join(dir, ".kogen/intents/fixture/model.qnt"), *c.ModelQnt, 0o644)
			}
			if c.Readme != nil {
				writeFile(t, filepath.Join(dir, "README.md"), *c.Readme, 0o644)
			}
			writeFile(t, filepath.Join(dir, "a.txt"), "a\n", 0o644)
			cfg := &project.Config{Setup: c.Setup, Fix: c.Fix}
			for _, ch := range c.Checks {
				cfg.Checks = append(cfg.Checks, project.Check{Name: ch[0], Run: ch[1]})
			}
			if c.AcceptanceRun != nil {
				cfg.Acceptance = &project.Acceptance{Run: *c.AcceptanceRun, StepsDir: "features/steps"}
			}
			intent, err := project.LoadIntent(dir, "fixture")
			if err != nil {
				t.Fatal(err)
			}
			b := &Attempt{State: State{Root: dir, Slug: "fixture", Config: cfg, Baseline: c.Baseline}, intent: intent, repo: git.New(dir, env)}
			brief, err := b.brief()
			if err != nil {
				t.Fatal(err)
			}
			eq(t, "brief", brief, executor.Brief{Stable: c.Stable, Dynamic: c.Dynamic})
			sess, err := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: brief}, nil)
			if err != nil {
				t.Fatal(err)
			}
			want := []any{map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "input_text", "text": c.Stable},
				map[string]any{"type": "input_text", "text": c.Dynamic},
			}}}
			if got := sess.(*nativeSession).pending; jsonText(got) != jsonText(want) {
				t.Fatalf("opening input differs\n got: %s\nwant: %s", jsonText(got), jsonText(want))
			}
			// The caller's diagnostic data follows the opening message.
			diag := &Diagnostic{SourcePath: "/x/diag.txt", SHA256: strings.Repeat("a", 64), Text: "boom"}
			sess, _ = nativeExecutor{b: b, tail: []any{diag.message()}}.Start(context.Background(), executor.Task{Brief: brief}, nil)
			if got := sess.(*nativeSession).pending; len(got) != 2 || jsonText(got[1]) != jsonText(diag.message()) || jsonText(got[:1]) != jsonText(want) {
				t.Fatalf("opening input with diagnostic data: %s", jsonText(got))
			}
		})
	}
}

func initGit(t *testing.T, dir string, env []string) {
	t.Helper()
	cmd := exec.Command("git", "init", "-q")
	cmd.Dir, cmd.Env = dir, env
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
}

func TestNativeFirstRequestCarriesTheOpeningInput(t *testing.T) {
	t.Parallel()
	// End to end: the first request body of a Build holds the opening blocks that the brief
	// defines, as the first input item.
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d %s", a.exit, a.shown())
	}
	first := e.prov.requests()[0]["input"].([]any)[0].(map[string]any)
	eq(t, "role", first["role"], any("user"))
	blocks := first["content"].([]any)
	if len(blocks) != 2 {
		t.Fatalf("%d blocks", len(blocks))
	}
	stable, dynamic := blocks[0].(map[string]any)["text"].(string), blocks[1].(map[string]any)["text"].(string)
	contains(t, "stable", stable, "# Intent: Preserve the fixture")
	contains(t, "stable", stable, "# Protected paths")
	if !strings.HasPrefix(dynamic, "# Files\n\n") || !strings.Contains(dynamic, "\nREADME.md\n") {
		t.Fatalf("dynamic %q", dynamic)
	}
}

// ---- the native executor as the contract states it ----

func TestNativeDescriptor(t *testing.T) {
	t.Parallel()
	d := nativeExecutor{}.Describe()
	if err := d.Validate(); err != nil {
		t.Fatal(err)
	}
	eq(t, "name", d.Name, executor.Native)
	eq(t, "capabilities", d.Capabilities, executor.Capabilities{
		Roles: []string{executor.RoleBuild}, Resume: executor.ResumeExact, Continuation: true, Usage: executor.UsageProvider,
		Prevention: []string{executor.PreventWriteTool}, Blocker: true, Images: true, MaxRounds: 0,
	})
}

// ---- conformance ----

// nativeDriver makes the native builder perform a conformance script: a scripted fake
// provider answers each round with the calls (write_file, shell, finish) that perform it.
type nativeDriver struct{ prov *fakeProvider }

func (d *nativeDriver) Name() string { return executor.Native }

func (d *nativeDriver) Feedback(t *testing.T) []string { return d.prov.toolOutputs() }

func (d *nativeDriver) Prepare(t *testing.T, root string, s conformance.Script) (executor.Executor, executor.Task) {
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	d.prov = newFakeProvider(t)
	for _, r := range s.Rounds {
		d.prov.then(d.round(r))
	}
	// A script whose shell writes the protected file documents a path that is not prevented;
	// the Build's detection of it is the next test. The attempt then leaves it out of the
	// baseline, so that the executor-level assertion (the round's claim) is what runs.
	shellTouchesProtected := false
	for _, r := range s.Rounds {
		for _, a := range r.Actions {
			shellTouchesProtected = shellTouchesProtected || strings.Contains(a.Shell, conformance.ProtectedPath)
		}
	}
	b := newConformanceAttempt(t, root, home, d.prov, !shellTouchesProtected)
	return nativeExecutor{b: b}, executor.Task{Brief: executor.Brief{Stable: "conformance task\n", Dynamic: "# Files\n\nREADME.md\n"}}
}

// round is the provider's answer to one script round: one response with every action's call,
// then the ending (a finish call, or text without a call).
func (d *nativeDriver) round(r conformance.RoundScript) handler {
	var items []map[string]any
	for _, a := range r.Actions {
		switch {
		case a.Write != nil:
			items = append(items, d.prov.call("write_file", map[string]any{"path": a.Write.Path, "content": a.Write.Content}))
		case a.Shell != "":
			items = append(items, d.prov.call("shell", map[string]any{"command": a.Shell}))
		case a.SleepSeconds > 0:
			items = append(items, d.prov.call("shell", map[string]any{"command": "sleep " + trimFloat(a.SleepSeconds)}))
		case a.SpawnOrphan:
			items = append(items, d.prov.call("shell", map[string]any{"command": "mkdir -p .conformance; sleep 300 & echo $! > " + conformance.ChildPIDPath}))
		}
	}
	if r.End == "no_call" {
		items = append(items, map[string]any{"type": "message", "id": "msg-1", "role": "assistant",
			"content": []any{map[string]any{"type": "output_text", "text": r.Claim}}})
	} else {
		items = append(items, d.prov.call("finish", map[string]any{"summary": r.Claim}))
	}
	return respondWith(items, r.Usage)
}

func trimFloat(f float64) string {
	b, _ := json.Marshal(f)
	return string(b)
}

// respondWith is an SSE answer with the given items; usage nil reports none.
func respondWith(items []map[string]any, usage *conformance.ScriptUsage) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		for i, it := range items {
			io.WriteString(w, "data: "+jsonText(map[string]any{"type": "response.output_item.done", "output_index": i, "item": it})+"\n\n")
		}
		resp := map[string]any{}
		if usage != nil {
			resp["usage"] = map[string]any{
				"input_tokens": usage.Input, "input_tokens_details": map[string]any{"cached_tokens": usage.Cached},
				"output_tokens": usage.Output, "output_tokens_details": map[string]any{"reasoning_tokens": 0},
			}
		}
		io.WriteString(w, "data: "+jsonText(map[string]any{"type": "response.completed", "response": resp})+"\n\n")
	}
}

func seedLogin(t *testing.T, home string) {
	t.Helper()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	os.Chmod(filepath.Join(home, ".kogen"), 0o700)
	b, _ := json.Marshal(map[string]any{
		"client_id": "oaiapp_fake", "access_token": "fake-access-token", "refresh_token": "fake-refresh-token",
		"expires_at": time.Now().Unix() + 86400, "scope": "openid", "email": "integration@example.invalid",
	})
	if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// newConformanceAttempt is a Build in progress over a conformance checkout: just enough
// state (the run, the checkpoint custody, the protected baseline) for the native executor's
// hooks to run as they do in a Build. protect puts the conformance's protected file into the
// approved baseline.
func newConformanceAttempt(t *testing.T, root, home string, prov *fakeProvider, protect bool) *Attempt {
	t.Helper()
	env := isolatedEnv("HOME="+home, "KOGEN_PROVIDER_URL="+prov.srv.URL, "KOGEN_AUTH_URL="+prov.srv.URL,
		"GIT_AUTHOR_NAME=c", "GIT_AUTHOR_EMAIL=c@example.invalid", "GIT_COMMITTER_NAME=c", "GIT_COMMITTER_EMAIL=c@example.invalid")
	s := sys.NewWith(env, root)
	s.Stdout, s.Stderr = io.Discard, io.Discard
	repo := git.New(root, env)
	run, err := StartRun(root)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &project.Config{Models: project.DefaultModels()}
	baseline := []string{project.ConfigPath}
	if protect {
		cfg.Protect = []string{"protected"}
		baseline = append(baseline, conformance.ProtectedPath)
	}
	facts, err := startFacts(root, "conformance", run, cfg, "", "")
	if err != nil {
		t.Fatal(err)
	}
	gitIndex, err := repo.IndexPath()
	if err != nil {
		t.Fatal(err)
	}
	start := repo.Head()
	startTree, err := repo.Tree(start, nil)
	if err != nil {
		t.Fatal(err)
	}
	digests := map[string]string{}
	for _, p := range baseline {
		digests[p] = fileDigest(root, p)
	}
	t.Cleanup(func() { sys.Terminate(s.Groups()) })
	return &Attempt{
		State: State{
			Root: root, Slug: "conformance", Config: cfg, Start: start, Baseline: baseline, BaselineDigests: digests, Excluded: []string{},
			Run: run, GitIndex: gitIndex, StartTree: startTree, Phase: "building", T0: time.Now().UnixMilli(),
			Continuation: Continuation{Stage: StageBuilder}, ApprovalBytes: encodeBase64([]byte("approval")),
			WorkingContext: map[string]*OwnerContext{}, PromptCache: map[string]provider.CacheState{},
			Usage: zeroTokens(), AttemptUsage: zeroTokens(), CacheIDs: map[string]string{},
		},
		s: s, deps: Deps{Client: &provider.Client{Cache: provider.NewCache(nil), Version: "kogen dev+12345678 (test)"}},
		repo: repo, cache: provider.NewCache(nil), facts: facts,
	}
}

func TestNativeConformance(t *testing.T) {
	t.Parallel()
	conformance.Run(t, &nativeDriver{})
}

func TestNativeShellWriteToTheBaselineStopsTheRound(t *testing.T) {
	t.Parallel()
	// E3: prevention covers write_file only. A shell write to a protected file is not
	// prevented; Kogen's detection after the shell call stops the round with
	// candidate/baseline_changed (the conformance script documents the missing prevention).
	root := conformance.NewCheckout(t)
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	prov := newFakeProvider(t)
	prov.then(respondWith([]map[string]any{
		prov.call("shell", map[string]any{"command": "printf 'tampered\\n' > " + conformance.ProtectedPath}),
		prov.call("finish", map[string]any{"summary": "done"}),
	}, nil))
	b := newConformanceAttempt(t, root, home, prov, true)
	sess, err := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = sess.Round(context.Background(), executor.Input{})
	se, ok := sys.AsError(err)
	if !ok || se.Class != "candidate" || se.Reason != "baseline_changed" || !strings.Contains(se.Detail, conformance.ProtectedPath) {
		t.Fatalf("round error %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(root, conformance.ProtectedPath)); string(got) != "tampered\n" {
		t.Fatalf("protected file %q", got)
	}
}

func TestNativeRoundResultCarriesTheClaimAndTheProvidersUsage(t *testing.T) {
	t.Parallel()
	root := conformance.NewCheckout(t)
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	prov := newFakeProvider(t)
	usage := &conformance.ScriptUsage{Input: 120, Cached: 20, Output: 30}
	prov.then(
		respondWith([]map[string]any{prov.call("finish", map[string]any{"summary": "wrote the thing"})}, usage),
		respondWith([]map[string]any{{"type": "message", "id": "m", "role": "assistant", "content": []any{
			map[string]any{"type": "output_text", "text": "nothing else"}}}}, nil),
	)
	b := newConformanceAttempt(t, root, home, prov, true)
	sess, _ := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
	r1, err := sess.Round(context.Background(), executor.Input{})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "ending", r1.Ending, executor.EndFinish)
	eq(t, "claim", r1.Claim, "wrote the thing")
	eq(t, "usage", r1.Usage, executor.Usage{Input: intp(120), Cached: intp(20), Output: intp(30), Reasoning: intp(0), State: executor.UsageComplete, Source: executor.UsageProvider, Model: r1.Usage.Model})
	eq(t, "handle", r1.Handle, executor.Handle{Executor: executor.Native, Version: nativeVersion, SessionID: b.Run.ID, Resume: executor.ResumeExact})
	// The round's boundary is checkpointed with the finish call for the verification stage.
	eq(t, "stage", b.Continuation.Stage, StageBuilderVerify)
	if b.Continuation.Finish == nil || b.Continuation.Finish["name"] != "finish" {
		t.Fatalf("continuation %+v", b.Continuation)
	}
	// Feedback answers the finish call; the next round ends without a call.
	r2, err := sess.Round(context.Background(), executor.Input{Feedback: "fix the tests"})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "ending 2", r2.Ending, executor.EndNoCall)
	eq(t, "claim 2", r2.Claim, "nothing else")
	eq(t, "usage 2", r2.Usage.State, executor.UsageUnknown)
	if r2.Usage.Input != nil || r2.Usage.Output != nil {
		t.Fatalf("unknown usage carries numbers: %+v", r2.Usage)
	}
	if !slices.Contains(prov.toolOutputs(), "fix the tests") {
		t.Fatalf("feedback did not answer the finish call: %q", prov.toolOutputs())
	}
	eq(t, "stage 2", b.Continuation.Stage, StageBuilderVerify)
	if b.Continuation.Finish != nil {
		t.Fatalf("a no-call ending has no finish: %+v", b.Continuation)
	}
}

func TestNativeRoundMapsCancellationButKeepsTheSessionsInterrupt(t *testing.T) {
	t.Parallel()
	root := conformance.NewCheckout(t)
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	prov := newFakeProvider(t)
	prov.then(respondWith([]map[string]any{prov.call("shell", map[string]any{"command": "sleep 30"}), prov.call("finish", map[string]any{"summary": "x"})}, nil))
	b := newConformanceAttempt(t, root, home, prov, true)
	sess, _ := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
	// The caller interrupts the Session: the round returns the interrupt, exit code intact.
	go func() {
		for prov.count() == 0 {
			time.Sleep(10 * time.Millisecond)
		}
		time.Sleep(300 * time.Millisecond)
		b.s.Interrupt("SIGTERM")
	}()
	_, err := sess.Round(context.Background(), executor.Input{})
	var in *sys.Interrupted
	if !errors.As(err, &in) || in.Signal != "SIGTERM" {
		t.Fatalf("error %v", err)
	}
}

func TestNativeShellContextCancellationStops(t *testing.T) {
	root := conformance.NewCheckout(t)
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	prov := newFakeProvider(t)
	marker := filepath.Join(t.TempDir(), "started")
	prov.then(respondWith([]map[string]any{prov.call("shell", map[string]any{"command": "echo started > '" + marker + "'; sleep 30"})}, nil))
	b := newConformanceAttempt(t, root, home, prov, true)
	sess, _ := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := sess.Round(ctx, executor.Input{}); done <- err }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatal("shell did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	err := <-done
	if err == nil {
		t.Fatal("cancellation returned success")
	}
	for _, req := range prov.requests() {
		for _, v := range requestInput(req) {
			if m, ok := v.(map[string]any); ok && m["type"] == "function_call_output" && strings.Contains(fmt.Sprint(m["output"]), "timed out after") {
				t.Fatal("cancellation returned timeout feedback")
			}
		}
	}
}
