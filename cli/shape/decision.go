package shape

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/executor"
	"kogen/project"
)

// SubmitDecisionCheckTool is the one tool of the decision check call.
const SubmitDecisionCheckTool = "submit_decision_check"

const decisionInstructions = `You check the stated decisions of one candidate Intent against the feature request that it answers. You see only the request text and the candidate intent.md. Read-only: do not use any tool except ` + SubmitDecisionCheckTool + `.

Give one item for every line of the candidate's "## Decisions" section and for every explicit result the intent states for a concrete input in its prose or examples. For each item give:
- statement: text copied exactly from intent.md (for a Decisions line, the whole line);
- request_quotes: the passages of the request that support or contradict it, each copied exactly from the request (none when the request is silent);
- verdict: follows (the request states it), contradicts (the request states otherwise) or unsupported (the request does not state it);
- why: one short reason.
A Decision line may be marked as an assumption with (assumption: <what the user must confirm>) placed before its trailing tag; a marked line keeps its trailing (source: request) or (source: answer N).
Answer by calling ` + SubmitDecisionCheckTool + `.`

// assumptionRule is the feedback line that says exactly how to mark an assumption.
const assumptionRule = "Mark an assumption with (assumption: <what the user must confirm>) before the required trailing tag, e.g. - <decision> (assumption: <what the user must confirm>) (source: request); every Decision line keeps its trailing (source: request) or (source: answer N)."

func decisionSchema() map[string]any {
	s := map[string]any{"type": "string"}
	item := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"statement":      s,
			"request_quotes": map[string]any{"type": "array", "items": s},
			"verdict":        map[string]any{"type": "string", "enum": []any{"follows", "contradicts", "unsupported"}},
			"why":            s,
		},
		"required":             []any{"statement", "request_quotes", "verdict", "why"},
		"additionalProperties": false,
	}
	return map[string]any{
		"type":                 "object",
		"properties":           map[string]any{"items": map[string]any{"type": "array", "items": item}},
		"required":             []any{"items"},
		"additionalProperties": false,
	}
}

func decisionToolDef() map[string]any {
	return map[string]any{
		"type": "function", "name": SubmitDecisionCheckTool, "strict": true,
		"description": "Submit the decision check: one item per stated decision with its request quotes and verdict.",
		"parameters":  decisionSchema(),
	}
}

func decisionInvalid(why string) error {
	return sys.Fail("shape", "decision_check_invalid", "the decision check answer is not a valid "+SubmitDecisionCheckTool+" payload ("+why+"); nothing was published", 1)
}

type decisionItem struct {
	statement string
	quotes    []string
	verdict   string
	why       string
}

func parseDecisionCheck(args map[string]any) ([]decisionItem, error) {
	list, ok := args["items"].([]any)
	if !ok {
		return nil, decisionInvalid("items must be a list")
	}
	items := []decisionItem{}
	for _, raw := range list {
		m, ok := raw.(map[string]any)
		if !ok {
			return nil, decisionInvalid("an item must be an object")
		}
		var it decisionItem
		var okS, okV, okW bool
		it.statement, okS = m["statement"].(string)
		it.verdict, okV = m["verdict"].(string)
		it.why, okW = m["why"].(string)
		quotes, okQ := m["request_quotes"].([]any)
		if !okS || !okV || !okW || !okQ || (it.verdict != "follows" && it.verdict != "contradicts" && it.verdict != "unsupported") {
			return nil, decisionInvalid("an item is malformed")
		}
		it.quotes = []string{}
		for _, q := range quotes {
			qs, ok := q.(string)
			if !ok {
				return nil, decisionInvalid("a request quote must be a string")
			}
			it.quotes = append(it.quotes, qs)
		}
		items = append(items, it)
	}
	return items, nil
}

// decisionOutcome applies the mechanical rules: final items (verdicts replaced where a
// statement or quote is not found), the event, and the feedback lines (nil when no problem).
func decisionOutcome(items []decisionItem, request, intent string) (map[string]any, []string) {
	counts := map[string]int{}
	events := make([]any, len(items))
	var problems []string
	for i := range items {
		it := &items[i]
		supported := strings.Contains(intent, it.statement)
		for _, q := range it.quotes {
			supported = supported && strings.Contains(request, q)
		}
		if !supported {
			it.verdict = "unsupported"
		}
		counts[it.verdict]++
		events[i] = map[string]any{"statement": it.statement, "request_quotes": it.quotes, "verdict": it.verdict, "why": it.why}
		if it.verdict == "follows" || strings.Contains(it.statement, "(assumption:") {
			continue
		}
		quoted := make([]string, len(it.quotes))
		for j, q := range it.quotes {
			quoted[j] = `"` + q + `"`
		}
		problems = append(problems, fmt.Sprintf("statement: %s | request_quotes: %s | why: %s", it.statement, strings.Join(quoted, ", "), it.why))
	}
	event := map[string]any{"event": "decision_check", "follows": counts["follows"], "contradicts": counts["contradicts"], "unsupported": counts["unsupported"], "items": events}
	if len(problems) == 0 {
		return event, nil
	}
	head := fmt.Sprintf("Decision check: %d stated decisions are not supported by the request; follow the request, or ask, or mark the decision as an assumption the user must confirm:", len(problems))
	return event, append([]string{head, assumptionRule}, problems...)
}

