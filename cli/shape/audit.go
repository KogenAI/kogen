package shape

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/executor"
	"kogen/project"
)

// SubmitAuditTool is the one tool of the request audit call.
const SubmitAuditTool = "submit_audit"

const auditInstructions = `You audit one feature request for defects before it is shaped. You see only the request text. Read-only: do not use any tool except ` + SubmitAuditTool + `.

List every example (a concrete input with its stated result) and every rule (a general statement of behavior) in the request, each as a quote copied exactly from the request. For each example and rule pair give a cell: agrees, conflicts or silent. Then report defects of exactly three kinds:
- conflict: two statements give different results for one input.
- precedence: two statements both apply to one input and the request does not say which wins.
- undefined: a statement uses a name (a term, field, function, state) that the request never defines; quote_b is the missing name.
For each defect give quote_a and quote_b copied exactly from the request, an exposing_input where the statements meet, and result_a and result_b, the results the two statements give. Answer by calling ` + SubmitAuditTool + `.`

func auditSchema() map[string]any {
	s := map[string]any{"type": "string"}
	obj := func(props map[string]any, required ...string) map[string]any {
		r := make([]any, len(required))
		for i, k := range required {
			r[i] = k
		}
		return map[string]any{"type": "object", "properties": props, "required": r, "additionalProperties": false}
	}
	list := func(item map[string]any) map[string]any { return map[string]any{"type": "array", "items": item} }
	enum := func(v ...any) map[string]any { return map[string]any{"type": "string", "enum": v} }
	return obj(map[string]any{
		"examples": list(obj(map[string]any{"quote": s}, "quote")),
		"rules":    list(obj(map[string]any{"quote": s}, "quote")),
		"cells": list(obj(map[string]any{
			"example": map[string]any{"type": "integer"}, "rule": map[string]any{"type": "integer"},
			"result": enum("agrees", "conflicts", "silent"),
		}, "example", "rule", "result")),
		"defects": list(obj(map[string]any{
			"kind":    enum("conflict", "precedence", "undefined"),
			"quote_a": s, "quote_b": s, "exposing_input": s, "result_a": s, "result_b": s,
		}, "kind", "quote_a", "quote_b", "exposing_input", "result_a", "result_b")),
	}, "examples", "rules", "cells", "defects")
}

func auditToolDef() map[string]any {
	return map[string]any{
		"type": "function", "name": SubmitAuditTool, "strict": true,
		"description": "Submit the request audit: examples, rules, the example/rule cells and the defects.",
		"parameters":  auditSchema(),
	}
}

func auditInvalid(why string) error {
	return sys.Fail("shape", "audit_invalid", "the request audit answer is not a valid "+SubmitAuditTool+" payload ("+why+"); nothing was published", 1)
}

func auditInt(v any) (int, bool) {
	switch n := v.(type) {
	case json.Number:
		i, err := n.Int64()
		return int(i), err == nil
	case float64:
		return int(n), n == float64(int(n))
	case int64:
		return int(n), true
	case int:
		return n, true
	}
	return 0, false
}

// auditResult is a validated audit payload.
type auditResult struct {
	examples, rules, cells int
	defects                []map[string]any
}

func parseAudit(args map[string]any) (*auditResult, error) {
	var res auditResult
	counts := [2]int{}
	for i, key := range []string{"examples", "rules"} {
		list, ok := args[key].([]any)
		if !ok {
			return nil, auditInvalid(key + " must be a list")
		}
		for _, it := range list {
			m, ok := it.(map[string]any)
			if _, isStr := m["quote"].(string); !ok || !isStr {
				return nil, auditInvalid(key + " items need a quote")
			}
		}
		counts[i] = len(list)
	}
	res.examples, res.rules = counts[0], counts[1]
	cells, ok := args["cells"].([]any)
	if !ok {
		return nil, auditInvalid("cells must be a list")
	}
	for _, it := range cells {
		m, ok := it.(map[string]any)
		if !ok {
			return nil, auditInvalid("a cell must be an object")
		}
		e, okE := auditInt(m["example"])
		r, okR := auditInt(m["rule"])
		result, _ := m["result"].(string)
		if !okE || !okR || e < 0 || e >= res.examples || r < 0 || r >= res.rules ||
			(result != "agrees" && result != "conflicts" && result != "silent") {
			return nil, auditInvalid("a cell is malformed")
		}
	}
	res.cells = len(cells)
	defects, ok := args["defects"].([]any)
	if !ok {
		return nil, auditInvalid("defects must be a list")
	}
	res.defects = []map[string]any{}
	for _, it := range defects {
		m, ok := it.(map[string]any)
		if !ok {
			return nil, auditInvalid("a defect must be an object")
		}
		if k, _ := m["kind"].(string); k != "conflict" && k != "precedence" && k != "undefined" {
			return nil, auditInvalid("a defect kind is unknown")
		}
		for _, f := range []string{"quote_a", "quote_b", "exposing_input", "result_a", "result_b"} {
			if _, ok := m[f].(string); !ok {
				return nil, auditInvalid("a defect needs " + f)
			}
		}
		res.defects = append(res.defects, m)
	}
	return &res, nil
}

