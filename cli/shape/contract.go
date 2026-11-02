package shape

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/executor"
	"kogen/project"
)

// The contract check (SHP-8): every new candidate that readiness accounted for goes to an
// independent read-only review that looks for acceptance expectations contradicting the Intent
// or the code it keeps unchanged, and to a confirmation of the findings Kogen found evidence for.
// Kogen alone decides which findings are evidenced; only confirmed ones refuse the candidate.

// SubmitContractReviewTool and SubmitContractConfirmationTool are the submit tools of the two
// calls of the contract check.
const (
	SubmitContractReviewTool       = "submit_contract_review"
	SubmitContractConfirmationTool = "submit_contract_confirmation"
)

const (
	contractGate         = "contract_review"
	contractRequestBound = 8  // model requests per conversation
	contractToolBound    = 32 // read-only tool calls per conversation

	// contractContradictionsFile is the record of the contradictions a not-ready Shape left, in
	// the shaping directory.
	contractContradictionsFile = "contract-contradictions.json"
)

var contractReviewInstructions = strings.Join([]string{
	"You check one candidate Intent before any Build is spent on it. Find acceptance expectations that no correct implementation of the Intent can pass.",
	"Read-only: use only read_file, list_files and search_text, then call " + SubmitContractReviewTool + " once.",
	"An expectation is an assertion, an expected value or output, or a call with its arguments, in the candidate acceptance.feature or in a step file the Intent lists under Acceptance. Report a finding only when the expectation contradicts the candidate intent.md (a rule, table, example or boundary it states) or the behaviour of repository code or text that the candidate does not change and the Intent keeps unchanged (for example an output envelope, a required argument, or a file another command writes).",
	"The readiness observations show how the unchanged tree behaved and which steps never ran. A scenario that fails only because the requested feature is missing is not a finding. Do not report style, coverage, weak tests, preferences or anything a correct implementation could satisfy.",
	"When unsure, report nothing.",
	`For each finding give scenario (the scenario name exactly as in acceptance.feature), expectation (its path and the exact text copied from that file), contract (the path of intent.md or of the unchanged repository file, and the exact text copied from it that the expectation contradicts) and why (what a correct implementation does instead). Answer {"findings":[]} when there is none.`,
}, "\n")

var contractConfirmationInstructions = strings.Join([]string{
	"You independently verify reported contradictions in one candidate Intent before any Build is spent on it.",
	"Read-only: use only read_file, list_files and search_text, then call " + SubmitContractConfirmationTool + " once.",
	"For each numbered finding, inspect the cited expectation and contract yourself. Answer confirmed only when a correct implementation of the Intent cannot pass the expectation because of the cited contract; otherwise answer refuted. Give one verdict per finding with its number and a short why.",
}, "\n")

// contractReadOnly are the inspection tools of both calls.
func contractReadOnly() []string {
	return []string{tools.ReadFileTool, tools.ListFilesTool, tools.SearchTextTool}
}

func contractQuoteSchema() map[string]any {
	s := map[string]any{"type": "string"}
	return map[string]any{
		"type":                 "object",
		"properties":           map[string]any{"path": s, "quote": s},
		"required":             []any{"path", "quote"},
		"additionalProperties": false,
	}
}

func contractReviewSchema() map[string]any {
	s := map[string]any{"type": "string"}
	item := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"scenario": s, "expectation": contractQuoteSchema(), "contract": contractQuoteSchema(), "why": s,
		},
		"required":             []any{"scenario", "expectation", "contract", "why"},
		"additionalProperties": false,
	}
	return map[string]any{
		"type":                 "object",
		"properties":           map[string]any{"findings": map[string]any{"type": "array", "items": item}},
		"required":             []any{"findings"},
		"additionalProperties": false,
	}
}

func contractConfirmationSchema() map[string]any {
	item := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"finding": map[string]any{"type": "integer"},
			"verdict": map[string]any{"type": "string", "enum": []any{"confirmed", "refuted"}},
			"why":     map[string]any{"type": "string"},
		},
		"required":             []any{"finding", "verdict", "why"},
		"additionalProperties": false,
	}
	return map[string]any{
		"type":                 "object",
		"properties":           map[string]any{"verdicts": map[string]any{"type": "array", "items": item}},
		"required":             []any{"verdicts"},
		"additionalProperties": false,
	}
}