// decisionCheck makes one fresh read-only call on the candidate intent.md and returns the
// feedback lines, nil when the candidate may go on.
func (sh *shaping) decisionCheck(ctx context.Context, intent string) ([]string, []decisionItem, error) {
	input := "Slug: " + sh.slug + "\n\n# Request\n\n" + sh.request + "\n\n# Candidate intent.md\n\n" + intent
	var args map[string]any
	sh.decisionChecks++
	if sh.ext != nil {
		x, err := startExternal(ctx, sh.ext, sh.extMax, sh.repo, sh.root, sh.s.Getenv("HOME"),
			fmt.Sprintf("%s/executor-decision-%d", sh.ev.Dir, sh.decisionChecks), sh.slug, sh.role, decisionInstructions+"\n\n"+input, "", mustJSON(decisionSchema()), sh.ev.Record, nil)
		if err != nil {
			return nil, nil, err
		}
		defer x.close()
		res, err := x.round(ctx, "")
		sh.decisionRounds += x.rounds
		if err != nil {
			return nil, nil, err
		}
		if res.Ending != executor.EndFinish {
			return nil, nil, decisionInvalid("the session ended without a result")
		}
		if args, err = submissionArgs(res.Structured); err != nil {
			return nil, nil, decisionInvalid("not a JSON object")
		}
	} else {
		sh.progress("kogen: checking the stated decisions")
		revision, err := CurrentRevision(sh.repo)
		if err != nil {
			return nil, nil, err
		}
		cacheID := startConversation(sh.ev, "decision-check")
		req := conversationRequest(provider.Request{
			Role: ProviderRole(sh.role), Instructions: decisionInstructions,
			Input: []any{map[string]any{"role": "user", "content": input}}, Tools: []any{decisionToolDef()},
			Scope: sh.ev.Dir, Context: map[string]any{"phase": "shape", "role": "shape", "slug": sh.slug},
		}, cacheID)
		call := sh.ev.BeginCall("shape", "", revision.Map(), "decision check", sh.role)
		t0 := time.Now()
		resp, err := sh.client.Respond(ctx, sh.s, req, call)
		call.End(resp, err)
		if err != nil {
			if e, ok := sys.AsError(err); ok && e.Class == "provider" {
				return nil, nil, sh.providerFailed(e)
			}
			return nil, nil, err
		}
		sh.progress(fmt.Sprintf("kogen: decision check response %s wall_ms=%d", resp.Usage.Line(), time.Since(t0).Milliseconds()))
		sh.decisionUsage = sh.decisionUsage.Add(resp.Usage)
		calls := tools.Calls(resp.Items)
		if len(calls) != 1 || calls[0].Name != SubmitDecisionCheckTool {
			return nil, nil, decisionInvalid("expected one " + SubmitDecisionCheckTool + " call")
		}
		args = calls[0].Args()
	}
	items, err := parseDecisionCheck(args)
	if err != nil {
		return nil, nil, err
	}
	event, lines := decisionOutcome(items, sh.request, intent)
	sh.ev.Record(event)
	return lines, items, nil
}

// assumptionLines are the Decisions lines marked as assumptions, without their leading "- ",
// for the approval card; nil unless the decision check is enabled.
func assumptionLines(cfg *project.Config, intent string) []string {
	if !cfg.ShapeDecisionCheck.Enabled {
		return nil
	}
	var out []string
	for _, l := range decisionLines(intent) {
		if strings.Contains(l, "(assumption:") {
			out = append(out, sourceTagRe.ReplaceAllString(strings.TrimPrefix(strings.TrimSpace(l), "- "), ""))
		}
	}
	return out
}

var sourceTagRe = regexp.MustCompile(`\s*\(source: (?:request|answer \d+)\)\s*$`)

var whitespaceRun = regexp.MustCompile(`\s+`)

// markAssumptions rewrites each flagged Decisions line of the intent with an assumption
// marker before its trailing source tag. ok is false (nothing marked) unless every flagged
// item is unsupported and its statement is a tagged line of the Decisions section.
func markAssumptions(items []decisionItem, intent string) (marked string, statements []string, ok bool) {
	lines := decisionLines(intent)
	why := map[string]string{}
	for _, it := range items {
		if it.verdict == "follows" || strings.Contains(it.statement, "(assumption:") {
			continue
		}
		if it.verdict != "unsupported" {
			return "", nil, false
		}
		found := ""
		for _, l := range lines {
			if strings.TrimSpace(l) == strings.TrimSpace(it.statement) && sourceTagRe.MatchString(l) {
				found = l
				break
			}
		}
		if found == "" {
			return "", nil, false
		}
		why[found] = strings.TrimSpace(whitespaceRun.ReplaceAllString(it.why, " "))
		statements = append(statements, it.statement)
	}
	if len(statements) == 0 {
		return "", nil, false
	}
	marked = intent
	for line, w := range why {
		tag := sourceTagRe.FindString(line)
		head := strings.TrimRight(strings.TrimSuffix(line, tag), " \t")
		marked = strings.Replace(marked, line, head+" (assumption: "+w+")"+" "+strings.TrimSpace(tag), 1)
	}
	return marked, statements, true
}
