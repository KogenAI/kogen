package build

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/project"
	"kogen/verify"
)

// The independent review and repair (chapter 06). After a green pass one reviewer, in a
// fresh conversation that never sees the builder's, reads the approved Intent and the
// candidate's source (material.go), repairs supported defects with the file and command
// tools and submits a verdict. Changed contents are verified externally; failures return to
// this same reviewer conversation. An unresolved blocker ends the Build instead of restarting
// the builder, and an explicit resume reopens it under the same reviewer.
//
// The reviewer's own state is kept in the Continuation (`Pass` is the pass under review and
// `Review` the session below), so a resume continues the very same conversation:
//
//	{"role":     {provider, model, effort},
//	 "input":    the reviewer's conversation (replay items, tool outputs, user messages),
//	 "usage":    {input, cached, output, reasoning} of this review so far,
//	 "attempts": [{pass, tree, verdict, findings}] earlier submitted verdicts of this review,
//	 "verdict":  {verdict, findings} the submitted verdict (stages review_verify and
//	              review_retry_verify only),
//	 "tree":     the candidate tree the verdict judged (same stages)}
//
// In the stage `review` the input is the conversation to send next; in `review_verify` the
// conversation after the verdict; in `review_retry_verify` the conversation the explicit
// resume continues after fresh verification.

var reviewToolNames = []string{"read_file", "view_image", "list_files", "search_text", "write_file", "shell"}

// reviewVerdict is a valid submission of submit_review.
type reviewVerdict struct {
	Verdict  string           `json:"verdict"`
	Findings []map[string]any `json:"findings"`
}

// reviewAttempt is one submitted verdict of a review: the pass it followed and the tree it
// judged.
type reviewAttempt struct {
	Pass     int              `json:"pass"`
	Tree     string           `json:"tree"`
	Verdict  string           `json:"verdict"`
	Findings []map[string]any `json:"findings"`
}

// reviewSession is the reviewer's saved state (see above).
type reviewSession struct {
	Role     project.Role    `json:"role"`
	Input    []any           `json:"input"`
	Usage    Tokens          `json:"usage"`
	Attempts []reviewAttempt `json:"attempts"`
	Verdict  *reviewVerdict  `json:"verdict,omitempty"`
	Tree     string          `json:"tree,omitempty"`
	// Tools are the tool definitions the reviewer conversation was given; a continued
	// conversation keeps them (empty: the current reviewer tools).
	Tools []any `json:"tools,omitempty"`
	// Rejected and NoTool are the allowances this conversation has consumed: one rejected
	// submit_review (after the unread-progress exemption) and one prose-only turn (the
	// reminder) are each sent back once, independently of each other. Remind marks the
	// pending reminder: the next request requires submit_review where the route supports it.
	// PrevUnread is the unread-part count of the last unread rejection (the progress
	// exemption). Reopened marks the reopened conversation of a blocked review. All of them
	// travel with the checkpoint, so an interruption or a working-window reset keeps them.
	Rejected   int  `json:"rejected_verdicts,omitempty"`
	NoTool     int  `json:"no_tool_reminders,omitempty"`
	Remind     bool `json:"remind,omitempty"`
	PrevUnread int  `json:"prev_unread,omitempty"`
	Reopened   bool `json:"reopened,omitempty"`
	// Repaired: a verdict of this review was already judged and sent back, so the pass it now
	// works from may hold the reviewer's own verified edits rather than the builder's tree.
	Repaired bool `json:"repaired,omitempty"`
}

func (s reviewSession) encode() (json.RawMessage, error) {
	s.Attempts = nonNil(s.Attempts)
	for i := range s.Attempts {
		s.Attempts[i].Findings = nonNil(s.Attempts[i].Findings)
	}
	if s.Verdict != nil {
		v := *s.Verdict
		v.Findings = nonNil(v.Findings)
		s.Verdict = &v
	}
	s.Input = nonNil(s.Input)
	return encodeJSON(s)
}

func reviewDecode(raw json.RawMessage) (reviewSession, error) {
	var s reviewSession
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&s); err != nil {
		return s, err
	}
	return s, nil
}