func contractToolDef(name, description string, schema map[string]any) map[string]any {
	return map[string]any{"type": "function", "name": name, "strict": true, "description": description, "parameters": schema}
}

func contractReviewToolDef() map[string]any {
	return contractToolDef(SubmitContractReviewTool, "Submit the contract review: the acceptance expectations that contradict the Intent or the code it keeps unchanged, each with quotes.", contractReviewSchema())
}

func contractConfirmationToolDef() map[string]any {
	return contractToolDef(SubmitContractConfirmationTool, "Submit the confirmation: one verdict per numbered finding.", contractConfirmationSchema())
}

// ---- payloads ----

type contractQuote struct{ path, quote string }

type contractFinding struct {
	scenario    string
	expectation contractQuote
	contract    contractQuote
	why         string
}

type contractVerdict struct {
	finding int
	verdict string
	why     string
}

func exactKeys(m map[string]any, keys ...string) bool {
	if len(m) != len(keys) {
		return false
	}
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			return false
		}
	}
	return true
}

func parseContractQuote(v any) (contractQuote, bool) {
	m, ok := v.(map[string]any)
	if !ok || !exactKeys(m, "path", "quote") {
		return contractQuote{}, false
	}
	p, ok1 := m["path"].(string)
	q, ok2 := m["quote"].(string)
	return contractQuote{p, q}, ok1 && ok2
}

// parseContractReview is the findings of exactly one valid submit_contract_review payload, or
// why it is not one.
func parseContractReview(args map[string]any) ([]contractFinding, string) {
	if !exactKeys(args, "findings") {
		return nil, `the payload must have exactly the field "findings"`
	}
	list, ok := args["findings"].([]any)
	if !ok {
		return nil, "findings must be a list"
	}
	out := make([]contractFinding, 0, len(list))
	for _, raw := range list {
		m, ok := raw.(map[string]any)
		if !ok || !exactKeys(m, "scenario", "expectation", "contract", "why") {
			return nil, "a finding must be an object with exactly the fields scenario, expectation, contract, why"
		}
		var f contractFinding
		var ok1, ok2, ok3, ok4 bool
		f.scenario, ok1 = m["scenario"].(string)
		f.why, ok2 = m["why"].(string)
		f.expectation, ok3 = parseContractQuote(m["expectation"])
		f.contract, ok4 = parseContractQuote(m["contract"])
		if !ok1 || !ok2 || !ok3 || !ok4 {
			return nil, "a finding has a field of the wrong type"
		}
		out = append(out, f)
	}
	return out, ""
}

// integerArg is a JSON integer as the argument decoders deliver it.
func integerArg(v any) (int, bool) {
	switch x := v.(type) {
	case json.Number:
		n, err := x.Int64()
		return int(n), err == nil
	case int64:
		return int(x), int64(int(x)) == x
	case float64:
		return int(x), x == float64(int(x))
	case int:
		return x, true
	}
	return 0, false
}

// parseContractConfirmation is the verdicts of exactly one valid submit_contract_confirmation
// payload, or why it is not one.
func parseContractConfirmation(args map[string]any) ([]contractVerdict, string) {
	if !exactKeys(args, "verdicts") {
		return nil, `the payload must have exactly the field "verdicts"`
	}
	list, ok := args["verdicts"].([]any)
	if !ok {
		return nil, "verdicts must be a list"
	}
	out := make([]contractVerdict, 0, len(list))
	for _, raw := range list {
		m, ok := raw.(map[string]any)
		if !ok || !exactKeys(m, "finding", "verdict", "why") {
			return nil, "a verdict must be an object with exactly the fields finding, verdict, why"
		}
		n, ok1 := integerArg(m["finding"])
		verdict, ok2 := m["verdict"].(string)
		why, ok3 := m["why"].(string)
		if !ok1 || !ok2 || !ok3 || (verdict != "confirmed" && verdict != "refuted") {
			return nil, "a verdict has a field of the wrong type or value"
		}
		out = append(out, contractVerdict{n, verdict, why})
	}
	return out, ""
}

// ---- the mechanical rules ----

