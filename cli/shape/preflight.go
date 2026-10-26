package shape

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
)

// PreflightInput is one `kogen intent preflight <slug> [--json]`.
type PreflightInput struct {
	Project  string // the checkout root
	Slug     string
	JSON     bool
	Checkout any // the checkout facts shown in JSON mode (project.CheckoutFacts); nil: read from Project
}

// preflightLimitation is the single limitation every preflight reports.
const preflightLimitation = "Setup, checks, hooks, providers, tool availability, signing and full readiness/resume safety were not executed or established. Build revalidates normally."

type preflightResult struct {
	Name     string
	Status   string
	Blockers []map[string]any
}

// Preflight prints point-in-time, read-only observations of whether a Build could start for
// the Intent; it authorizes nothing. Exit 0: no blocker; 1: blockers; 3: the project
// configuration could not be read (printed as the error). Git is only observed.
func Preflight(ctx context.Context, s *sys.Session, in PreflightInput) (int, error) {
	root := in.Project
	if !filepath.IsAbs(root) {
		root = filepath.Join(s.Cwd, root)
	}
	cfg, err := project.LoadConfig(root)
	if err != nil {
		if e, ok := sys.AsError(err); ok {
			preflightOutput(s, in, nil, preflightErrorValue(e))
			return 3, nil
		}
		return 1, err
	}
	repo := git.New(root, s.Env).Observing()
	slug := in.Slug

	var checks []preflightResult
	run := func(name string, fn func() error) error {
		c, err := preflightCheck(name, fn)
		checks = append(checks, c)
		return err
	}
	steps := []struct {
		name string
		fn   func() error
	}{
		{"configuration", func() error { return nil }},
		{"package", func() error { return preflightPackage(root, slug) }},
		{"approval", func() error { return preflightApproval(root, slug, cfg) }},
		{"cleanliness", func() error { return preflightClean(repo, root, slug) }},
		{"conflict", func() error { return preflightConflict(repo, root) }},
	}
	for _, step := range steps {
		if step.name == "cleanliness" && !project.IntentExists(root, slug) {
			checks = append(checks, preflightResult{Name: step.name, Status: "not_evaluated"})
			continue
		}
		if err := run(step.name, step.fn); err != nil {
			return 1, err
		}
	}
	if err := s.Err(); err != nil {
		return 130, err
	}

	blockers := []any{}
	checkValues := []any{}
	for _, c := range checks {
		checkValues = append(checkValues, map[string]any{"name": c.Name, "status": c.Status})
		for _, b := range c.Blockers {
			blockers = append(blockers, b)
		}
	}
	data := map[string]any{
		"slug":        slug,
		"ready":       len(blockers) == 0,
		"checks":      checkValues,
		"blockers":    blockers,
		"limitations": []any{preflightLimitation},
	}
	preflightOutput(s, in, data, nil)
	if len(blockers) == 0 {
		return 0, nil
	}
	return 1, nil
}

// preflightCheck runs one check: a *sys.Error is a blocker; any other error is a failure of
// the observation itself.
func preflightCheck(name string, fn func() error) (preflightResult, error) {
	err := fn()
	if err == nil {
		return preflightResult{Name: name, Status: "passed"}, nil
	}
	e, ok := sys.AsError(err)
	if !ok {
		return preflightResult{Name: name}, err
	}
	return preflightResult{Name: name, Status: "blocked", Blockers: []map[string]any{preflightErrorValue(e)}}, nil
}

func preflightErrorValue(e *sys.Error) map[string]any {
	paths := []any{}
	for _, l := range e.Lines {
		paths = append(paths, l)
	}
	return map[string]any{"class": e.Class, "reason": e.Reason, "detail": e.Detail, "paths": paths}
}

