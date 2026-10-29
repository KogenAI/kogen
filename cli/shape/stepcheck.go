package shape

import (
	"context"
	"fmt"
	"strings"

	"kogen/project"
	"kogen/verify"
)

// The step self-check: before readiness, Kogen checks the step code of the candidate package
// with its own Node and Cucumber, so a broken step file comes back as feedback instead of
// wasting a readiness run or a Build.

const selfcheckHeadline = "Step self-check failed; nothing was published. Fix the step files and resubmit."

// selfcheckFeedback is the feedback of a failed self-check, empty when no item is a defect:
// warnings (unused definitions) are not defects.
func selfcheckFeedback(items []verify.StepItem) string {
	var lines []string
	for _, it := range items {
		if !it.OK {
			lines = append(lines, "- "+it.Check+" "+it.Target+": "+it.Detail)
		}
	}
	if len(lines) == 0 {
		return ""
	}
	return selfcheckHeadline + "\n" + strings.Join(lines, "\n")
}

// stepSelfcheck runs the self-check on the written candidate and records its one event. It
// returns the feedback text, empty when no item is a defect. Unused definitions of the
// Intent's own step files are warnings: the event lists them with their definition pattern and
// file, and they never make feedback.
func (sh *shaping) stepSelfcheck(ctx context.Context) (string, error) {
	intent, scenarios, err := project.CheckIntent(sh.root, sh.slug, nil)
	if err != nil {
		return "", nil // the package is not readable; readiness reports why
	}
	own, files, texts := verify.StepAnalysis(sh.root, intent, scenarios)

	var items []verify.StepItem
	if len(own) > 0 {
		raw, _, err := verify.RunStepScript(ctx, sh.stepTool(sh.rd.Tools.Node, "KOGEN_NODE"), sh.stepTool(sh.rd.Tools.Cucumber, "KOGEN_CUCUMBER"),
			sh.root, sh.s.Env, files, texts)
		if err != nil {
			return "", err
		}
		items = verify.StepItems(own, raw)
	}
	obs, err := sh.observerItems(ctx, intent)
	if err != nil {
		return "", err
	}
	items = append(items, obs...)

	all, ok := make([]any, 0, len(items)), true
	for _, it := range items {
		m := map[string]any{"check": it.Check, "target": it.Target, "ok": it.OK, "detail": it.Detail}
		if it.File != "" {
			m["file"] = it.File
		}
		if it.Warning {
			m["warning"] = true
		}
		all = append(all, m)
		ok = ok && it.OK
	}
	event := map[string]any{"event": "step_selfcheck", "ok": ok, "items": all}
	if warnings := verify.StepWarnings(items); len(warnings) > 0 {
		list := make([]any, len(warnings))
		for i, w := range warnings {
			list[i] = map[string]any{"pattern": w.Pattern, "file": w.File, "detail": w.Detail}
		}
		event["warnings"] = list
	}
	sh.ev.Record(event)
	return selfcheckFeedback(items), nil
}

// stepTool is a tool path of the readiness tools, else the environment variable.
func (sh *shaping) stepTool(configured, env string) string {
	if configured != "" {
		return configured
	}
	return sh.s.Getenv(env)
}

// observerItems re-runs the controls of every declared observer and compares each exit code
// with the recorded one.
func (sh *shaping) observerItems(ctx context.Context, intent *project.Intent) ([]verify.StepItem, error) {
	decls, err := verify.Declarations(intent)
	if err != nil {
		return nil, nil // invalid declarations are readiness's to report
	}
	var items []verify.StepItem
	for _, d := range decls {
		if d.Kind != "observer" {
			continue
		}
		for _, c := range d.Checks {
			r, err := sh.ev.Probe(func() (verify.ProbeResult, error) {
				return verify.Probe{Root: sh.root, Command: c.Command, Tools: sh.rd.Tools}.Run(ctx, sh.s)
			})
			if err != nil {
				return nil, err
			}
			it := verify.StepItem{Check: "observer", Target: d.ID + " " + c.Name, OK: r.Status == c.Exit && !r.TimedOut}
			if !it.OK {
				it.Detail = fmt.Sprintf("exit %d, recorded exit %d", r.Status, c.Exit)
			}
			items = append(items, it)
		}
	}
	return items, nil
}