// contractEvidence is what Kogen compares a finding with: the candidate's scenario names, the
// files an expectation may cite (as written on disk) and the files a contract may cite.
type contractEvidence struct {
	scenarios    []string          // the declared scenario and outline names, normalized
	expectations map[string]string // path to the content on disk: acceptance.feature and the listed step files
	intentPath   string
	intent       string
	// tracked is the HEAD content of a file tracked at HEAD that is not a file of the candidate
	// package; false for any other path.
	tracked func(path string) (string, bool)
}

func (e contractEvidence) evidenced(f contractFinding) bool {
	if strings.TrimSpace(f.why) == "" || !slices.Contains(e.scenarios, normalizeWhitespace(f.scenario)) {
		return false
	}
	text, ok := e.expectations[f.expectation.path]
	if !ok || normalizeWhitespace(f.expectation.quote) == "" || !containsNormalized(text, f.expectation.quote) {
		return false
	}
	if normalizeWhitespace(f.contract.quote) == "" {
		return false
	}
	if f.contract.path == e.intentPath {
		return containsNormalized(e.intent, f.contract.quote)
	}
	head, ok := e.tracked(f.contract.path)
	return ok && containsNormalized(head, f.contract.quote)
}

// contractItem is one finding with what Kogen decided about it.
type contractItem struct {
	finding      contractFinding
	evidenced    bool
	verdict      string  // "", confirmed or refuted
	confirmation *string // the counted verdict's why
}

// contractFindingLine is the confirmation input's line for finding n (from 1), values normalized.
func contractFindingLine(n int, f contractFinding) string {
	return fmt.Sprintf("%d. scenario: %s | %s", n, normalizeWhitespace(f.scenario), contractBody(f))
}

func contractBody(f contractFinding) string {
	nw := normalizeWhitespace
	return fmt.Sprintf("expectation: %s: %s | contract: %s: %s | why: %s",
		nw(f.expectation.path), nw(f.expectation.quote), nw(f.contract.path), nw(f.contract.quote), nw(f.why))
}

// contractItemLine is the feedback line of a confirmed finding.
func contractItemLine(f contractFinding, confirmation string) string {
	return fmt.Sprintf("- %s | %s | confirmed: %s", normalizeWhitespace(f.scenario), contractBody(f), normalizeWhitespace(confirmation))
}

// contractHeadline is the first line of the refusal of n confirmed findings.
func contractHeadline(n int) string {
	return fmt.Sprintf("Contract check: %d acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. "+
		"Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. "+
		"Resubmitting this candidate unchanged is refused again.", n)
}

// contractFeedback is the refusal text: the headline and one line per confirmed finding.
func contractFeedback(lines []string) string {
	return strings.Join(append([]string{contractHeadline(len(lines))}, lines...), "\n")
}

// applyVerdicts gives each evidenced item its counted verdict: the first verdict for n, n from
// 1 to the number of findings sent. A finding without a counted verdict is refuted. It returns
// the item lines of the confirmed findings.
func applyVerdicts(items []contractItem, verdicts []contractVerdict) []string {
	sent := 0
	for _, it := range items {
		if it.evidenced {
			sent++
		}
	}
	counted := map[int]contractVerdict{}
	for _, v := range verdicts {
		if _, seen := counted[v.finding]; !seen && v.finding >= 1 && v.finding <= sent {
			counted[v.finding] = v
		}
	}
	var lines []string
	n := 0
	for i := range items {
		it := &items[i]
		if !it.evidenced {
			continue
		}
		n++
		v, ok := counted[n]
		if !ok {
			it.verdict = "refuted"
			continue
		}
		it.verdict = v.verdict
		why := v.why
		it.confirmation = &why
		if v.verdict == "confirmed" {
			lines = append(lines, contractItemLine(it.finding, v.why))
		}
	}
	return lines
}

