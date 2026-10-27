package shape

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"kogen/project"
	"kogen/verify"
)

// The step self-check: before readiness, Kogen checks the step code of the candidate package
// with its own Node and Cucumber, so a broken step file comes back as feedback instead of
// wasting a readiness run or a Build.

const stepsFolder = "features/steps/"

const selfcheckHeadline = "Step self-check failed; nothing was published. Fix the step files and resubmit."

// scItem is one thing the self-check looked at.
type scItem struct {
	Check  string `json:"check"`
	Target string `json:"target"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// scRaw is what the Node side observed: how each file loaded, every definition and how many
// definitions match each step text of the feature.
type scRaw struct {
	Loads []struct {
		File  string `json:"file"`
		Error string `json:"error"`
	} `json:"loads"`
	Defs []struct {
		File    string `json:"file"`
		Pattern string `json:"pattern"`
		Body    string `json:"body"`
		Used    bool   `json:"used"`
	} `json:"defs"`
	Steps []struct {
		Text  string `json:"text"`
		Count int    `json:"count"`
	} `json:"steps"`
}

// scScript loads the step files the way the acceptance command does and reports scRaw as the
// last stdout line. The input is {"files":[...],"texts":[...]} on stdin.
const scScript = `
const fs = require('fs'), path = require('path');
const cc = require('@cucumber/cucumber');
const b = cc.supportCodeLibraryBuilder;
const inp = JSON.parse(fs.readFileSync(0, 'utf8'));
let n = 0;
b.reset(process.cwd(), () => String(n++));
const loads = [];
for (const f of inp.files) {
  try { require(path.resolve(f)); loads.push({ file: f, error: '' }); }
  catch (e) {
    const t = String(e && e.name ? e.name + ': ' + e.message : e).replace(/\s+/g, ' ').slice(0, 400);
    loads.push({ file: f, error: t });
  }
}
const lib = b.finalize();
const defs = lib.stepDefinitions.map(d => ({
  file: d.uri, pattern: d.pattern instanceof RegExp ? d.pattern.source : String(d.pattern),
  body: String(d.unwrappedCode), used: inp.texts.some(t => d.matchesStepName(t)),
}));
const steps = inp.texts.map(t => ({ text: t, count: lib.stepDefinitions.filter(d => d.matchesStepName(t)).length }));
process.stdout.write('\nKOGEN_SELFCHECK_RESULT:' + JSON.stringify({ loads, defs, steps }) + '\n');
`

// exitWrapper names the wrapper that changes exit codes (go run, npm run, npx without ` -- `
// passthrough) in a step definition body that also deals with an exit code; empty if none.
func exitWrapper(body string) string {
	if !strings.Contains(body, "status") && !strings.Contains(body, "exit") {
		return ""
	}
	passthrough := strings.Contains(body, " -- ")
	switch {
	case strings.Contains(body, "go run"):
		return "go run"
	case strings.Contains(body, "npm run") && !passthrough:
		return "npm run"
	case strings.Contains(body, "npx") && !passthrough:
		return "npx"
	}
	return ""
}

// scItems is the load, steps, definitions and exit_code items for the Intent's own step files.
// A file that does not load leaves the checks that need its definitions out.
func scItems(own []string, raw scRaw) []scItem {
	var items []scItem
	failed := false
	for _, f := range own {
		msg := ""
		for _, l := range raw.Loads {
			if l.File == f {
				msg = l.Error
			}
		}
		items = append(items, scItem{"load", f, msg == "", msg})
		failed = failed || msg != ""
	}
	if failed {
		return items
	}
	for _, s := range raw.Steps {
		it := scItem{"steps", s.Text, s.Count == 1, ""}
		switch {
		case s.Count == 0:
			it.Detail = "undefined step"
		case s.Count > 1:
			it.Detail = fmt.Sprintf("ambiguous step (%d definitions)", s.Count)
		}
		items = append(items, it)
	}
	for _, d := range raw.Defs {
		if slices.Contains(own, d.File) {
			it := scItem{"definitions", d.Pattern, d.Used, ""}
			if !d.Used {
				it.Detail = "unused definition"
			}
			items = append(items, it)
		}
	}
	for _, f := range own {
		it := scItem{"exit_code", f, true, ""}
		for _, d := range raw.Defs {
			if w := exitWrapper(d.Body); d.File == f && w != "" {
				it.OK = false
				it.Detail = "step definition " + d.Pattern + " asserts an exit code but obtains it through " + w + ", which changes exit codes; build the binary (go build) and run it instead"
				break
			}
		}
		items = append(items, it)
	}
	return items
}

// selfcheckFeedback is the feedback of a failed self-check, nil items ok.
func selfcheckFeedback(items []scItem) string {
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

// ownStepFiles are the Intent's own step files: its Acceptance paths in the steps folder that
// the acceptance command loads (JavaScript); other acceptance files there, such as Go drivers
// mounted with go -overlay, are not step code.
func ownStepFiles(intent *project.Intent) []string {
	var own []string
	for _, p := range intent.StepFiles() {
		if strings.HasPrefix(p, stepsFolder) && filepath.Ext(p) == ".js" {
			own = append(own, p)
		}
	}
	return own
}

// stepSelfcheck runs the self-check on the written candidate and records its one event. It
// returns the feedback text, empty when every item is ok.
func (sh *shaping) stepSelfcheck(ctx context.Context) (string, error) {
	intent, scenarios, err := project.CheckIntent(sh.root, sh.slug, nil)
	if err != nil {
		return "", nil // the package is not readable; readiness reports why
	}
	own := ownStepFiles(intent)
	var texts []string
	for _, sc := range scenarios {
		for _, st := range sc.Steps {
			if !slices.Contains(texts, st.Text) {
				texts = append(texts, st.Text)
			}
		}
	}
	files := slices.Clone(own)
	entries, _ := os.ReadDir(filepath.Join(sh.root, stepsFolder))
	for _, e := range entries {
		p := stepsFolder + e.Name()
		if !e.IsDir() && filepath.Ext(p) == ".js" && !slices.Contains(own, p) {
			files = append(files, p)
		}
	}
	sort.Strings(files[len(own):])

	var items []scItem
	if len(own) > 0 {
		raw, err := sh.runStepScript(ctx, files, texts)
		if err != nil {
			return "", err
		}
		items = scItems(own, raw)
	}
	obs, err := sh.observerItems(ctx, intent)
	if err != nil {
		return "", err
	}
	items = append(items, obs...)

	all, ok := make([]any, 0, len(items)), true
	for _, it := range items {
		all = append(all, map[string]any{"check": it.Check, "target": it.Target, "ok": it.OK, "detail": it.Detail})
		ok = ok && it.OK
	}
	sh.ev.Record(map[string]any{"event": "step_selfcheck", "ok": ok, "items": all})
	return selfcheckFeedback(items), nil
}

func (sh *shaping) runStepScript(ctx context.Context, files, texts []string) (scRaw, error) {
	node, cucumber := sh.rd.Tools.Node, sh.rd.Tools.Cucumber
	if node == "" {
		node = sh.s.Getenv("KOGEN_NODE")
	}
	if cucumber == "" {
		cucumber = sh.s.Getenv("KOGEN_CUCUMBER")
	}
	in, _ := json.Marshal(map[string]any{"files": files, "texts": texts})
	cmd := exec.CommandContext(ctx, node, "-e", scScript)
	cmd.Dir = sh.root
	cmd.Env = append(slices.Clone(sh.s.Env), "NODE_PATH="+cucumber)
	cmd.Stdin = bytes.NewReader(in)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	runErr := cmd.Run()
	var raw scRaw
	for _, line := range strings.Split(out.String(), "\n") {
		if rest, ok := strings.CutPrefix(line, "KOGEN_SELFCHECK_RESULT:"); ok {
			if json.Unmarshal([]byte(rest), &raw) == nil {
				return raw, nil
			}
		}
	}
	if ctx.Err() != nil {
		return raw, ctx.Err()
	}
	// Node itself failed to run the check: every own step file carries that failure.
	text := strings.Join(strings.Fields(errb.String()), " ")
	if text == "" && runErr != nil {
		text = runErr.Error()
	}
	if len(text) > 400 {
		text = text[:400]
	}
	for _, f := range files {
		raw.Loads = append(raw.Loads, struct {
			File  string `json:"file"`
			Error string `json:"error"`
		}{f, text})
	}
	return raw, nil
}

// observerItems re-runs the controls of every declared observer and compares each exit code
// with the recorded one.
func (sh *shaping) observerItems(ctx context.Context, intent *project.Intent) ([]scItem, error) {
	decls, err := verify.Declarations(intent)
	if err != nil {
		return nil, nil // invalid declarations are readiness's to report
	}
	var items []scItem
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
			it := scItem{"observer", d.ID + " " + c.Name, r.Status == c.Exit && !r.TimedOut, ""}
			if !it.OK {
				it.Detail = fmt.Sprintf("exit %d, recorded exit %d", r.Status, c.Exit)
			}
			items = append(items, it)
		}
	}
	return items, nil
}