// reviewIndependent is the real Reviewer.
type reviewIndependent struct{}

// reviewRun is one independent review in progress: the pass under review and the session.
type reviewRun struct {
	b           *Attempt
	pass        verify.Pass
	sess        reviewSession
	tools       []any
	nativeTools *tools.Tools
	// external: the reviewer is an external executor; its source is delivered as complete
	// Kogen-owned prompt data (review_external.go), not as pinned parts it must read.
	external bool
}

func (b *Attempt) reviewNativeTools() *tools.Tools {
	return &tools.Tools{Root: b.Root, Session: b.s, Repo: agent.Git(b.repo), Enabled: reviewToolNames, Protected: b.Baseline, Excluded: b.Excluded}
}
func reviewTools(t *tools.Tools) []any {
	return shellDefinitions(t, slices.Concat(reviewToolNames, []string{agent.SubmitReviewTool}))
}

// Review starts the review of a green pass (REV-1): a new review number, the material and
// the conversation.
func (reviewIndependent) Review(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
	b.Review++
	if err := b.Track(); err != nil {
		return Approved{}, err
	}
	b.s.Progress(fmt.Sprintf("kogen: reviewing (review %d)", b.Review))
	role := b.Config.Models["review"]
	// Only the frozen caller diagnostic follows the authority message here, never the
	// builder's replay, progress or reasoning.
	diagnostic := b.diagnosticMessages()
	if nav := b.State.navigationIn(phaseReview); nav != "" {
		// A staged Build's reviewer is told the plan's position and that stage evidence is
		// historical: as its own leading message, so its instructions stay frozen.
		diagnostic = append(slices.Clone(diagnostic), map[string]any{"role": "user",
			"content": "Staged plan context for this independent review." + nav})
	}
	nativeTools := b.reviewNativeTools()
	tools := reviewTools(nativeTools)
	m, err := b.materialOf(pass)
	if err != nil {
		return Approved{}, err
	}
	// A review is a fresh conversation: the unfinished observations of an earlier review that
	// ended without a verdict are not carried into it (its archives stay in custody).
	if state := b.WorkingContext["review"]; state != nil {
		state.Observations = []any{}
	}
	input, err := b.materialPrepare(pass.Tree, m, role, reviewerPrompt(b.onDemand()), tools, diagnostic, false)
	if err != nil {
		return Approved{}, err
	}
	r := &reviewRun{b: b, pass: pass, tools: tools, nativeTools: nativeTools, sess: reviewSession{Role: role, Input: input, Usage: zeroTokens()}}
	return r.loop(ctx, nil, "")
}

// Resume continues a saved review (LOOP-10): a request that was interrupted is sent again
// with the saved conversation; a verdict whose verification was interrupted is judged
// again; a blocked review (verdict changes) is reopened, not replayed.
func (reviewIndependent) Resume(ctx context.Context, b *Attempt) (Approved, error) {
	c := b.Continuation
	sess, err := reviewDecode(c.Review)
	if err != nil || c.Pass == nil {
		return Approved{}, resumeRefused("the saved review state cannot be read")
	}
	nativeTools := b.reviewNativeTools()
	tools := reviewTools(nativeTools)
	if len(sess.Tools) > 0 {
		tools = sess.Tools
	}
	r := &reviewRun{b: b, pass: *c.Pass, sess: sess, tools: tools, nativeTools: nativeTools}
	verdicts := c.Stage != StageReview
	if verdicts && (sess.Verdict == nil || sess.Tree == "") {
		return Approved{}, resumeRefused("the saved review state has no verdict")
	}
	switch {
	case c.Stage == StageReviewRetry:
		return r.retry(ctx)
	case c.Stage == StageReviewVerify && sess.Verdict.Verdict == "changes":
		// An explicit resume reopens the blocker, not its terminal verdict.
		record := ReviewRecord{N: b.Review, Verdict: "pending", Findings: nonNil(sess.Verdict.Findings), Tree: sess.Tree}
		if b.LastReview != nil {
			record = *b.LastReview
			record.Verdict = "pending"
		}
		b.LastReview = &record
		if err := b.Track(); err != nil {
			return Approved{}, err
		}
		if err := r.save(StageReviewRetry); err != nil {
			return Approved{}, err
		}
		return r.retry(ctx)
	case c.Stage == StageReviewVerify:
		return r.loop(ctx, sess.Verdict, sess.Tree)
	}
	return r.loop(ctx, nil, "")
}