// contractEvent is the contract_review event of a review that ran.
func contractEvent(hash, result, reason string, findings, evidenced, confirmed int, items []contractItem) map[string]any {
	list := make([]any, len(items))
	quote := func(q contractQuote) map[string]any { return map[string]any{"path": q.path, "quote": q.quote} }
	for i, it := range items {
		var verdict, confirmation any
		if it.verdict != "" {
			verdict = it.verdict
		}
		if it.confirmation != nil {
			confirmation = *it.confirmation
		}
		list[i] = map[string]any{
			"scenario": it.finding.scenario, "expectation": quote(it.finding.expectation), "contract": quote(it.finding.contract),
			"why": it.finding.why, "evidenced": it.evidenced, "verdict": verdict, "confirmation": confirmation,
		}
	}
	event := map[string]any{"event": "contract_review", "package": hash, "result": result,
		"findings": findings, "evidenced": evidenced, "confirmed": confirmed, "items": list}
	if reason != "" {
		event["reason"] = reason
	}
	return event
}

// contractReviewInput is the user message of the review: the slug and the sections, each
// content without its trailing newlines.
func contractReviewInput(slug string, sections [][2]string) string {
	var b strings.Builder
	b.WriteString("Slug: " + slug)
	for _, s := range sections {
		b.WriteString("\n\n# " + s[0] + "\n\n" + strings.TrimRight(s[1], "\n"))
	}
	return b.String()
}

// ---- the check ----

// packageHash is the hash `kogen intent approve` shows for the files on disk.
func (sh *shaping) packageHash() (string, error) {
	baseline, err := project.Baseline(sh.root, sh.slug, sh.cfg)
	if err != nil {
		return "", err
	}
	return project.Hash(sh.root, baseline), nil
}

// contractRefusal is the refusal of a candidate already refused by the contract check in this
// run, with the same feedback text; false for any other candidate.
func (sh *shaping) contractRefusal(hash string) (string, outcome, bool) {
	lines, ok := sh.contractRefused[hash]
	if !ok {
		return "", outcome{}, false
	}
	sh.contractLines = lines
	sh.refused(contractGate, lines)
	return contractFeedback(lines), outcome{kind: outInvalid, problems: lines}, true
}

// contractCheck gives the candidate on disk to the review and, for the findings Kogen found
// evidence for, to the confirmation. It returns the item lines of the confirmed findings, nil
// when the candidate may go on.
func (sh *shaping) contractCheck(ctx context.Context, hash, observations string) ([]string, error) {
	intentBytes, err := os.ReadFile(filepath.Join(sh.root, project.IntentMDPath(sh.slug)))
	if err != nil {
		return nil, err
	}
	featureBytes, err := os.ReadFile(filepath.Join(sh.root, project.FeaturePath(sh.slug)))
	if err != nil {
		return nil, err
	}
	intent, err := project.ReadIntent(sh.root, sh.slug, nil)
	if err != nil {
		return nil, err
	}
	scenarios, err := project.ParseGherkin(string(featureBytes))
	if err != nil {
		return nil, err
	}
	feature := project.FeaturePath(sh.slug)
	sections := [][2]string{{"Candidate intent.md", string(intentBytes)}, {"Candidate acceptance.feature", string(featureBytes)}}
	ev := contractEvidence{
		expectations: map[string]string{feature: string(featureBytes)},
		intentPath:   project.IntentMDPath(sh.slug), intent: string(intentBytes),
	}
	for _, p := range intent.StepFiles() {
		text, err := os.ReadFile(filepath.Join(sh.root, p))
		if err != nil {
			continue
		}
		ev.expectations[p] = string(text)
		if _, proposed := sh.proposed[p]; proposed {
			sections = append(sections, [2]string{"Candidate step file " + p, string(text)})
		}
	}
	for _, sc := range scenarios {
		ev.scenarios = append(ev.scenarios, normalizeWhitespace(sc.Name))
		if sc.Outline != nil {
			ev.scenarios = append(ev.scenarios, normalizeWhitespace(sc.Outline.Name))
		}
	}
	ev.tracked = func(path string) (string, bool) {
		if !normalPath(path) || path == ev.intentPath || path == feature || path == project.ModelPath(sh.slug) {
			return "", false
		}
		if _, proposed := sh.proposed[path]; proposed {
			return "", false
		}
		if kind, err := sh.repo.OK("cat-file", "-t", "HEAD:"+path); err != nil || strings.TrimSpace(kind) != "blob" {
			return "", false
		}
		return sh.repo.Show("HEAD", path)
	}
	if observations == "" {
		observations = "All scenarios pass now."
	}
	reviewInput := contractReviewInput(sh.slug, append(sections, [2]string{"Readiness observations", observations}))

	incomplete := func(reason string, findings, evidenced int, items []contractItem) ([]string, error) {
		sh.progress("kogen: contract check incomplete (" + reason + "); the candidate goes on")
		sh.ev.Record(contractEvent(hash, "incomplete", reason, findings, evidenced, 0, items))
		return nil, nil
	}

	args, why, err := sh.contractCall(ctx, "review", reviewInput)
	if err != nil {
		return nil, err
	}
	var findings []contractFinding
	if why == "" {
		if findings, why = parseContractReview(args); why != "" {
			why = "invalid " + SubmitContractReviewTool + " payload: " + why
		}
	}
	if why != "" {
		return incomplete(why, 0, 0, nil)
	}
	items := make([]contractItem, len(findings))
	var evidenced []string
	for i, f := range findings {
		items[i] = contractItem{finding: f, evidenced: ev.evidenced(f)}
		if items[i].evidenced {
			evidenced = append(evidenced, contractFindingLine(len(evidenced)+1, f))
		}
	}
	if len(evidenced) == 0 {
		sh.ev.Record(contractEvent(hash, "clean", "", len(findings), 0, 0, items))
		return nil, nil
	}
	args, why, err = sh.contractCall(ctx, "confirmation", reviewInput+"\n\n# Findings to verify\n\n"+strings.Join(evidenced, "\n"))
	if err != nil {
		return nil, err
	}
	var verdicts []contractVerdict
	if why == "" {
		if verdicts, why = parseContractConfirmation(args); why != "" {
			why = "invalid " + SubmitContractConfirmationTool + " payload: " + why
		}
	}
	if why != "" {
		return incomplete(why, len(findings), len(evidenced), items)
	}
	lines := applyVerdicts(items, verdicts)
	result := "clean"
	if len(lines) > 0 {
		result = "refused"
	}
	sh.ev.Record(contractEvent(hash, result, "", len(findings), len(evidenced), len(lines), items))
	return lines, nil
}

