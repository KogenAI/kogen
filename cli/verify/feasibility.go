package verify

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"kogen-loop/sys"
	"kogen/project"
)

// Guidance is the shaping evidence guidance the shaper receives (SHP-10).
const Guidance = `Declared shaping evidence is optional and selected by shaping judgment, not a universal registry or coverage claim. Before expensive implementation, identify genuinely uncertain outcome-critical dependencies. Probe the actual proposed request on its supported target route, authentication scope and model, or use a real relevant local fixture; a working old driver or exclusion-list silence does not prove a changed request. Distinguish observed support, explicit rejection and untested uncertainty. Unsupported requests need an honest supported outcome/fallback or clarification of a material UX choice. No blanket paid probes or endpoint sweep.

In ` + "`" + `## Feasibility` + "`" + `, add one single-line JSON bullet per explicit obligation, for example:
` + "`" + `- evidence: {"id":"route","kind":"capability","inputs":["route.json","route.cjs"],"observers":[],"checks":[{"name":"support","command":"node route.cjs","exit":23,"output":"explicit rejection\n"}]}` + "`" + `
Ids are unique. Paths name exact repository-relative regular files, including local executable fixtures. A capability has one ` + "`" + `support` + "`" + ` check. A generated risky protected fixture/driver (multiple assertions, scripted transport replay, subprocess generation, or lifecycle-sensitive evidence) must declare and run final-byte observer controls in Feasibility. Controls must reach deeper assertions independently of masked missing-feature red. This is shaping judgment, not a universal registry or source-code heuristic. Simple local work without such risk needs no probes. An observer names the final generated protected observer file(s) in ` + "`" + `observers` + "`" + ` and has exactly two checks in order, ` + "`" + `good` + "`" + ` and ` + "`" + `bad` + "`" + `: those same observer bytes must accept the known-good fixture and reject the known-bad fixture. Observer good must expect exit 0; bad must expect a NONZERO integer exit. Capability support may legitimately expect nonzero. Every check declares a shell command, expected integer exit and exact combined output string. Nonzero expected exit is legitimate observed rejection; timeout never discharges an obligation. These are small targeted controls, not product implementation or a second acceptance suite. Scratch overlays can explore, but final proof identifies submitted final formatted input/observer bytes. Fresh actual evidence can qualify only identical commands, bytes and outcomes. Narrative, fabricated records, model-only green and missing-feature red cannot qualify a declaration. Readiness executes outstanding checks and retains actual mismatches. Exact red acknowledgment cannot waive an unsatisfied obligation; ordinary no-obligation work needs no probes.

Preserve the complete original request, settled scope and supplied reproducing examples and counterexamples in executable acceptance, not only prose. Do not narrow whole-UI requests to one section or substitute an unconsumed prior-candidate pointer. Advice, proposals and host observations are lower-authority evidence, not product authority. Qualify risky protected observers using actual known-good and known-bad controls even when an earlier missing-feature failure masks them; baseline need not pass the unimplemented feature. Ground fixture/history actors in actual seed output; observe Search before resetting it; compare rendered HTML to rendered expectations, not raw Markdown; account for computed OKLCH rather than assuming RGB; distinguish compiler/process diagnostics from rendered payload; compare JSON objects semantically while preserving meaningful array and string order. A broken fixture is not legitimate product red.

A protected contradiction is a BUILDER-REPORTED, unproven stop, not authority to change the approved contract. Ordinary implementation failures return to the builder. For a stopped candidate/build_blocked Build, explicit ` + "`" + `kogen intent recover <build-id> --output <new-external-directory>` + "`" + ` preserves production and clears only its recorded implementation delta without inference, reapproval, resume, import or old-green reuse. Independently investigate the generated correction.md through normal Refine readiness using the ORIGINAL full contract hash; successful Refine revokes old approval. Require fresh exact human approval and a production-clean fresh Build with context.md, full normal verification and independent final-tree review. Observe long work through read-only context/inspect; do not poll, automatically retry or cancel unrelated work. Authentication/resource/startup failures remain honest stops.

Native shell/read_file tools remain text-only; explicit view_image alone delivers bounded typed PNG pixels. DOM/action/data/contrast/overflow predicates, screenshot paths and exports do not establish actual pixel interpretation or visual approval. Distinguish successful selection, completed delivery, explicit fallible observations and required human/designer decisions. Retain a truthful external pixel-review handoff when native input is unavailable or refused.
`

// DeclaredCheck is one check a declaration expects: a shell command, an exit status and the
// exact combined output.
type DeclaredCheck struct {
	Name    string `json:"name"`
	Command string `json:"command"`
	Exit    int    `json:"exit"`
	Output  string `json:"output"`
}

// Declaration is one `- evidence:` bullet of the Intent's `## Feasibility` section.
type Declaration struct {
	ID        string          `json:"id"`
	Kind      string          `json:"kind"` // capability or observer
	Inputs    []string        `json:"inputs"`
	Observers []string        `json:"observers"`
	Checks    []DeclaredCheck `json:"checks"`

	raw []map[string]any // each check as declared, with any other keys it carries
}