func preflightPackage(root, slug string) error {
	_, _, err := project.CheckIntent(root, slug, nil)
	e, ok := sys.AsError(err)
	if err == nil || !ok {
		return err
	}
	invalid := sys.Fail("intent", "invalid_package", strings.Join(e.Lines, "; "), 1)
	invalid.Lines = []string{project.IntentMDPath(slug), project.FeaturePath(slug)}
	return invalid
}

func preflightApproval(root, slug string, cfg *project.Config) error {
	var approval map[string]any
	if b, err := os.ReadFile(project.ApprovalPath(root, slug)); err == nil {
		if json.Unmarshal(b, &approval) != nil {
			approval = nil
		}
	}
	baseline, err := project.Baseline(root, slug, cfg)
	if err != nil {
		return err
	}
	if approval != nil && approval["sha256"] == project.Hash(root, baseline) {
		return nil
	}
	e := sys.Fail("intent", "approval_changed", "exact current approval is absent or changed", 1)
	e.Lines = []string{project.ApprovalPath(root, slug)}
	return e
}

// preflightClean is GIT-1: only this Intent's folder and acceptance files, and other
// Intents' own folders, may be uncommitted.
func preflightClean(repo *git.Repo, root, slug string) error {
	changed, err := repo.ChangedPaths()
	if err != nil {
		return err
	}
	intent, err := project.LoadIntent(root, slug)
	if err != nil {
		return err
	}
	own := project.IntentDir(slug) + "/"
	var dirty []string
	for _, p := range changed {
		other := strings.HasPrefix(p, ".kogen/intents/") && !strings.HasPrefix(p, own)
		if !other && !slices.Contains(intent.Acceptance, p) && !strings.HasPrefix(p, own) {
			dirty = append(dirty, p)
		}
	}
	if len(dirty) == 0 {
		return nil
	}
	e := sys.Fail("environment", "dirty_tree",
		fmt.Sprintf("%d changed path(s) are not part of an Intent; commit, stash or discard them first", len(dirty)), 5)
	e.Lines = dirty[:min(len(dirty), 20)]
	return e
}

func preflightConflict(repo *git.Repo, root string) error {
	op, err := repo.OperationInProgress()
	if err != nil {
		return err
	}
	if op != "" {
		return sys.Fail("environment", "git_operation_in_progress", op, 1)
	}
	held, err := git.NewLock(git.BuildLockPath(root)).Held()
	if err != nil {
		return err
	}
	if held {
		return sys.Fail("environment", "build_running", "a Build owns this checkout", 1)
	}
	return nil
}

func preflightOutput(s *sys.Session, in PreflightInput, data, errValue map[string]any) {
	if in.JSON {
		checkout := in.Checkout
		if checkout == nil {
			if c, err := project.Checkout(in.Project); err == nil {
				checkout = c
			}
		}
		doc := map[string]any{"schema_version": 1, "kind": "preflight", "checkout": checkout, "data": nil, "error": nil}
		if data != nil {
			doc["data"] = data
		}
		if errValue != nil {
			doc["error"] = errValue
		}
		b, err := project.EncodeJSON(doc)
		if err != nil {
			b = []byte(fmt.Sprintf("%q", err.Error()))
		}
		s.Puts(string(b))
		return
	}
	if data == nil {
		s.Puts("preflight: " + errValue["detail"].(string))
		return
	}
	state := "blocked"
	if data["ready"].(bool) {
		state = "ready (observations only)"
	}
	s.Puts(fmt.Sprintf("preflight %s: %s", in.Slug, state))
	for _, c := range data["checks"].([]any) {
		c := c.(map[string]any)
		s.Puts(fmt.Sprintf("  %s: %s", c["name"], c["status"]))
	}
	for _, b := range data["blockers"].([]any) {
		b := b.(map[string]any)
		s.Puts(fmt.Sprintf("  %s/%s: %s", b["class"], b["reason"], b["detail"]))
		for _, p := range b["paths"].([]any) {
			s.Puts("    " + p.(string))
		}
	}
	for _, l := range data["limitations"].([]any) {
		s.Puts("  " + l.(string))
	}
}