// contractCall makes the review ("review") or the confirmation ("confirmation"): one fresh
// read-only conversation or session. It returns the arguments of the submit call, or why the
// call ended incomplete.
func (sh *shaping) contractCall(ctx context.Context, kind, input string) (map[string]any, string, error) {
	instructions, submit, schema, def, doing := contractReviewInstructions, SubmitContractReviewTool, contractReviewSchema(), contractReviewToolDef(), "kogen: checking the contract"
	if kind == "confirmation" {
		instructions, submit, schema, def, doing = contractConfirmationInstructions, SubmitContractConfirmationTool, contractConfirmationSchema(), contractConfirmationToolDef(), "kogen: confirming contract findings"
	}
	if sh.ext != nil {
		return sh.contractExternal(ctx, kind, instructions+"\n\n"+input, schema)
	}
	sh.progress(doing)
	revision, err := CurrentRevision(sh.repo)
	if err != nil {
		return nil, "", err
	}
	defs := append(agent.AsAny(agent.Defs(contractReadOnly()...)), def)
	cacheID := startConversation(sh.ev, "contract-"+kind)
	tl := sh.agentTools(ctx, contractReadOnly())
	conversation := []any{map[string]any{"role": "user", "content": input}}
	used := 0
	for requests := 0; requests < contractRequestBound; requests++ {
		req := conversationRequest(provider.Request{
			Role: ProviderRole(sh.role), Instructions: instructions, Input: conversation, Tools: defs,
			Scope: sh.ev.Dir, Context: map[string]any{"phase": "shape", "role": "shape", "slug": sh.slug},
		}, cacheID)
		if m, err := tools.Measure(sh.client.Body(req), req.Role); err != nil {
			return nil, "", err
		} else if !m.Fits {
			return nil, fmt.Sprintf("a request of %d bytes is above the %d-byte ceiling", m.RenderedBytes, provider.InputBudgetBytes), nil
		}
		call := sh.ev.BeginCall("shape", "", revision.Map(), "contract "+kind, sh.role).Sized(sh.client, req)
		t0 := time.Now()
		resp, err := sh.client.Respond(ctx, sh.s, req, call)
		call.End(resp, err)
		if err != nil {
			if e, ok := sys.AsError(err); ok && e.Class == "provider" {
				return nil, "", sh.providerFailed(e)
			}
			return nil, "", err
		}
		sh.progress(fmt.Sprintf("kogen: contract %s response %s wall_ms=%d", kind, resp.Usage.Line(), time.Since(t0).Milliseconds()))
		sh.contractUsage = sh.contractUsage.Add(resp.Usage)
		calls := tools.Calls(resp.Items)
		if len(calls) == 0 {
			return nil, "the answer called no tool", nil
		}
		if slices.ContainsFunc(calls, func(c tools.Call) bool { return c.Name == submit }) {
			if len(calls) != 1 {
				return nil, "the answer called other tools besides " + submit, nil
			}
			return calls[0].Args(), "", nil
		}
		conversation = append(conversation, tools.Replay(resp.Items)...)
		for _, c := range calls {
			if used >= contractToolBound {
				return nil, fmt.Sprintf("the %d read-only tool call bound was reached", contractToolBound), nil
			}
			if err := interrupted(ctx, sh.s); err != nil {
				return nil, "", err
			}
			out, err := tl.Run(c.Name, c.Args())
			if err != nil {
				return nil, "", err
			}
			used++
			conversation = append(conversation, toolOutput(c, out))
		}
	}
	return nil, fmt.Sprintf("the %d request bound was reached", contractRequestBound), nil
}

