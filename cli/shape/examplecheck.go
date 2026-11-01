package shape

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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

// SubmitExampleCheckTool is the one tool of the example check call.
const SubmitExampleCheckTool = "submit_example_check"

const exampleInstructions = `You check the acceptance examples of one candidate Intent against the rules the Intent states. You see only the request text, the candidate intent.md and the candidate acceptance.feature. Read-only: do not use any tool except ` + SubmitExampleCheckTool + `.

Give one item for every scenario and every Examples row that states a concrete expected result for a concrete input. For each item give:
- scenario: the scenario name, copied exactly from acceptance.feature;
- input: the concrete input, copied exactly from acceptance.feature;
- expected: the expected result, copied exactly from acceptance.feature;
- rule: the rule that determines the expected value, copied exactly from intent.md or the request;
- derived: the value that rule gives for that input, computed by you step by step and written in the same form as expected;
- why: the computation.
Judge only the stated inputs, expected values and rules, never step code.
Answer by calling ` + SubmitExampleCheckTool + `.`

// exampleFields are the six text fields of an item, in order.
var exampleFields = []string{"scenario", "input", "expected", "rule", "derived", "why"}

func exampleSchema() map[string]any {
	props := map[string]any{}
	required := make([]any, len(exampleFields))
	for i, f := range exampleFields {
		props[f] = map[string]any{"type": "string"}
		required[i] = f
	}
	item := map[string]any{"type": "object", "properties": props, "required": required, "additionalProperties": false}
	return map[string]any{
		"type":                 "object",
		"properties":           map[string]any{"examples": map[string]any{"type": "array", "items": item}},
		"required":             []any{"examples"},
		"additionalProperties": false,
	}
}

func exampleToolDef() map[string]any {
	return map[string]any{
		"type": "function", "name": SubmitExampleCheckTool, "strict": true,
		"description": "Submit the example check: one item per acceptance example with its quotes, derived value and computation.",
		"parameters":  exampleSchema(),
	}
}

func exampleInvalid(why string) error {
	return sys.Fail("shape", "example_check_invalid", "the example check answer is not a valid "+SubmitExampleCheckTool+" payload ("+why+"); nothing was published", 1)
}

// exampleItem is one example of the check with the result Kogen decided.
type exampleItem struct {
	scenario, input, expected, rule, derived, why string
	result                                        string
}

func parseExampleCheck(args map[string]any) ([]exampleItem, error) {
	if len(args) != 1 {
		return nil, exampleInvalid(`the payload must have exactly the field "examples"`)
	}
	list, ok := args["examples"].([]any)
	if !ok {
		return nil, exampleInvalid("examples must be a list")
	}
	items := make([]exampleItem, 0, len(list))
	for _, raw := range list {
		m, ok := raw.(map[string]any)
		if !ok || len(m) != len(exampleFields) {
			return nil, exampleInvalid("an item must be an object with exactly the fields " + strings.Join(exampleFields, ", "))
		}
		var v [6]string
		for i, f := range exampleFields {
			s, ok := m[f].(string)
			if !ok {
				return nil, exampleInvalid("the field " + f + " of an item must be a string")
			}
			v[i] = s
		}
		items = append(items, exampleItem{scenario: v[0], input: v[1], expected: v[2], rule: v[3], derived: v[4], why: v[5]})
	}
	return items, nil
}

// exampleOutcome applies the mechanical rule: each item's result, the event, and the feedback
// lines (the headline, then one line per contradicting item; nil when none contradicts).
func exampleOutcome(items []exampleItem, request, intent, feature string) (map[string]any, []string) {
	nReq, nIntent, nFeature := normalizeWhitespace(request), normalizeWhitespace(intent), normalizeWhitespace(feature)
	quoted := func(text, haystack string) bool {
		n := normalizeWhitespace(text)
		return n != "" && strings.Contains(haystack, n)
	}
	counts := map[string]int{}
	events := make([]any, len(items))
	var lines []string
	for i := range items {
		it := &items[i]
		switch {
		case !quoted(it.scenario, nFeature) || !quoted(it.input, nFeature) || !quoted(it.expected, nFeature) ||
			!(quoted(it.rule, nIntent) || quoted(it.rule, nReq)):
			it.result = "unquoted"
		case normalizeWhitespace(it.derived) != normalizeWhitespace(it.expected):
			it.result = "contradicts"
			lines = append(lines, fmt.Sprintf("- scenario: %s | input: %s | expected: %s | rule: %s | derived: %s | why: %s",
				it.scenario, it.input, it.expected, it.rule, it.derived, it.why))
		default:
			it.result = "follows"
		}
		counts[it.result]++
		events[i] = map[string]any{"scenario": it.scenario, "input": it.input, "expected": it.expected, "rule": it.rule,
			"derived": it.derived, "why": it.why, "result": it.result}
	}
	event := map[string]any{"event": "example_check", "follows": counts["follows"], "contradicts": counts["contradicts"], "unquoted": counts["unquoted"], "items": events}
	if len(lines) == 0 {
		return event, nil
	}
	head := fmt.Sprintf("Example check: %d acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.", len(lines))
	return event, append([]string{head}, lines...)
}

