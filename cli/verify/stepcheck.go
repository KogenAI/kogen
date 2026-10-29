package verify

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
)

// The step analysis of a candidate package: its step files are loaded with Kogen's own Node
// and Cucumber the way the acceptance command loads them, so Shape's step self-check and
// readiness agree on what is a defect and what is only a warning (K-UNUSEDSTEP-WARN).

// StepsFolder is the folder of the project's step definitions.
const StepsFolder = "features/steps/"

// StepItem is one thing the step analysis looked at. OK is false for a defect that refuses
// the candidate; Warning marks an item that is ok but worth reporting (an unused definition).
// File is the step file of a definition item.
type StepItem struct {
	Check   string `json:"check"`
	Target  string `json:"target"`
	OK      bool   `json:"ok"`
	Detail  string `json:"detail"`
	File    string `json:"file,omitempty"`
	Warning bool   `json:"warning,omitempty"`
}

// StepWarning is an unused step definition of an Intent's own step file: the definition's
// pattern as written, the file that holds it and what is wrong. It never refuses by itself.
type StepWarning struct {
	Pattern string `json:"pattern"`
	File    string `json:"file"`
	Detail  string `json:"detail"`
}

// Line is the warning as one line of output.
func (w StepWarning) Line() string {
	return "warning: step definition " + w.Pattern + " in " + w.File + ": " + w.Detail
}

// UnusedDefinition is the detail of an unused step definition.
const UnusedDefinition = "unused definition"

// StepRaw is what the Node side observed: how each file loaded, every definition and how many
// definitions match each step text of the feature.
type StepRaw struct {
	Loads []StepLoad `json:"loads"`
	Defs  []StepDef  `json:"defs"`
	Steps []StepText `json:"steps"`
}

type StepLoad struct {
	File  string `json:"file"`
	Error string `json:"error"`
}

type StepDef struct {
	File    string `json:"file"`
	Pattern string `json:"pattern"`
	Body    string `json:"body"`
	Used    bool   `json:"used"`
}

type StepText struct {
	Text  string `json:"text"`
	Count int    `json:"count"`
}

// stepScript loads the step files the way the acceptance command does and reports StepRaw as
// the last stdout line. The input is {"files":[...],"texts":[...]} on stdin.
const stepScript = `
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

// ExitWrapper names the wrapper that changes exit codes (go run, npm run, npx without ` -- `
// passthrough) in a step definition body that also deals with an exit code; empty if none.
func ExitWrapper(body string) string {
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

// StepItems is the load, steps, definitions and exit_code items for the Intent's own step
// files. A file that does not load leaves the checks that need its definitions out. An unused
// definition is an ok item that carries a warning.
func StepItems(own []string, raw StepRaw) []StepItem {
	var items []StepItem
	failed := false
	for _, f := range own {
		msg := ""
		for _, l := range raw.Loads {
			if l.File == f {
				msg = l.Error
			}
		}
		items = append(items, StepItem{Check: "load", Target: f, OK: msg == "", Detail: msg})
		failed = failed || msg != ""
	}
	if failed {
		return items
	}
	for _, s := range raw.Steps {
		it := StepItem{Check: "steps", Target: s.Text, OK: s.Count == 1}
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
			it := StepItem{Check: "definitions", Target: d.Pattern, OK: true, File: d.File}
			if !d.Used {
				it.Detail, it.Warning = UnusedDefinition, true
			}
			items = append(items, it)
		}
	}
	for _, f := range own {
		it := StepItem{Check: "exit_code", Target: f, OK: true}
		for _, d := range raw.Defs {
			if w := ExitWrapper(d.Body); d.File == f && w != "" {
				it.OK = false
				it.Detail = "step definition " + d.Pattern + " asserts an exit code but obtains it through " + w + ", which changes exit codes; build the binary (go build) and run it instead"
				break
			}
		}
		items = append(items, it)
	}
	return items
}

// StepWarnings are the warnings among items.
func StepWarnings(items []StepItem) []StepWarning {
	var out []StepWarning
	for _, it := range items {
		if it.Warning {
			out = append(out, StepWarning{Pattern: it.Target, File: it.File, Detail: it.Detail})
		}
	}
	return out
}

// OwnStepFiles are the Intent's own step files: its Acceptance paths in the steps folder that
// the acceptance command loads (JavaScript); other acceptance files there, such as Go drivers
// mounted with go -overlay, are not step code. A step file reused from earlier work is as much
// its own as a new one.
func OwnStepFiles(intent *project.Intent) []string {
	var own []string
	for _, p := range intent.StepFiles() {
		if strings.HasPrefix(p, StepsFolder) && filepath.Ext(p) == ".js" {
			own = append(own, p)
		}
	}
	return own
}

// StepAnalysis is the load order and step texts of an Intent in root: the own files first,
// then the other JavaScript files of the steps folder, and every distinct step text.
func StepAnalysis(root string, intent *project.Intent, scenarios []project.Scenario) (own, files, texts []string) {
	own = OwnStepFiles(intent)
	for _, sc := range scenarios {
		for _, st := range sc.Steps {
			if !slices.Contains(texts, st.Text) {
				texts = append(texts, st.Text)
			}
		}
	}
	files = slices.Clone(own)
	entries, _ := os.ReadDir(filepath.Join(root, StepsFolder))
	for _, e := range entries {
		p := StepsFolder + e.Name()
		if !e.IsDir() && filepath.Ext(p) == ".js" && !slices.Contains(own, p) {
			files = append(files, p)
		}
	}
	sort.Strings(files[len(own):])
	return own, files, texts
}

// RunStepScript loads files in root with node and the Cucumber under cucumber (a NODE_PATH),
// env being the process environment. loaded is false when Node could not run the script at
// all; raw then carries that failure as the load error of every file.
func RunStepScript(ctx context.Context, node, cucumber, root string, env, files, texts []string) (raw StepRaw, loaded bool, err error) {
	in, _ := json.Marshal(map[string]any{"files": files, "texts": texts})
	cmd := exec.CommandContext(ctx, node, "-e", stepScript)
	cmd.Dir = root
	cmd.Env = append(slices.Clone(env), "NODE_PATH="+cucumber)
	cmd.Stdin = bytes.NewReader(in)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	runErr := cmd.Run()
	for _, line := range strings.Split(out.String(), "\n") {
		if rest, ok := strings.CutPrefix(line, "KOGEN_SELFCHECK_RESULT:"); ok {
			if json.Unmarshal([]byte(rest), &raw) == nil {
				return raw, true, nil
			}
		}
	}
	if ctx.Err() != nil {
		return raw, false, ctx.Err()
	}
	// Node itself failed to run the check: every step file carries that failure.
	text := strings.Join(strings.Fields(errb.String()), " ")
	if text == "" && runErr != nil {
		text = runErr.Error()
	}
	if len(text) > 400 {
		text = text[:400]
	}
	for _, f := range files {
		raw.Loads = append(raw.Loads, StepLoad{File: f, Error: text})
	}
	return raw, false, nil
}
