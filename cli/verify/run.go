package verify

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
)

// Input is everything one verification pass needs.
type Input struct {
	Root     string          // the user's checkout
	Repo     *git.Repo       // Git at Root; nil: git.New(Root, session env)
	Config   *project.Config // the project's commands
	Intent   *project.Intent // the Intent being built; its Model is the model to check
	Start    string          // the HEAD the Build started from
	Excluded []string        // other uncommitted Intents' folders, left out of the candidate
	N        int             // the pass number
	RunDir   string          // the run's evidence folder: acceptance-N.ndjson goes there
	Tools    Tools
	Log      Logger
	Evidence Evidence
	// Stage, when set, makes the pass a scoped stage gate: the setup commands, then only the
	// stage's checks (named stage-<id>-<n>). Acceptance, the model and the project's checks
	// are not part of it, so such a pass is never whole-Intent proof.
	Stage *Stage
	// Intact is the baseline guard (VER-8): it returns the refusal when the approved baseline
	// changed. It runs after each fixer and after the pass's commands.
	Intact func() error
}

// Stage is the gate of one milestone of a staged Build.
type Stage struct {
	ID     string
	Checks []string
}

func (in Input) repo(s *sys.Session) *git.Repo {
	if in.Repo != nil {
		return in.Repo
	}
	return git.New(in.Root, s.Env)
}

func (in Input) intact() error {
	if in.Intact == nil {
		return nil
	}
	return in.Intact()
}

func (in Input) model() *project.ModelSpec {
	if in.Intent == nil || in.Intent.Model == nil || in.Intent.Model.None {
		return nil
	}
	return in.Intent.Model
}

func (in Input) acceptanceRun() string {
	if in.Config.Acceptance == nil {
		return ""
	}
	return in.Config.Acceptance.Run
}

// Run is a builder round's end (VER-6): the fixers once in the checkout, then a pass.
func Run(ctx context.Context, s *sys.Session, in Input) (Pass, error) {
	if err := Fix(ctx, s, in); err != nil {
		return Pass{}, err
	}
	return Verify(ctx, s, in)
}

// Fix runs `commands.fix` once, in order, in the checkout, checking the baseline after each.
func Fix(ctx context.Context, s *sys.Session, in Input) error {
	for i, cmd := range in.Config.Fix {
		name := fmt.Sprintf("fix-%d", i+1)
		logEvent(in.Log, map[string]any{"event": "command", "name": name, "command": cmd})
		r, err := runStep(ctx, s, in.Tools, name, in.Log, cmd, in.Root, nil)
		if err != nil {
			return err
		}
		logEvent(in.Log, map[string]any{"event": "command_result", "name": name, "status": r.Status, "output": Cap(r.Output)})
		if err := in.intact(); err != nil {
			return err
		}
	}
	return nil
}

type item struct {
	name    string
	kind    string // setup, acceptance, model, check
	command string
}

