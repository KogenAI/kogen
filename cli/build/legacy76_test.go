package build

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The version 3 checkpoints of the CURRENT Elixir Kogen (main 76109e1a): testdata/legacy76/gen.exs
// builds them with the real modules (Kogen.Build.save/2, Kogen.Stages.retain/2,
// Kogen.ReviewMaterial.prepare/8) and reads each one back with Kogen.Run.decode_checkpoint/1.
// They carry what the bdfd607 checkpoints of testdata/legacy do not: staged-plan progress and
// stage evidence in private custody, the raw identity of a builder-reported blocker's candidate,
// nullable usage counts and the reviewer's inline source with its tree.

const legacy76Dir = "testdata/legacy76"

type legacy76Case struct {
	ID         string            `json:"id"`
	Checkpoint string            `json:"checkpoint"`
	Project    string            `json:"project"`
	Edits      map[string]string `json:"edits"`
	Modes      map[string]string `json:"modes"`
	Custody    map[string]string `json:"custody"`
	PassTree   string            `json:"pass_tree"`
	Commit     string            `json:"commit"`
	StartTree  string            `json:"start_tree"`
}

type legacy76Manifest struct {
	Root      string                  `json:"root"`
	Slug      string                  `json:"slug"`
	Start     string                  `json:"start"`
	Tracked   []string                `json:"tracked"`
	AuthorEnv map[string]string       `json:"author_env"`
	Cases     map[string]legacy76Case `json:"cases"`
}