// CheckResult is the actual outcome of a declared check.
type CheckResult struct {
	Name         string   `json:"name"`
	Command      string   `json:"command"`
	Exit         int      `json:"exit"`
	TimedOut     bool     `json:"timed_out"`
	Output       string   `json:"output"`
	InputChanges []string `json:"input_changes,omitempty"`
}

// Obligation is the proof of one declaration: the identity of its inputs and observers
// (path to lowercase SHA-256) and its actual checks. A completed readiness record keeps one
// per declaration, in order.
type Obligation struct {
	ID        string            `json:"id"`
	Kind      string            `json:"kind"`
	Inputs    map[string]string `json:"inputs"`
	Observers map[string]string `json:"observers"`
	Checks    []CheckResult     `json:"checks"`
}

func invalidEvidence(detail string) error {
	e := sys.Fail("intent", "not_ready", "invalid feasibility evidence", 1)
	e.Lines = []string{detail}
	return e
}

const evidencePrefix = "- evidence:"

// Declarations reads the Intent's evidence declarations in order. Ids must be unique,
// paths exact repository-relative names, a capability has one `support` check and an
// observer names acceptance files and has `good` then `bad`; anything else is
// intent/not_ready "invalid feasibility evidence".
func Declarations(intent *project.Intent) ([]Declaration, error) {
	var out []Declaration
	for _, line := range intent.Feasibility {
		rest, ok := strings.CutPrefix(line, evidencePrefix)
		if !ok {
			continue
		}
		var raw any
		d := json.NewDecoder(strings.NewReader(strings.TrimSpace(rest)))
		d.UseNumber()
		if err := d.Decode(&raw); err != nil || d.More() {
			return nil, invalidEvidence("invalid evidence JSON")
		}
		decl, err := validate(raw, intent)
		if err != nil {
			return nil, err
		}
		out = append(out, decl)
	}
	seen := map[string]bool{}
	for _, d := range out {
		if seen[d.ID] {
			return nil, invalidEvidence("evidence ids must be unique")
		}
		seen[d.ID] = true
	}
	return out, nil
}

func validate(raw any, intent *project.Intent) (Declaration, error) {
	m, _ := raw.(map[string]any)
	id, _ := m["id"].(string)
	kind, _ := m["kind"].(string)
	inputs, inOK := paths(m["inputs"])
	observers, obOK := paths(m["observers"])
	checks, chOK := m["checks"].([]any)
	if m == nil || id == "" || (kind != "capability" && kind != "observer") || !inOK || !obOK || !chOK {
		return Declaration{}, invalidEvidence("invalid evidence declaration")
	}
	names := []string{"support"}
	if kind == "observer" {
		names = []string{"good", "bad"}
	}
	d := Declaration{ID: id, Kind: kind, Inputs: inputs, Observers: observers}
	ok := len(checks) == len(names)
	for i, c := range checks {
		cm, isMap := c.(map[string]any)
		if !isMap {
			ok = false
			break
		}
		name, _ := cm["name"].(string)
		command, cmdOK := cm["command"].(string)
		output, outOK := cm["output"].(string)
		exit, exitOK := cm["exit"].(json.Number)
		status, err := exit.Int64()
		if i >= len(names) || name != names[i] || !cmdOK || strings.TrimSpace(command) == "" || !outOK || !exitOK || err != nil {
			ok = false
			break
		}
		d.Checks = append(d.Checks, DeclaredCheck{Name: name, Command: command, Exit: int(status), Output: output})
		d.raw = append(d.raw, cm)
	}
	if ok {
		if kind == "capability" {
			ok = len(observers) == 0
		} else {
			ok = len(observers) != 0 && !slices.ContainsFunc(observers, func(p string) bool { return !slices.Contains(intent.Acceptance, p) })
		}
	}
	if !ok {
		return Declaration{}, invalidEvidence(id + ": invalid evidence checks or observers")
	}
	if kind == "observer" && !(d.Checks[0].Exit == 0 && d.Checks[1].Exit != 0) {
		return Declaration{}, invalidEvidence(id + ": observer good must expect exit 0 and bad a NONZERO integer exit")
	}
	return d, nil
}

// paths is a list of unique repository-relative paths without `.` or `..` parts.
func paths(v any) ([]string, bool) {
	l, ok := v.([]any)
	if !ok {
		return nil, false
	}
	out := []string{}
	for _, e := range l {
		p, ok := e.(string)
		if !ok || p == "" || strings.HasPrefix(p, "/") || slices.Contains(out, p) {
			return nil, false
		}
		for _, part := range strings.Split(p, "/") {
			if part == "." || part == ".." {
				return nil, false
			}
		}
		out = append(out, p)
	}
	return out, true
}