// save checkpoints the review at stage.
func (r *reviewRun) save(stage string) error {
	raw, err := r.sess.encode()
	if err != nil {
		return err
	}
	pass := r.pass
	r.b.setPhase(phaseReview)
	return r.b.Save(Continuation{Stage: stage, Pass: &pass, Review: raw})
}

// loop runs the reviewer's conversation, and judges each verdict, until the review approves
// or stops. A pending verdict (a review resumed while its verdict was being verified) is
// judged first.
func (r *reviewRun) loop(ctx context.Context, pending *reviewVerdict, tree string) (Approved, error) {
	b := r.b
	for {
		if pending == nil {
			if err := r.save(StageReview); err != nil {
				return Approved{}, err
			}
			if err := b.facts.update(b, "reviewing", ""); err != nil {
				return Approved{}, err
			}
			verdict, err := r.converse(ctx)
			if err != nil {
				return Approved{}, err
			}
			if tree, err = b.repo.Tree(b.Start, b.Excluded); err != nil {
				return Approved{}, err
			}
			pending = &verdict
		}
		approved, again, err := r.evaluate(ctx, *pending, tree)
		pending = nil
		if err != nil || !again {
			return approved, err
		}
	}
}

// retry is the explicit resume of a blocked review (REV-5): fresh verification of the
// candidate, then the original finding and the actual results go back to the same reviewer.
func (r *reviewRun) retry(ctx context.Context) (Approved, error) {
	b := r.b
	verdict := r.sess.Verdict
	pass, err := b.Verify(ctx)
	if err != nil {
		return Approved{}, err
	}
	attempts := append(slices.Clone(r.sess.Attempts), reviewAttempt{
		Pass: r.pass.N, Tree: r.sess.Tree, Verdict: verdict.Verdict, Findings: verdict.Findings,
	})
	findings, err := encodeJSON(nonNil(verdict.Findings))
	if err != nil {
		return Approved{}, err
	}
	evidence := pass.Results()
	if !pass.Green {
		evidence = b.PassFeedback(pass, "submit_review")
	}
	feedback := "The caller explicitly resumed this blocked Build. Continue as the same independent\n" +
		"reviewer for targeted clearance or scoped repair, not a new whole-change critique.\n" +
		"The original blocking finding remains unresolved until your new explicit decision:\n" +
		string(findings) + "\n" +
		"Earlier green evidence and approval do not clear this blocker. Fresh verification:\n" +
		evidence + "\n" +
		"Use the actual results, including failures and unrun items. Do not infer an operator\n" +
		"explanation. Submit changes if unresolved, or explicitly approve after resolving it;\n" +
		"edits still require ordinary external exact verification before commit.\n"
	r.pass = pass
	r.sess = reviewSession{
		Role: r.sess.Role, Usage: r.sess.Usage, Attempts: attempts, Reopened: true, Repaired: r.sess.Repaired,
		Input: slices.Concat(r.sess.Input, []any{map[string]any{"role": "user", "content": feedback}}),
	}
	return r.loop(ctx, nil, "")
}