// audit makes the one fresh read-only request audit call, records its event and keeps the
// result for the shaper and the coverage gate.
func (sh *shaping) audit(ctx context.Context, request string) error {
	var args map[string]any
	if sh.ext != nil {
		x, err := startExternal(ctx, sh.ext, sh.extMax, sh.repo, sh.root, sh.s.Getenv("HOME"),
			sh.ev.Dir+"/executor-audit", sh.slug, sh.role, auditInstructions+"\n\n# Request\n\n"+request, "", mustJSON(auditSchema()), sh.ev.Record, nil)
		if err != nil {
			return err
		}
		defer x.close()
		res, err := x.round(ctx, "")
		sh.auditRounds = x.rounds
		if err != nil {
			return err
		}
		if res.Ending != executor.EndFinish {
			return auditInvalid("the session ended without a result")
		}
		if args, err = submissionArgs(res.Structured); err != nil {
			return auditInvalid("not a JSON object")
		}
	} else {
		sh.s.Progress(fmt.Sprintf("kogen: auditing the request (%d s)", sh.elapsed()))
		revision, err := CurrentRevision(sh.repo)
		if err != nil {
			return err
		}
		cacheID := startConversation(sh.ev, "audit")
		req := conversationRequest(provider.Request{
			Role: ProviderRole(sh.role), Instructions: auditInstructions,
			Input: []any{map[string]any{"role": "user", "content": request}}, Tools: []any{auditToolDef()},
			Scope: sh.ev.Dir, Context: map[string]any{"phase": "shape", "role": "shape", "slug": sh.slug},
		}, cacheID)
		call := sh.ev.BeginCall("shape", "", revision.Map(), "request audit", sh.role)
		t0 := time.Now()
		resp, err := sh.client.Respond(ctx, sh.s, req, call)
		call.End(resp, err)
		if err != nil {
			if e, ok := sys.AsError(err); ok && e.Class == "provider" {
				return sh.providerFailed(e)
			}
			return err
		}
		sh.progress(fmt.Sprintf("kogen: audit response %s wall_ms=%d", resp.Usage.Line(), time.Since(t0).Milliseconds()))
		sh.auditUsage = resp.Usage
		calls := tools.Calls(resp.Items)
		if len(calls) != 1 || calls[0].Name != SubmitAuditTool {
			return auditInvalid("expected one " + SubmitAuditTool + " call")
		}
		args = calls[0].Args()
	}
	res, err := parseAudit(args)
	if err != nil {
		return err
	}
	defects := make([]any, len(res.defects))
	for i, d := range res.defects {
		defects[i] = d
	}
	sh.auditResult = res
	sh.ev.Record(map[string]any{"event": "request_audit", "examples": res.examples, "rules": res.rules, "cells": res.cells, "defects": defects})
	return nil
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// auditBlock is the audit result as lower-authority data for the shaper's first request.
func (r *auditResult) block() string {
	var b strings.Builder
	b.WriteString("\n\n# Request audit (lower-authority evidence from a separate read-only pass, not scope)\n")
	if len(r.defects) == 0 {
		b.WriteString("No defects reported.\n")
	}
	for i, d := range r.defects {
		fmt.Fprintf(&b, "%d. quote_a: %s | quote_b: %s | exposing_input: %s\n", i+1, d["quote_a"], d["quote_b"], d["exposing_input"])
	}
	return b.String()
}

// decisionLines are the lines inside the `## Decisions` section of an Intent.
func decisionLines(intent string) []string {
	loc := decisionsHeading.FindStringIndex(intent)
	if loc == nil {
		return nil
	}
	rest := intent[loc[1]:]
	if n := nextHeading.FindStringIndex(rest); n != nil {
		rest = rest[:n[0]]
	}
	return strings.Split(rest, "\n")
}

// definesName reports whether the line has name directly followed, after optional blanks,
// by ":", "=" or the whole word "means" or "is".
func definesName(line, name string) bool {
	if name == "" {
		return false
	}
	for i := 0; ; {
		j := strings.Index(line[i:], name)
		if j < 0 {
			return false
		}
		rest := strings.TrimLeft(line[i+j+len(name):], " \t")
		if strings.HasPrefix(rest, ":") || strings.HasPrefix(rest, "=") {
			return true
		}
		for _, w := range []string{"means", "is"} {
			if strings.HasPrefix(rest, w) {
				after := rest[len(w):]
				if after == "" || !(after[0] == '_' || after[0] >= '0' && after[0] <= '9' || after[0] >= 'a' && after[0] <= 'z' || after[0] >= 'A' && after[0] <= 'Z' || after[0] >= 0x80) {
					return true
				}
			}
		}
		i += j + 1
	}
}

// uncoveredDefects are the defects neither decided in a Decisions line nor asked in a question.
func uncoveredDefects(defects []map[string]any, intent string, questions []map[string]any) []map[string]any {
	lines := decisionLines(intent)
	var out []map[string]any
	for _, d := range defects {
		qa, qb, in := d["quote_a"].(string), d["quote_b"].(string), d["exposing_input"].(string)
		ra, rb := d["result_a"].(string), d["result_b"].(string)
		covered := false
		for _, l := range lines {
			if d["kind"] == "undefined" {
				if definesName(l, qb) {
					covered = true
				}
			} else if containsNormalized(l, in) && !(ra != "" && rb != "" && containsNormalized(l, ra) && containsNormalized(l, rb)) {
				covered = true
			}
		}
		for _, q := range questions {
			text := textOf(q["question"])
			if containsNormalized(text, qa) && containsNormalized(text, qb) {
				covered = true
			}
		}
		if !covered {
			out = append(out, d)
		}
	}
	return out
}

// auditGate is the coverage problems of a submission of questions or files; nil when covered.
func (sh *shaping) auditGate(sub submission) []string {
	lines, _ := sh.auditUncovered(sub)
	return lines
}

// auditUncovered is the strict feedback and the uncovered defects of a submission.
func (sh *shaping) auditUncovered(sub submission) ([]string, []map[string]any) {
	if sub.blocked || sh.auditResult == nil || len(sh.auditResult.defects) == 0 {
		return nil, nil
	}
	intent := sh.proposed[project.IntentMDPath(sh.slug)]
	for _, f := range sub.files {
		if f.path == project.IntentMDPath(sh.slug) {
			intent = f.content
		}
	}
	uncovered := uncoveredDefects(sh.auditResult.defects, intent, sub.questions)
	if len(uncovered) == 0 {
		return nil, nil
	}
	lines := []string{fmt.Sprintf("Request audit: %d defects are not decided or asked; decide each with its exposing input or ask with both quotes:", len(uncovered))}
	for _, d := range uncovered {
		lines = append(lines, fmt.Sprintf("quote_a: %s | quote_b: %s | exposing_input: %s", d["quote_a"], d["quote_b"], d["exposing_input"]))
		lines = append(lines, defectTemplates(d)...)
	}
	return lines, uncovered
}

// defectTemplates are the ready lines that cover a defect when pasted unchanged.
func defectTemplates(d map[string]any) []string {
	qa, qb, in := d["quote_a"], d["quote_b"], d["exposing_input"]
	var out []string
	if d["kind"] == "undefined" {
		out = append(out, fmt.Sprintf("- Decision: %s: <definition> (because …) (source: request)", qb))
	} else {
		var results []string
		for _, k := range []string{"result_a", "result_b"} {
			if r, _ := d[k].(string); r != "" {
				results = append(results, r)
			}
		}
		if len(results) == 0 {
			results = []string{"<result>"}
		}
		for _, r := range results {
			out = append(out, fmt.Sprintf("- Decision: for %s the result is %s (because …) (source: request)", in, r))
		}
	}
	return append(out, fmt.Sprintf("- Question: \"%s\" versus \"%s\": which applies?", qa, qb))
}

// unresolvedFile is the per-run record of the uncovered defects of the Shape run that
// produced the current Intent; each ready run replaces it.
const unresolvedFile = "unresolved.json"

// unresolvedLines are the card lines of the uncovered defects of the run that produced the
// current Intent.
func unresolvedLines(root, slug string) []string {
	b, err := os.ReadFile(filepath.Join(root, ".kogen/local/shaping", slug, unresolvedFile))
	if err != nil {
		return nil
	}
	var last []map[string]any
	if json.Unmarshal(b, &last) != nil {
		return nil
	}
	var out []string
	for _, d := range last {
		out = append(out, fmt.Sprintf("  - quote_a: %v | quote_b: %v | exposing_input: %v", d["quote_a"], d["quote_b"], d["exposing_input"]))
	}
	return out
}