// Verify runs one pass over the current candidate (VER-6, VER-7, VER-9): the exact clean
// candidate tree is materialized into a `kogen-verify-*` scratch directory with a synthetic
// Git; setup commands run in order, then acceptance, the applicable model and the project's
// checks in declaration order, stopping between items at the first definitive red. The
// later items are named in NotRun. Files that changed in the scratch inputs or in the
// checkout while the checks ran make the pass not green. The scratch directory is removed
// whatever happens.
func Verify(ctx context.Context, s *sys.Session, in Input) (Pass, error) {
	s.Progress(fmt.Sprintf("kogen: verifying (pass %d)", in.N))
	repo := in.repo(s)
	before, err := repo.Tree(in.Start, in.Excluded)
	if err != nil {
		return Pass{}, err
	}
	var report string
	if in.RunDir != "" {
		report = filepath.Join(in.RunDir, fmt.Sprintf("acceptance-%d.ndjson", in.N))
	} else {
		dir := sys.TmpPath("kogen-verify-report")
		defer os.RemoveAll(dir)
		report = filepath.Join(dir, "acceptance.ndjson")
	}
	model := in.model()

	var items []item
	for i, cmd := range in.Config.Setup {
		items = append(items, item{fmt.Sprintf("setup-%d", i+1), "setup", cmd})
	}
	if in.Stage != nil {
		for i, cmd := range in.Stage.Checks {
			items = append(items, item{fmt.Sprintf("stage-%s-%d", in.Stage.ID, i+1), "check", cmd})
		}
	} else {
		items = append(items, item{"acceptance", "acceptance", ""})
		if model != nil {
			items = append(items, item{"model", "model", ""})
		}
		for _, c := range in.Config.Checks {
			items = append(items, item{c.Name, "check", c.Run})
		}
	}

	p := Pass{N: in.N, Tree: before, Clean: true, Model: ModelNotRun, NotRun: []string{}, Setup: []CommandResult{}, Checks: []CommandResult{}}
	if model == nil {
		p.Model = ModelNone
	}
	scratchMoved, red, err := func() ([]string, bool, error) {
		scratch := sys.TmpPath("kogen-verify")
		defer os.RemoveAll(scratch)
		mat, err := repo.Materialize(before, scratch)
		if err != nil {
			return nil, false, err
		}
		if err := os.MkdirAll(filepath.Join(scratch, ".kogen/local"), 0o755); err != nil {
			return nil, false, err
		}
		red := false
		for _, it := range items {
			if red {
				p.NotRun = append(p.NotRun, it.name)
				continue
			}
			switch it.kind {
			case "acceptance":
				a, err := RunAcceptance(ctx, s, scratch, in.Tools, in.Intent.Slug, in.acceptanceRun(), report, in.Evidence, in.Log)
				if err != nil {
					return nil, false, err
				}
				p.Acceptance = &a
				red = len(a.Problems) > 0
			case "model":
				m, err := CheckModel(ctx, s, scratch, in.Tools, model, in.Evidence, in.Log)
				if err != nil {
					return nil, false, err
				}
				p.Model = m
				red = m.Failed()
			default:
				if it.kind == "setup" {
					s.Progress(fmt.Sprintf("kogen: running %s: %s", it.name, it.command))
					count(in.Evidence, "setup")
				}
				r, err := runLogged(ctx, s, in, scratch, it.name, it.command)
				if err != nil {
					return nil, false, err
				}
				if it.kind == "setup" {
					p.Setup = append(p.Setup, r)
				} else {
					p.Checks = append(p.Checks, r)
				}
				red = r.Status != 0
			}
		}
		moved, err := mat.Mutations()
		return moved, red, err
	}()
	if err != nil {
		return Pass{}, err
	}

	if err := in.intact(); err != nil {
		return Pass{}, err
	}
	after, err := repo.Tree(in.Start, in.Excluded)
	if err != nil {
		return Pass{}, err
	}
	changed, err := repo.Changed(before, after)
	if err != nil {
		return Pass{}, err
	}
	p.Moved = unique(slices.Concat(scratchMoved, changed))
	p.Failing = []string{}
	if p.Acceptance != nil && len(p.Acceptance.Problems) > 0 {
		p.Failing = append(p.Failing, "acceptance")
	}
	if p.Model.Failed() {
		p.Failing = append(p.Failing, "model")
	}
	for _, c := range slices.Concat(p.Setup, p.Checks) {
		if c.Status != 0 {
			p.Failing = append(p.Failing, c.Name)
		}
	}
	p.Green = !red && len(p.NotRun) == 0 && len(p.Failing) == 0 && len(p.Moved) == 0
	s.Progress(p.Summary())
	logEvent(in.Log, map[string]any{"event": "pass", "pass": in.N, "green": p.Green, "failing": p.Failing,
		"not_run": p.NotRun, "files_changed_while_checks_ran": p.Moved})
	return p, nil
}

func unique(paths []string) []string {
	out := []string{}
	for _, p := range paths {
		if !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

func runLogged(ctx context.Context, s *sys.Session, in Input, dir, name, command string) (CommandResult, error) {
	logEvent(in.Log, map[string]any{"event": "command", "name": name, "command": command, "cwd": dir})
	r, err := runStep(ctx, s, in.Tools, name, in.Log, command, dir, nil)
	if err != nil {
		return CommandResult{}, err
	}
	logEvent(in.Log, map[string]any{"event": "command_result", "name": name, "status": r.Status, "output": Cap(r.Output)})
	return CommandResult{Name: name, Command: command, Status: r.Status, Output: r.Output}, nil
}

// RunAcceptance runs the acceptance command in root on the Intent's feature with
// KOGEN_ACCEPTANCE_FEATURES (the feature path relative to root) and KOGEN_ACCEPTANCE_REPORT
// (report), then accounts for its Cucumber Messages report (VER-3, VER-4).
func RunAcceptance(ctx context.Context, s *sys.Session, root string, tools Tools, slug, command, report string, ev Evidence, log Logger) (Acceptance, error) {
	count(ev, "acceptance")
	feature := project.FeaturePath(slug)
	text, err := os.ReadFile(filepath.Join(root, feature))
	if err != nil {
		return Acceptance{}, err
	}
	expected, err := project.ParseGherkin(string(text))
	if err != nil {
		return Acceptance{}, fmt.Errorf("%s: %w", feature, err)
	}
	os.Remove(report)
	if err := os.MkdirAll(filepath.Dir(report), 0o755); err != nil {
		return Acceptance{}, err
	}
	logEvent(log, map[string]any{"event": "command", "name": "acceptance", "command": command})
	r, err := runStep(withStep(ctx, "acceptance", "acceptance"), s, tools, "acceptance", log, command, root, map[string]string{
		"KOGEN_ACCEPTANCE_FEATURES": feature,
		"KOGEN_ACCEPTANCE_REPORT":   report,
	})
	if err != nil {
		return Acceptance{}, err
	}
	logEvent(log, map[string]any{"event": "command_result", "name": "acceptance", "status": r.Status, "output": Cap(r.Output)})
	return Account(root, feature, expected, report, r.Status, r.Output), nil
}