// evaluate judges a valid verdict on the candidate tree. A blocked review ends the Build.
// An approval binds the tree: when it is not the tree of a green pass, the changed contents
// are verified, and a pass that is not green on that very tree returns to the reviewer
// (again true) with targeted feedback.
func (r *reviewRun) evaluate(ctx context.Context, verdict reviewVerdict, tree string) (ap Approved, again bool, err error) {
	b := r.b
	n := b.Review
	r.sess.Verdict, r.sess.Tree = &verdict, tree
	if err := r.save(StageReviewVerify); err != nil {
		return Approved{}, false, err
	}
	if err := b.BaselineIntact(); err != nil {
		return Approved{}, false, err
	}
	findings := nonNil(verdict.Findings)
	review := ReviewRecord{N: n, Verdict: verdict.Verdict, Findings: findings, Tree: tree}
	b.LastReview = &review
	if err := b.Track(); err != nil {
		return Approved{}, false, err
	}
	attempts := append(slices.Clone(r.sess.Attempts), reviewAttempt{Pass: r.pass.N, Tree: tree, Verdict: verdict.Verdict, Findings: findings})
	blocking := 0
	for _, f := range findings {
		if f["severity"] == "blocking" {
			blocking++
		}
	}
	b.s.Progress(fmt.Sprintf("kogen: review %d: %s, %d blocking", n, verdict.Verdict, blocking))
	if err := b.Run.Write(reviewFile(n), map[string]any{
		"model": r.sess.Role.Model, "effort": r.sess.Role.Effort, "usage": r.sess.Usage,
		"verdict": verdict.Verdict, "findings": findings, "tree": tree, "attempts": attempts,
	}); err != nil {
		return Approved{}, false, err
	}
	b.Run.Event(map[string]any{
		"event": "review", "review": n, "attempt": len(attempts), "pass": r.pass.N, "tree": tree,
		"verdict": verdict.Verdict, "findings": findings,
	})

	if verdict.Verdict == "changes" {
		e := sys.Fail("candidate", "review_blocked",
			"the reviewer could not resolve a substantive blocker within the approved Intent; edits are left in place", 1)
		for _, f := range findings {
			if f["severity"] == "blocking" {
				e.Lines = append(e.Lines, fmt.Sprintf("review: %s:%s: %s", display(f["path"]), display(f["line"]), display(f["message"])))
			}
		}
		return Approved{}, false, e
	}

	final := r.pass
	if !(r.pass.Green && tree == r.pass.Tree) {
		pending := review
		pending.Verdict = "pending"
		b.LastReview = &pending
		if err := b.Track(); err != nil {
			return Approved{}, false, err
		}
		if final, err = b.Verify(ctx); err != nil {
			return Approved{}, false, err
		}
	}
	if final.Green && final.Tree == tree {
		approved := review
		b.LastReview = &approved
		if err := b.Track(); err != nil {
			return Approved{}, false, err
		}
		return Approved{Pass: final, Review: approved}, false, nil
	}

	var feedback string
	if final.Green {
		paths, err := b.repo.Changed(tree, final.Tree)
		if err != nil {
			return Approved{}, false, err
		}
		b.s.Progress(fmt.Sprintf("kogen: review %d: candidate changed after approval; inspecting changed paths", n))
		feedback = "Candidate contents changed after your approval: " + strings.Join(paths, ", ") +
			". The new tree passed checks but has not been reviewed. Inspect these changes and submit_review for the current contents; do not restart the whole critique."
	} else {
		b.s.Progress(fmt.Sprintf("kogen: review %d: final verification failed; continuing targeted repairs", n))
		feedback = "Final verification of your repairs failed. Fix these failures and regressions from your edits; do not restart a whole-change critique. If observed evidence demonstrates a protected fixture defect, use submit_review changes with a blocking finding at that protected path instead of a production workaround, including a test-facing hidden comment.\n" +
			b.PassFeedback(final, "submit_review")
	}
	b.Repairs++
	if err := b.Track(); err != nil {
		return Approved{}, false, err
	}
	r.pass = final
	r.sess = reviewSession{
		Role: r.sess.Role, Usage: r.sess.Usage, Attempts: attempts, Reopened: r.sess.Reopened, Repaired: true,
		Input: slices.Concat(r.sess.Input, []any{map[string]any{"role": "user", "content": feedback}}),
	}
	return Approved{}, true, nil
}