// exampleCheck makes one fresh read-only call on the request and the candidate intent.md and
// acceptance.feature and returns the feedback lines, nil when the candidate may go on. A
// candidate already checked without a contradiction in this run is not checked again.
func (sh *shaping) exampleCheck(ctx context.Context) ([]string, error) {
	intent, err := os.ReadFile(filepath.Join(sh.root, project.IntentMDPath(sh.slug)))
	if err != nil {
		return nil, err
	}
	feature, err := os.ReadFile(filepath.Join(sh.root, project.FeaturePath(sh.slug)))
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(append(append(append([]byte{}, intent...), 0), feature...))
	key := hex.EncodeToString(sum[:])
	if sh.exampleChecked[key] {
		return nil, nil
	}
	input := "Slug: " + sh.slug + "\n\n# Request\n\n" + sh.request + "\n\n# Candidate intent.md\n\n" + string(intent) +
		"\n\n# Candidate acceptance.feature\n\n" + string(feature)
	var args map[string]any
	sh.exampleChecks++
	if sh.ext != nil {
		x, err := startExternal(ctx, sh.ext, sh.extMax, sh.repo, sh.root, sh.s.Getenv("HOME"),
			fmt.Sprintf("%s/executor-example-%d", sh.ev.Dir, sh.exampleChecks), sh.slug, sh.role, exampleInstructions+"\n\n"+input, "", mustJSON(exampleSchema()), sh.ev.Record, nil)
		if err != nil {
			return nil, err
		}
		defer x.close()
		res, err := x.round(ctx, "")
		sh.exampleRounds += x.rounds
		if err != nil {
			return nil, err
		}
		if res.Ending != executor.EndFinish {
			return nil, exampleInvalid("the session ended without a result")
		}
		if args, err = submissionArgs(res.Structured); err != nil {
			return nil, exampleInvalid("not a JSON object")
		}
	} else {
		sh.progress("kogen: checking the acceptance examples")
		revision, err := CurrentRevision(sh.repo)
		if err != nil {
			return nil, err
		}
		cacheID := startConversation(sh.ev, "example-check")
		req := conversationRequest(provider.Request{
			Role: ProviderRole(sh.role), Instructions: exampleInstructions,
			Input: []any{map[string]any{"role": "user", "content": input}}, Tools: []any{exampleToolDef()},
			Scope: sh.ev.Dir, Context: map[string]any{"phase": "shape", "role": "shape", "slug": sh.slug},
		}, cacheID)
		call := sh.ev.BeginCall("shape", "", revision.Map(), "example check", sh.role).Sized(sh.client, req)
		t0 := time.Now()
		resp, err := sh.client.Respond(ctx, sh.s, req, call)
		call.End(resp, err)
		if err != nil {
			if e, ok := sys.AsError(err); ok && e.Class == "provider" {
				return nil, sh.providerFailed(e)
			}
			return nil, err
		}
		sh.progress(fmt.Sprintf("kogen: example check response %s wall_ms=%d", resp.Usage.Line(), time.Since(t0).Milliseconds()))
		sh.exampleUsage = sh.exampleUsage.Add(resp.Usage)
		calls := tools.Calls(resp.Items)
		if len(calls) != 1 || calls[0].Name != SubmitExampleCheckTool {
			return nil, exampleInvalid("expected one " + SubmitExampleCheckTool + " call")
		}
		args = calls[0].Args()
	}
	items, err := parseExampleCheck(args)
	if err != nil {
		return nil, err
	}
	event, lines := exampleOutcome(items, sh.request, string(intent), string(feature))
	sh.ev.Record(event)
	if lines == nil {
		if sh.exampleChecked == nil {
			sh.exampleChecked = map[string]bool{}
		}
		sh.exampleChecked[key] = true
	}
	return lines, nil
}

// exampleContradictionsFile is the record of the contradictions a not-ready Shape left, in
// the shaping directory.
const exampleContradictionsFile = "example-contradictions.json"

type exampleContradictions struct {
	SHA256 string   `json:"sha256"`
	Lines  []string `json:"lines"`
}

// writeExampleContradictions records the item lines against the hash of the package left on
// disk, the hash `kogen intent approve` shows.
func (sh *shaping) writeExampleContradictions(lines []string) error {
	baseline, err := project.Baseline(sh.root, sh.slug, sh.cfg)
	if err != nil {
		return err
	}
	b, err := json.Marshal(exampleContradictions{SHA256: project.Hash(sh.root, baseline), Lines: lines})
	if err != nil {
		return err
	}
	path := filepath.Join(sh.ev.Dir, exampleContradictionsFile)
	if err := os.WriteFile(path, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

// approveExampleContradictions refuses a package whose current hash is the one Shape left
// contradicting. A record that does not parse or names another hash does not affect approval.
func approveExampleContradictions(root, slug, sha string) error {
	b, err := os.ReadFile(filepath.Join(root, ".kogen/local/shaping", slug, exampleContradictionsFile))
	if err != nil {
		return nil
	}
	var rec exampleContradictions
	if json.Unmarshal(b, &rec) != nil || rec.SHA256 != sha {
		return nil
	}
	e := sys.Fail("intent", "examples_contradict", "Shape's example check found acceptance examples that contradict the Intent's rules; correct the examples or the rules in the Intent's files, or delete "+project.IntentDir(slug)+"/ and shape again", 1)
	e.Lines = rec.Lines
	return e
}