func legacy76Load(t testing.TB) legacy76Manifest {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(legacy76Dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m legacy76Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func legacy76Doc(t testing.TB, c legacy76Case) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(legacy76Dir, c.Checkpoint))
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

type legacy76Options struct {
	state    func(m *legacyMap)
	envelope func(doc map[string]any)
}

// newLegacy76Env makes the repository of the case's project at a new place (the start commit
// and every tree are the Elixir Kogen's, byte for byte), brings it into the state the case was
// saved in, installs the private stage evidence the Build kept in its run folder, and writes
// the Elixir checkpoint with the paths moved. It returns the repository and the Build's id.
func newLegacy76Env(t *testing.T, name string, opts ...func(*legacy76Options)) (*env, string) {
	t.Helper()
	var o legacy76Options
	for _, f := range opts {
		f(&o)
	}
	man := legacy76Load(t)
	c, ok := man.Cases[name]
	if !ok {
		t.Fatalf("no fixture case %q", name)
	}
	e := &env{t: t, root: physical(t, t.TempDir()), home: physical(t, t.TempDir()), aux: physical(t, t.TempDir()), prov: newFakeProvider(t)}
	e.hooks = t.TempDir()
	e.git = isolatedEnv()
	for k, v := range man.AuthorEnv {
		e.git = append(e.git, k+"="+v)
	}
	e.run("git", "init", "-q", "--initial-branch=main")
	for k, v := range map[string]string{"user.name": "Kogen Fixture", "user.email": "kogen-fixture@example.invalid",
		"commit.gpgsign": "false", "core.hooksPath": e.hooks} {
		e.run("git", "config", k, v)
	}
	project := filepath.Join(legacy76Dir, c.Project)
	var approval []byte
	err := filepath.WalkDir(project, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(project, path)
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if rel == "APPROVAL" {
			approval = b
			return nil
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(rel, ".sh") {
			mode = 0o755
		}
		writeFile(t, filepath.Join(e.root, rel), string(b), mode)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	e.run("git", append([]string{"add"}, man.Tracked...)...)
	e.run("git", "commit", "-qm", "fixture baseline")
	if got := e.head(); got != man.Start {
		t.Fatalf("the start commit is %s, the Elixir Kogen's is %s: the fixture project and gen.exs have drifted apart", got, man.Start)
	}
	// The Build made the tree of its start (the objects stay in the repository).
	if tree, err := e.gitRepo().Tree(man.Start, nil); err != nil || tree != c.StartTree {
		t.Fatalf("the tree of the start is %s (%v), the Elixir Kogen's is %s", tree, err, c.StartTree)
	}
	for rel, text := range c.Edits {
		e.write(rel, text)
		if mode, ok := c.Modes[rel]; ok {
			bits := map[string]os.FileMode{"755": 0o755, "644": 0o644}[mode]
			if err := os.Chmod(filepath.Join(e.root, rel), bits); err != nil {
				t.Fatal(err)
			}
		}
	}
	if c.Commit != "" {
		e.run("git", "add", "-A")
		msg := filepath.Join(e.aux, "commit-message.txt")
		writeFile(t, msg, "Preserve the fixture\n\nKogen-Intent: fixture\n", 0o644)
		e.run("git", "commit", "-q", "-F", msg)
		if got := e.head(); got != c.Commit {
			t.Fatalf("the landed commit is %s, the Elixir Kogen's is %s", got, c.Commit)
		}
	} else {
		writeFile(t, filepath.Join(e.root, ".kogen/local/approvals/fixture.json"), string(approval), 0o644)
	}
	index, err := os.ReadFile(filepath.Join(e.root, ".git/index"))
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(e.root, ".kogen/local/runs", c.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "index-at-start"), string(index), 0o644)
	writeFile(t, filepath.Join(dir, "result.json"), `{"build":"`+c.ID+`","outcome":"interrupted","slug":"fixture"}`+"\n", 0o644)
	for file, source := range c.Custody {
		b, err := os.ReadFile(filepath.Join(legacy76Dir, source))
		if err != nil {
			t.Fatal(err)
		}
		writeFile(t, filepath.Join(dir, file), string(b), 0o600)
	}

	doc := legacy76Doc(t, c)
	raw, err := base64.StdEncoding.DecodeString(doc["state"].(string))
	if err != nil {
		t.Fatal(err)
	}
	term, err := legacyDecodeTerm(raw)
	if err != nil {
		t.Fatal(err)
	}
	moved := legacyReplace(legacyReplace(term, "/private"+man.Root, e.root), man.Root, e.root).(*legacyMap)
	if o.state != nil {
		o.state(moved)
	}
	doc["state"] = base64.StdEncoding.EncodeToString(legacyEncode(moved))
	identity, err := fileIdentity(e.root)
	if err != nil {
		t.Fatal(err)
	}
	candidate, err := e.gitRepo().Tree(man.Start, nil)
	if err != nil {
		t.Fatal(err)
	}
	doc["identity"], doc["candidate"], doc["index"] = identity, candidate, base64.StdEncoding.EncodeToString(index)
	if doc["recovery_raw"] != nil {
		// The identity the Elixir Build recorded is of its own checkout's files: the bytes and
		// modes are the same here, and so are the paths.
		_ = doc["recovery_raw"]
	}
	if o.envelope != nil {
		o.envelope(doc)
	}
	writeFile(t, filepath.Join(dir, "checkpoint.json"), string(legacyJSONBytes(t, doc)), 0o600)
	return e, c.ID
}

func (e *env) legacy76Checkpoint(id string) []byte {
	e.t.Helper()
	b, err := os.ReadFile(e.runPath(id, "checkpoint.json"))
	if err != nil {
		e.t.Fatal(err)
	}
	return b
}

func TestEveryMain76CheckpointDecodes(t *testing.T) {
	// ExUnit: lib/kogen/run.ex decode_checkpoint/1 (valid_state?/2 on the Build map as Build.save/2 wrote it at main 76109e1a)
	man := legacy76Load(t)
	for name := range man.Cases {
		t.Run(name, func(t *testing.T) {
			e, id := newLegacy76Env(t, name)
			loaded, why := decodeCheckpoint(e.legacy76Checkpoint(id), legacyDecode)
			if strings.HasSuffix(name, "tool_request") && strings.HasPrefix(name, "staged_") {
				// Kogen.Stages gives a tool boundary that a model request saved no valid phase.
				eq(t, "reason", why, "malformed required checkpoint fields")
				return
			}
			if why != "" {
				t.Fatalf("refused: %s", why)
			}
			st := loaded.State
			eq(t, "version", loaded.Doc.Version, 3)
			eq(t, "run id", st.Run.ID, id)
			eq(t, "doc progress", sameProgress(loaded.Doc.StageProgress, st.StageProgress), true)
			staged := strings.HasPrefix(name, "staged_")
			eq(t, "staged", st.StageProgress != nil, staged)
			eq(t, "plan", len(st.StagePlan) == 2, staged)
			if !staged && (len(st.StageEvidence) != 0 || st.StagePlan != nil) {
				t.Fatal("stage state in an unstaged Build")
			}
			if len(st.PromptCache) != 1 {
				t.Fatalf("cache states %v", st.PromptCache)
			}
		})
	}
}

func TestMain76StagedStateIsReadWithItsEvidence(t *testing.T) {
	// ExUnit: lib/kogen/stages.ex valid?/1 (progress, ordered evidence, private custody and the approved contract)
	e, id := newLegacy76Env(t, "staged_builder_second")
	loaded, why := decodeCheckpoint(e.legacy76Checkpoint(id), legacyDecode)
	if why != "" {
		t.Fatal(why)
	}
	st := loaded.State
	eq(t, "progress", canonical(st.StageProgress.value()), `{"active":"surface","completed":["foundation"],"phase":"stage","total":2}`)
	eq(t, "records", len(st.StageEvidence), 2)
	red, green := st.StageEvidence[0], st.StageEvidence[1]
	eq(t, "red", red.Pass.Green, false)
	eq(t, "red failing", red.Pass.Failing, []string{"stage-foundation-1"})
	eq(t, "red not run", red.Pass.NotRun, []string{"stage-foundation-2"})
	contains(t, "red output", red.Pass.Checks[0].Output, "scoped red")
	eq(t, "green", green.Pass.Green && green.Pass.Clean, true)
	eq(t, "green stage", green.StageID+"/"+itoa(green.Index), "foundation/1")
	eq(t, "contract", green.Contract, st.ApprovalBytes)
	for _, ev := range st.StageEvidence {
		if ev.Custody == nil || !strings.HasPrefix(ev.Custody.Path, e.root+"/.kogen/local/runs/"+id+"/stage-") {
			t.Fatalf("custody %+v", ev.Custody)
		}
	}
	eq(t, "plan", st.StagePlan[0].Title+" | "+st.StagePlan[0].Goal, "Foundation | First runnable section — é")
	// Staged navigation: the Elixir Kogen's own text.
	contains(t, "navigation", st.navigation(), "\nStaged plan progress: {\"active\":\"surface\",\"completed\":[\"foundation\"],\"phase\":\"stage\",\"total\":2}\nActive stage 2/2: ")
}

func TestMain76NullableUsageIsKept(t *testing.T) {
	// ExUnit: test/kogen/run_test.exs: usage counts may be nil, a missing key or a non-integer are refused
	e, id := newLegacy76Env(t, "nullable_usage")
	loaded, why := decodeCheckpoint(e.legacy76Checkpoint(id), legacyDecode)
	if why != "" {
		t.Fatal(why)
	}
	u := loaded.State.Usage
	if u.Input != nil || u.Cached != nil || u.Reasoning != nil || u.Output == nil || *u.Output != 1 {
		t.Fatalf("usage %+v", u)
	}
	eq(t, "line", u.Line(), "input=unknown cached=unknown output=1 reasoning=unknown")
	eq(t, "total", u.Total(), "unknown")
}

func TestMain76ReviewerKeepsItsInlineSourceAndTree(t *testing.T) {
	// ExUnit: test/integration/review_material_test.exs: fitted inline source relocates on pressure
	e, id := newLegacy76Env(t, "review")
	loaded, why := decodeCheckpoint(e.legacy76Checkpoint(id), legacyDecode)
	if why != "" {
		t.Fatal(why)
	}
	owner := loaded.State.WorkingContext["review"]
	if owner == nil || owner.InlineMaterial == nil || owner.SourceTree == nil {
		t.Fatalf("review context %+v", owner)
	}
	eq(t, "tree", *owner.SourceTree, loaded.State.LastPass.Tree)
	eq(t, "files", len(owner.InlineMaterial.Files), 1)
	eq(t, "file", owner.InlineMaterial.Files[0]["path"], any("app.txt"))
	eq(t, "checks", owner.InlineMaterial.Checks, "acceptance: passed (2 scenarios)")
}

func TestMain76RecoveryIdentityOfABlockerIsRecorded(t *testing.T) {
	// ExUnit: test/integration/recovery_test.exs (the raw identity recorded with each checkpoint of a Build that reported a blocker)
	e, id := newLegacy76Env(t, "blocker_edits")
	loaded, why := decodeCheckpoint(e.legacy76Checkpoint(id), legacyDecode)
	if why != "" {
		t.Fatal(why)
	}
	got := loaded.Doc.RecoveryRaw
	if got == nil || got["app.txt"] == nil || got["src/new.txt"] == nil || got["src/new.txt"].Mode != "100755" {
		t.Fatalf("recovery raw %v", got)
	}
	// The identity the Elixir Kogen recorded is the one this one computes for the same files.
	man := legacy76Load(t)
	again, err := rawIdentity(e.gitRepo(), e.root, loaded.State.StartTree)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(again, got) {
		t.Fatalf("identity differs:\n%v\n%v", again, got)
	}
	_ = man
}

func TestMain76BuildsResumeAndLand(t *testing.T) {
	// ExUnit: test/integration/stages_test.exs: stage scratch mutations are red, ordered red stops commands, fresh setup and milestone custody survive Resume
	type scenario struct {
		name   string
		script func(e *env)
		check  func(t *testing.T, e *env, id, child string, r *attempt)
	}
	approve := func(e *env) {
		f := e.prov
		f.then(f.calls("submit_review", approveVerdict()))
	}
	scenarios := []scenario{
		{name: "builder", script: func(e *env) {
			f := e.prov
			f.then(f.calls("finish", map[string]any{"summary": "done"}), f.calls("submit_review", approveVerdict()))
		}},
		{name: "builder_verify", script: approve},
		{name: "review", script: approve},
		{name: "review_verify", script: approve},
		{name: "nullable_usage", script: func(e *env) {
			f := e.prov
			f.then(f.calls("finish", map[string]any{"summary": "done"}), f.calls("submit_review", approveVerdict()))
		}, check: func(t *testing.T, e *env, id, child string, r *attempt) {
			res := e.result(child)
			usage := res["usage"].(map[string]any)
			// Unknown stays unknown: the saved nil counts are not counted as zero.
			eq(t, "input", usage["input"], nil)
			eq(t, "cached", usage["cached"], nil)
			eq(t, "output", usage["output"], any(float64(3)))
			contains(t, "stdout", r.out.String(), "tokens: unknown")
		}},
		{name: "staged_builder_second", script: func(e *env) {
			f := e.prov
			f.then(f.calls("finish", map[string]any{"summary": "stage two"}), f.calls("submit_review", approveVerdict()))
		}, check: func(t *testing.T, e *env, id, child string, r *attempt) {
			lacks(t, "stdout", r.out.String(), "stage foundation gate")
			contains(t, "progress", r.errs.String(), "kogen: stage surface gate passed")
			events := e.events(child)
			stages := eventsNamed(events, "stage_pass")
			eq(t, "stage records", len(stages), 1)
			eq(t, "stage", stages[0]["stage_id"], any("surface"))
			_, state := e.checkpoint(child)
			p := state["stage_progress"].(map[string]any)
			eq(t, "phase", p["phase"], any("landed"))
			eq(t, "completed", p["completed"], any([]any{"foundation", "surface"}))
			eq(t, "evidence", len(state["stage_evidence"].([]any)), 3)
		}},
		{name: "staged_builder_second_verify", script: func(e *env) {
			f := e.prov
			f.then(f.calls("submit_review", approveVerdict()))
		}, check: func(t *testing.T, e *env, id, child string, r *attempt) {
			contains(t, "progress", r.errs.String(), "kogen: stage surface gate passed")
		}},
		{name: "staged_builder_final", script: approve},
		{name: "staged_review_final", script: approve},
	}
	for _, sc := range scenarios {
		t.Run(sc.name, func(t *testing.T) {
			e, id := newLegacy76Env(t, sc.name)
			sc.script(e)
			before := e.runFiles(id)
			r := legacyResume(e, id)
			if r.exit != 0 || r.err != nil {
				t.Fatalf("exit %d err %v\n%s\n%s", r.exit, r.err, r.shown(), r.errs.String())
			}
			man := legacy76Load(t)
			child := legacyChild(t, e, id)
			contains(t, "stdout", r.out.String(), "resuming Build "+id+" as "+child+" (root "+id+")\n")
			contains(t, "stdout", r.out.String(), "landed fixture ")
			eq(t, "commits", e.gitOut("rev-list", "--count", man.Start+"..HEAD"), "1")
			if !reflect.DeepEqual(e.runFiles(id), before) {
				t.Fatal("the files of the Elixir Build changed")
			}
			doc, state := e.checkpoint(child)
			eq(t, "child version", doc["version"], any(float64(4)))
			eq(t, "child stage", state["continuation"].(map[string]any)["stage"], any("landed"))
			if sc.check != nil {
				sc.check(t, e, id, child, r)
			}
		})
	}
}

func TestMain76StagedLandedBuildIsANoOp(t *testing.T) {
	// ExUnit: test/integration/stages_test.exs: Resume refuses phase claims inconsistent with final work, reviewer ownership or landing
	e, id := newLegacy76Env(t, "staged_landed_final")
	commit := e.head()
	r := legacyResume(e, id)
	eq(t, "exit", r.exit, 0)
	eq(t, "stdout", r.out.String(), "Build "+id+" already landed "+commit+"\n")
	eq(t, "requests", e.prov.count(), 0)
}

func TestMain76StagedBoundariesAreRefused(t *testing.T) {
	// ExUnit: lib/kogen/stages.ex valid_phase?/2 (a request's tool boundary is no stage owner's) and test/integration/build_boundaries_test.exs (tool boundaries are uncertain)
	for _, c := range []struct{ name, want string }{
		{"staged_tool_second", "uncertain tool boundary; inspect effects before starting a freshly approved Build"},
		{"staged_tool_request", "malformed required checkpoint fields"},
		{"tool", "uncertain tool boundary; inspect effects before starting a freshly approved Build"},
		{"tool_request", "uncertain tool boundary; inspect effects before starting a freshly approved Build"},
	} {
		t.Run(c.name, func(t *testing.T) {
			e, id := newLegacy76Env(t, c.name)
			before, files, runs := e.state(), e.runFiles(id), e.runIDs()
			r := e.resume(id)
			eq(t, "exit", r.exit, 1)
			contains(t, "output", r.shown(), "candidate/resume_refused: Build "+id+": "+c.want)
			if !reflect.DeepEqual(e.state(), before) || !reflect.DeepEqual(e.runFiles(id), files) || !reflect.DeepEqual(e.runIDs(), runs) || e.prov.count() != 0 {
				t.Fatal("custody or runs changed")
			}
		})
	}
}

func TestMain76StagedResumeRefusesInconsistentProgressAndEvidence(t *testing.T) {
	// ExUnit: test/integration/stages_test.exs: Resume refuses phase claims, corrupted navigation and altered evidence
	progress := func(f func(p *legacyMap)) func(*legacy76Options) {
		return func(o *legacy76Options) {
			o.state = func(m *legacyMap) { f(legacyDigMap(t, m, latom("stage_progress"))) }
			o.envelope = nil
		}
	}
	both := func(f func(p map[string]any)) func(*legacy76Options) {
		return func(o *legacy76Options) {
			o.state = nil
			o.envelope = func(doc map[string]any) { f(doc["stage_progress"].(map[string]any)) }
		}
	}
	cases := []struct {
		name string
		opts func(*legacy76Options)
		prep func(e *env, id string)
	}{
		{name: "envelope without the progress", opts: func(o *legacy76Options) {
			o.envelope = func(doc map[string]any) { delete(doc, "stage_progress") }
		}},
		{name: "state without the progress", opts: func(o *legacy76Options) {
			o.state = func(m *legacyMap) { legacyPut(m, latom("stage_progress"), latom("nil")) }
		}},
		{name: "completed cleared in the state", opts: progress(func(p *legacyMap) { legacyPut(p, "completed", []any{}) })},
		{name: "active stage claims the first", opts: progress(func(p *legacyMap) { legacyPut(p, "active", "foundation") })},
		{name: "phase claims review", opts: func(o *legacy76Options) {
			o.state = func(m *legacyMap) { legacyPut(legacyDigMap(t, m, latom("stage_progress")), "phase", "review") }
			o.envelope = func(doc map[string]any) { doc["stage_progress"].(map[string]any)["phase"] = "review" }
		}},
		{name: "phase claims landed", opts: func(o *legacy76Options) {
			o.state = func(m *legacyMap) { legacyPut(legacyDigMap(t, m, latom("stage_progress")), "phase", "landed") }
			o.envelope = func(doc map[string]any) { doc["stage_progress"].(map[string]any)["phase"] = "landed" }
		}},
		{name: "envelope progress differs", opts: both(func(p map[string]any) { p["total"] = float64(3) })},
		{name: "evidence tree altered", opts: func(o *legacy76Options) {
			o.state = func(m *legacyMap) {
				list := legacyDig(t, m, latom("stage_evidence")).([]any)
				legacyPut(list[0].(*legacyMap), latom("tree"), strings.Repeat("0", 40))
			}
		}},
		{name: "evidence file changed", prep: func(e *env, id string) {
			matches, _ := filepath.Glob(filepath.Join(e.runPath(id, "stage-*.json")))
			os.WriteFile(matches[0], []byte("{}\n"), 0o600)
		}},
		{name: "evidence file mode", prep: func(e *env, id string) {
			matches, _ := filepath.Glob(filepath.Join(e.runPath(id, "stage-*.json")))
			os.Chmod(matches[0], 0o644)
		}},
		{name: "evidence file removed", prep: func(e *env, id string) {
			matches, _ := filepath.Glob(filepath.Join(e.runPath(id, "stage-*.json")))
			os.Remove(matches[0])
		}},
		{name: "evidence folder not private", prep: func(e *env, id string) { os.Chmod(e.runPath(id, ""), 0o755) }},
		{name: "plan drift", opts: func(o *legacy76Options) {
			o.state = func(m *legacyMap) {
				legacyPut(m, latom("stage_plan"), legacyDig(t, m, latom("stage_plan")).([]any)[:1])
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var opts []func(*legacy76Options)
			if c.opts != nil {
				opts = append(opts, c.opts)
			}
			e, id := newLegacy76Env(t, "staged_builder_second", opts...)
			if c.prep != nil {
				c.prep(e, id)
			}
			before, files, runs := e.state(), e.runFiles(id), e.runIDs()
			cp := string(e.legacy76Checkpoint(id))
			r := e.resume(id)
			eq(t, "exit", r.exit, 1)
			contains(t, "output", r.shown(), "candidate/resume_refused: Build "+id+": malformed required checkpoint fields;")
			if string(e.legacy76Checkpoint(id)) != cp || !reflect.DeepEqual(e.state(), before) || !reflect.DeepEqual(e.runIDs(), runs) {
				t.Fatal("custody or runs changed")
			}
			if c.prep == nil && !reflect.DeepEqual(e.runFiles(id), files) {
				t.Fatal("the evidence of the Build changed")
			}
			eq(t, "requests", e.prov.count(), 0)
		})
	}
}