// converse is the reviewer's requests and tool calls until it submits a valid verdict. Two
// allowances, spent independently and each once: a rejected submit_review is sent back with its
// problems, and a prose-only turn is sent back with a reminder (the next request requires
// submit_review where the route supports it). Spending an allowance a second time ends this
// review without a verdict (reviewRun.invalidStop).
func (r *reviewRun) converse(ctx context.Context) (reviewVerdict, error) {
	b := r.b
	prevUnread := -1
	if r.sess.PrevUnread > 0 {
		prevUnread = r.sess.PrevUnread
	}
	for {
		if err := r.save(StageReview); err != nil {
			return reviewVerdict{}, err
		}
		force := ""
		if r.sess.Remind {
			mode := "text_fallback"
			if provider.SupportsToolChoice(providerRole(r.sess.Role)) {
				mode = "api_forced"
				force = agent.SubmitReviewTool
			}
			b.Run.Event(map[string]any{
				"event": "review_tool_choice", "review": b.Review, "tool": agent.SubmitReviewTool, "mode": mode,
				"rejected_verdicts": r.sess.Rejected, "no_tool_reminders": r.sess.NoTool,
			})
		}
		retain := func(c *Continuation, input []any) {
			sent := r.sess
			sent.Input = input
			if raw, err := sent.encode(); err == nil {
				c.Review = raw
			}
		}
		resp, active, err := b.Request(ctx, RequestSpec{
			Owner: "review", Role: r.sess.Role, Instructions: reviewerPrompt(b.onDemand()),
			Input: r.sess.Input, Tools: r.tools, Retain: retain, ForceTool: force,
			Prefill: func(input []any) ([]any, error) {
				return b.prefillSource(r.sess.Role, reviewerPrompt(b.onDemand()), r.tools, input)
			},
		})
		if err != nil {
			return reviewVerdict{}, err
		}
		// The reminder request is over: ordinary tool choice again.
		r.sess.Remind = false
		r.sess.Usage = r.sess.Usage.plus(responseTokens(r.sess.Role, resp))
		if err := b.Track(); err != nil {
			return reviewVerdict{}, err
		}
		input := slices.Concat(active, tools.Replay(resp.Items))
		calls := tools.Calls(resp.Items)
		tl := r.nativeTools
		if tl == nil {
			tl = b.reviewNativeTools()
		}

		var outs []any
		var verdict *reviewVerdict
		var problems []string
		for i := range calls {
			call := calls[i]
			if err := b.s.Err(); err != nil {
				return reviewVerdict{}, err
			}
			if err := b.validateWorkingContext(); err != nil {
				return reviewVerdict{}, err
			}
			if err := project.ValidateSource(b.SourceProvenance); err != nil {
				return reviewVerdict{}, err
			}
			if err := b.Save(Continuation{Stage: StageTool, Owner: "review", Input: slices.Concat(input, outs)}); err != nil {
				return reviewVerdict{}, err
			}
			switch {
			case verdict != nil || problems != nil:
				outs = append(outs, call.Output("ignored: the review already has a verdict"))
			case call.Name == agent.SubmitReviewTool:
				v, probs, err := r.validate(call.Args(), input)
				if err != nil {
					return reviewVerdict{}, err
				}
				if probs != nil {
					problems = probs
					outs = append(outs, call.Output(tools.Cut("invalid verdict:\n"+strings.Join(probs, "\n"))))
				} else {
					verdict = v
					outs = append(outs, call.Output("accepted"))
				}
			default:
				out, err := tl.Call(call)
				if err != nil {
					return reviewVerdict{}, err
				}
				result := out.Cut()
				if event := tools.ReadEvent(call, result, "review"); event != nil {
					b.Run.Event(event)
				}
				event := map[string]any{
					"event": "review_tool_call", "name": call.Name,
					"arguments": provider.Fingerprint(call.Arguments), "result": provider.Fingerprint(result.Value()),
				}
				for k, v := range b.toolRecordFields(call, result, b.reviewPartID) {
					event[k] = v
				}
				b.Run.Event(event)
				done := &Completed{Call: call.Item, Result: result.Value()}
				if err := b.Save(Continuation{Stage: StageTool, Owner: "review", Input: slices.Concat(input, outs), Completed: done}); err != nil {
					return reviewVerdict{}, err
				}
				if call.Name == "shell" {
					if err := b.BaselineIntact(); err != nil {
						return reviewVerdict{}, err
					}
				}
				outs = append(outs, call.Output(result))
			}
		}
		input = slices.Concat(input, outs)
		if len(calls) == 0 {
			problems = []string{"the review ended without calling submit_review"}
			if force != "" {
				// The route was told to call submit_review and answered with text only: a fault of
				// the provider, not unread-part progress. It is only a no-tool turn for the allowance.
				b.Run.Event(map[string]any{
					"event": "provider_fault", "fault": "forced_tool_not_called", "review": b.Review, "tool": force,
					"mode": "api_forced", "route": provider.Name(providerRole(r.sess.Role)), "model": r.sess.Role.Model,
				})
			}
		}

		exempt := false
		if n := unreadProblemCount(problems); n > 0 {
			exempt = prevUnread < 0 || n < prevUnread
			prevUnread, r.sess.PrevUnread = n, n
		}
		switch {
		case problems != nil && exempt:
			// Progress on unread parts spends neither allowance.
			r.allowance("unread_progress_exempt")
		case problems != nil && len(calls) == 0:
			if r.sess.NoTool >= 1 {
				return reviewVerdict{}, r.invalidStop(problems, "no_tool_reminder_exhausted")
			}
			input = append(input, map[string]any{"role": "user",
				"content": "Not a valid verdict: " + strings.Join(problems, "; ") + ". Call submit_review."})
			r.sess.NoTool++
			r.sess.Remind = true
			r.allowance("no_tool_turn")
		case problems != nil:
			if r.sess.Rejected >= 1 {
				return reviewVerdict{}, r.invalidStop(problems, "rejected_verdict_exhausted")
			}
			r.sess.Rejected++
			r.allowance("rejected_verdict")
		case verdict != nil:
			r.sess.Input = input
			if !r.external {
				if err := b.materialEvent(input); err != nil {
					return reviewVerdict{}, err
				}
			}
			return *verdict, nil
		}
		r.sess.Input = input
	}
}