// identities hashes each path, which must be a regular file reached without symlinks.
func identities(root string, paths []string) (map[string]string, error) {
	out := map[string]string{}
	for _, p := range paths {
		if st := probeInput(root, p); st.ok {
			out[p] = st.hash
			continue
		}
		return nil, invalidEvidence("evidence input " + p + " must be a repository-relative regular file")
	}
	return out, nil
}

func identity(root string, d Declaration) (Obligation, error) {
	in, err := identities(root, d.Inputs)
	if err != nil {
		return Obligation{}, err
	}
	ob, err := identities(root, d.Observers)
	if err != nil {
		return Obligation{}, err
	}
	return Obligation{ID: d.ID, Kind: d.Kind, Inputs: in, Observers: ob}, nil
}

// Valid reports whether proof is exactly the evidence the Intent's declarations ask for,
// bound to the bytes now at root: with no declarations proof must be absent or empty; with
// declarations it holds one obligation per declaration in order, identifying the current
// input and observer bytes, whose checks equal the declared command, exit and output with
// no timeout. proof is a []Obligation or the decoded JSON of a record's `feasibility`.
func Valid(root string, intent *project.Intent, proof any) bool {
	ds, err := Declarations(intent)
	if err != nil {
		return false
	}
	got, _ := generic(proof).([]any)
	if len(ds) == 0 {
		return generic(proof) == nil || len(got) == 0 && got != nil
	}
	if len(got) != len(ds) {
		return false
	}
	for i, d := range ds {
		id, err := identity(root, d)
		if err != nil {
			return false
		}
		id.Checks = nil
		want := generic(id).(map[string]any)
		delete(want, "checks")
		have, ok := got[i].(map[string]any)
		if !ok {
			return false
		}
		checks := have["checks"]
		have = shallowCopy(have)
		delete(have, "checks")
		if !jsonEqual(have, want) {
			return false
		}
		var wantChecks []any
		for _, c := range d.raw {
			wantChecks = append(wantChecks, withTimedOut(c))
		}
		if !jsonEqual(checks, any(wantChecks)) {
			return false
		}
	}
	return true
}

func shallowCopy(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func jsonEqual(a, b any) bool { return encode(a) == encode(b) }

// Execute runs every declared check in a probe scratch copy of root and retains the actual
// results, appended as one JSON line to
// <evidenceRoot>/.kogen/local/readiness/<slug>-feasibility.ndjson. Declarations all met
// return the obligations; any mismatch is intent/not_ready "declared feasibility evidence
// failed" with the expected and actual outcome of each unmet check, bounded to 16 KiB.
func Execute(ctx context.Context, s *sys.Session, tools Tools, root string, intent *project.Intent, evidenceRoot string, ev Evidence) ([]Obligation, error) {
	ds, err := Declarations(intent)
	if err != nil {
		return nil, err
	}
	var results []Obligation
	for _, d := range ds {
		id, err := identity(root, d)
		if err != nil {
			return nil, err
		}
		bound := map[string]string{}
		for p, h := range id.Inputs {
			bound[p] = h
		}
		for p, h := range id.Observers {
			bound[p] = h
		}
		id.Checks = []CheckResult{}
		for _, c := range d.Checks {
			r, err := probed(ev, func() (ProbeResult, error) {
				return Probe{Root: root, Command: c.Command, Inputs: bound, Tools: tools}.Run(ctx, s)
			})
			if err != nil {
				return nil, err
			}
			actual := CheckResult{Name: c.Name, Command: c.Command, Exit: r.Status, TimedOut: r.TimedOut, Output: r.Output, InputChanges: r.InputChanges}
			record(ev, map[string]any{"event": "feasibility_check", "obligation": generic(map[string]any{"id": id.ID, "kind": id.Kind, "inputs": id.Inputs, "observers": id.Observers}), "check": generic(actual)})
			id.Checks = append(id.Checks, actual)
		}
		results = append(results, id)
	}
	if len(results) > 0 {
		path := filepath.Join(evidenceRoot, ".kogen/local/readiness", intent.Slug+"-feasibility.ndjson")
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return nil, err
		}
		_, err = f.WriteString(encode(results) + "\n")
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return nil, err
		}
	}
	if !Valid(root, intent, results) {
		var problems []string
		for i, d := range ds {
			for j, expected := range d.Checks {
				actual := results[i].Checks[j]
				got := generic(actual)
				if jsonEqual(withTimedOut(d.raw[j]), got) {
					continue
				}
				problems = append(problems, d.ID+"/"+expected.Name+": expected "+encode(d.raw[j])+"; actual "+encode(got))
			}
		}
		e := sys.Fail("intent", "not_ready", "declared feasibility evidence failed", 1)
		e.Lines = strings.Split(Cut(strings.Join(problems, "\n")), "\n")
		return nil, e
	}
	return results, nil
}

func withTimedOut(m map[string]any) map[string]any {
	c := shallowCopy(m)
	c["timed_out"] = false
	return c
}