// contractExternal is one fresh read-only external session that answers the call with its
// structured result.
func (sh *shaping) contractExternal(ctx context.Context, kind, task string, schema map[string]any) (map[string]any, string, error) {
	folder := "executor-contract-review"
	if kind == "confirmation" {
		folder = "executor-contract-confirm"
	}
	sh.contractSessions[kind]++
	x, err := startExternal(ctx, sh.ext, sh.extMax, sh.repo, sh.root, sh.s.Getenv("HOME"),
		fmt.Sprintf("%s/%s-%d", sh.ev.Dir, folder, sh.contractSessions[kind]), sh.slug, sh.role, task, "", mustJSON(schema), sh.ev.Record, nil)
	if err != nil {
		return nil, "", err
	}
	defer x.close()
	res, err := x.round(ctx, "")
	sh.contractRounds += x.rounds
	if e, ok := sys.AsError(err); ok && e.Class == "executor" && e.Reason == executor.ReasonProtocol {
		return nil, "the session ended without a result", nil
	}
	if err != nil {
		return nil, "", err
	}
	if res.Ending != executor.EndFinish {
		return nil, "the session ended without a result", nil
	}
	args, err := submissionArgs(res.Structured)
	if err != nil {
		return nil, "the result is not a JSON object", nil
	}
	return args, "", nil
}

// ---- the record approval reads ----

type contractContradictions struct {
	SHA256 string   `json:"sha256"`
	Lines  []string `json:"lines"`
}

// writeContractContradictions records the item lines against the hash of the package left on
// disk, the hash `kogen intent approve` shows.
func (sh *shaping) writeContractContradictions(lines []string) error {
	hash, err := sh.packageHash()
	if err != nil {
		return err
	}
	b, err := json.Marshal(contractContradictions{SHA256: hash, Lines: lines})
	if err != nil {
		return err
	}
	path := filepath.Join(sh.stateDir, contractContradictionsFile)
	if err := os.WriteFile(path, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

// approveContractContradictions refuses a package whose current hash is the one Shape left
// contradicting. A record that does not parse or names another hash does not affect approval.
func approveContractContradictions(root, slug, sha string) error {
	b, err := os.ReadFile(filepath.Join(root, ".kogen/local/shaping", slug, contractContradictionsFile))
	if err != nil {
		return nil
	}
	var rec contractContradictions
	if json.Unmarshal(b, &rec) != nil || rec.SHA256 != sha {
		return nil
	}
	e := sys.Fail("intent", "contract_contradicts", "Shape's contract check found acceptance expectations that contradict the Intent or code it keeps unchanged; correct the Intent's files, or shape it again with kogen intent shape "+slug+" <request-file>", 1)
	e.Lines = rec.Lines
	return e
}