// validate checks a submit_review call (REV-4): a verdict approve or changes with findings
// {path, line, severity, message}; every path names a file of the checkout or of the start
// HEAD; changes has a blocking finding, approve none; no blocking finding asserts that there is
// no product defect; and an approval has read all pinned source parts (in the on_demand mode,
// any verdict has read every part covering a changed hunk). It returns the verdict, or the
// problems to send back.
func (r *reviewRun) validate(args map[string]any, input []any) (*reviewVerdict, []string, error) {
	b := r.b
	verdict, _ := args["verdict"].(string)
	list, isList := args["findings"].([]any)
	if (verdict != "approve" && verdict != "changes") || !isList {
		// Report only JSON types, never submitted contents.
		kind := func(field string) string {
			value, present := args[field]
			if !present {
				return "missing"
			}
			switch value.(type) {
			case nil:
				return "null"
			case string:
				return "a string"
			case bool:
				return "a boolean"
			case []any:
				return "an array"
			case map[string]any:
				return "an object"
			default:
				return "a number"
			}
		}
		var details []string
		if verdict != "approve" && verdict != "changes" {
			typ := kind("verdict")
			if typ == "a string" {
				typ += " with an unsupported value"
			}
			details = append(details, "verdict must be approve or changes but was "+typ)
		}
		if !isList {
			details = append(details, "findings must be a JSON array of objects but was "+kind("findings"))
		}
		return nil, []string{"submit_review needs verdict (approve or changes) and a findings list; " + strings.Join(details, "; ")}, nil
	}
	var problems []string
	var findings []map[string]any
	blocking := 0
	for _, item := range list {
		f, _ := item.(map[string]any)
		path, pathOK := f["path"].(string)
		_, lineOK := reviewInteger(f["line"])
		severity, _ := f["severity"].(string)
		_, messageOK := f["message"].(string)
		if f != nil && f["severity"] == "blocking" {
			blocking++
		}
		if f == nil || !pathOK || !lineOK || (severity != "blocking" && severity != "note") || !messageOK {
			problems = append(problems, "each finding needs path (string), line (integer), severity (blocking or note) and message")
			continue
		}
		findings = append(findings, f)
		if st, err := os.Stat(filepath.Join(b.Root, path)); err == nil && st.Mode().IsRegular() {
			continue
		}
		if _, ok := b.repo.Show(b.Start, path); !ok {
			problems = append(problems, path+" is not a file of the repository")
		}
	}
	switch {
	case verdict == "changes" && blocking == 0:
		problems = append(problems, "a changes verdict needs at least one blocking finding")
	case verdict == "approve" && blocking > 0:
		problems = append(problems, "an approve verdict cannot have blocking findings")
	}
	for _, f := range findings {
		// A blocker at a protected path reports a protected fixture defect (the documented stop),
		// which may well say that the product is not at fault.
		path, _ := f["path"].(string)
		if message, _ := f["message"].(string); f["severity"] == "blocking" && reviewNoDefect(message) && !slices.Contains(b.Baseline, path) {
			problems = append(problems, "a blocking finding that asserts no product defect (such as inspection not completed) is not a verdict on the candidate; "+
				"complete the reads the review requires, then submit approve, or changes with a concrete candidate defect")
			break
		}
	}
	if !r.external && b.onDemand() {
		unread, err := b.materialRequiredUnread(input)
		if err != nil {
			return nil, nil, err
		}
		if len(unread) > 0 {
			problems = append(problems, fmt.Sprintf("%d required hunk-covering pinned part(s) unread; read them completely before a verdict; incomplete reading is not a candidate defect; use read_file on %s",
				len(unread), strings.Join(unread[:min(8, len(unread))], ", ")))
		}
	}
	if verdict == "changes" && !r.external && !b.onDemand() {
		unread, err := b.materialUnread(input)
		if err != nil {
			return nil, nil, err
		}
		if len(unread) > 0 {
			problems = append(problems, fmt.Sprintf("%d pinned part(s) unread; read them before a verdict; incomplete delivery is not a candidate defect; use read_file on %s",
				len(unread), strings.Join(unread[:min(8, len(unread))], ", ")))
		}
	}
	if verdict == "approve" && !r.external && !b.onDemand() {
		unread, err := b.materialUnread(input)
		if err != nil {
			return nil, nil, err
		}
		if len(unread) > 0 {
			problems = append(problems, fmt.Sprintf("Read all pinned source evidence before approving: %d unread part(s); use read_file on %s",
				len(unread), strings.Join(unread[:min(8, len(unread))], ", ")))
		}
	}
	if problems != nil {
		return nil, problems, nil
	}
	return &reviewVerdict{Verdict: verdict, Findings: findings}, nil, nil
}

// reviewNoDefectRe matches a finding message that explicitly asserts no product defect, such as
// "no product defect is asserted by this finding" or "not a candidate defect". A concrete defect
// that merely mentions inspection does not match.
var reviewNoDefectRe = regexp.MustCompile(`(?i)\bno\s+(?:(?:product|candidate|code|implementation)\s+)?defects?\s+(?:(?:is|are|was|were|has\s+been|have\s+been)\s+)?(?:asserted|claimed|alleged|identified|found|reported)\b` +
	`|\bnot\s+(?:a|an)\s+(?:product|candidate)\s+defect\b` +
	`|\b(?:does|do|is|are)\s+not\s+(?:assert|claim|allege)(?:ing)?\s+(?:a|any)\s+(?:(?:product|candidate)\s+)?defect` +
	`|\bwithout\s+(?:asserting|claiming|alleging)\s+(?:a|any)\s+(?:(?:product|candidate)\s+)?defect`)

// reviewNoDefect reports whether a blocking finding's message explicitly asserts no product
// defect: invalid feedback, never a blocker.
func reviewNoDefect(message string) bool { return reviewNoDefectRe.MatchString(message) }

// reviewInteger is v when it is a JSON integer (not a float).
func reviewInteger(v any) (int64, bool) {
	switch n := v.(type) {
	case int64:
		return n, true
	case int:
		return int64(n), true
	case json.Number:
		return 0, !strings.ContainsAny(n.String(), ".eE")
	}
	return 0, false
}

// unreadProblemCount is the unread count named by the unread-parts problem of a changes
// verdict, or 0 when problems carry none.
func unreadProblemCount(problems []string) int {
	for _, p := range problems {
		var n int
		if _, err := fmt.Sscanf(p, "%d pinned part(s) unread; read them before a verdict;", &n); err == nil && n > 0 {
			return n
		}
	}
	return 0
}
