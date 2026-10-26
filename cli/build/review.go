package build

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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
	b     *Attempt
	pass  verify.Pass
	sess  reviewSession
	tools []any
}

func reviewTools() []any {
	return agent.AsAny(agent.Defs(slices.Concat(reviewToolNames, []string{agent.SubmitReviewTool})...))
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
	// Only the frozen caller diagnostic follows the builder's initial authority message
	// here, never its replay, progress or reasoning.
	var diagnostic []any
	if oc := b.WorkingContext["build"]; oc != nil && len(oc.Mandatory) > 1 {
		diagnostic = oc.Mandatory[1:]
	}
	if nav := b.State.navigationIn(phaseReview); nav != "" {
		// A staged Build's reviewer is told the plan's position and that stage evidence is
		// historical: as its own leading message, so its instructions stay frozen.
		diagnostic = append(slices.Clone(diagnostic), map[string]any{"role": "user",
			"content": "Staged plan context for this independent review." + nav})
	}
	tools := reviewTools()
	m, err := b.materialOf(pass)
	if err != nil {
		return Approved{}, err
	}
	input, err := b.materialPrepare(pass.Tree, m, role, agent.Prompt(agent.Reviewer), tools, diagnostic, false)
	if err != nil {
		return Approved{}, err
	}
	r := &reviewRun{b: b, pass: pass, tools: tools, sess: reviewSession{Role: role, Input: input, Usage: zeroTokens()}}
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
	tools := reviewTools()
	if len(sess.Tools) > 0 {
		tools = sess.Tools
	}
	r := &reviewRun{b: b, pass: *c.Pass, sess: sess, tools: tools}
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
		Role: r.sess.Role, Usage: r.sess.Usage, Attempts: attempts,
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
		Role: r.sess.Role, Usage: r.sess.Usage, Attempts: attempts,
		Input: slices.Concat(r.sess.Input, []any{map[string]any{"role": "user", "content": feedback}}),
	}
	return Approved{}, true, nil
}

// converse is the reviewer's requests and tool calls until it submits a valid verdict. One
// invalid verdict is sent back with its problems; a second ends the Build.
func (r *reviewRun) converse(ctx context.Context) (reviewVerdict, error) {
	b := r.b
	invalid := 0
	for {
		if err := r.save(StageReview); err != nil {
			return reviewVerdict{}, err
		}
		retain := func(c *Continuation, input []any) {
			sent := r.sess
			sent.Input = input
			if raw, err := sent.encode(); err == nil {
				c.Review = raw
			}
		}
		resp, active, err := b.Request(ctx, RequestSpec{
			Owner: "review", Role: r.sess.Role, Instructions: agent.Prompt(agent.Reviewer),
			Input: r.sess.Input, Tools: r.tools, Retain: retain,
			Prefill: func(input []any) ([]any, error) {
				return b.prefillSource(r.sess.Role, agent.Prompt(agent.Reviewer), r.tools, input)
			},
		})
		if err != nil {
			return reviewVerdict{}, err
		}
		r.sess.Usage = r.sess.Usage.plus(responseTokens(r.sess.Role, resp))
		if err := b.Track(); err != nil {
			return reviewVerdict{}, err
		}
		input := slices.Concat(active, tools.Replay(resp.Items))
		calls := tools.Calls(resp.Items)
		tl := &tools.Tools{
			Root: b.Root, Session: b.s, Repo: agent.Git(b.repo), Enabled: reviewToolNames, Protected: b.Baseline, Excluded: b.Excluded,
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
				b.Run.Event(map[string]any{
					"event": "review_tool_call", "name": call.Name,
					"arguments": provider.Fingerprint(call.Arguments), "result": provider.Fingerprint(result.Value()),
				})
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
		}

		switch {
		case problems != nil && invalid >= 1:
			b.Run.Event(map[string]any{"event": "review", "review": b.Review, "verdict": "invalid", "problems": problems})
			b.LastReview = &ReviewRecord{N: b.Review, Verdict: "invalid", Findings: []map[string]any{}}
			return reviewVerdict{}, sys.Fail("candidate", "review_invalid",
				"the reviewer did not return a valid verdict; edits are left in place", 1)
		case problems != nil:
			if len(calls) == 0 {
				input = append(input, map[string]any{"role": "user",
					"content": "Not a valid verdict: " + strings.Join(problems, "; ") + ". Call submit_review."})
			}
			invalid++
		case verdict != nil:
			r.sess.Input = input
			return *verdict, nil
		}
		r.sess.Input = input
	}
}

// validate checks a submit_review call (REV-4): a verdict approve or changes with findings
// {path, line, severity, message}; every path names a file of the checkout or of the start
// HEAD; changes has a blocking finding, approve none; and an approval has read all pinned
// source parts. It returns the verdict, or the problems to send back.
func (r *reviewRun) validate(args map[string]any, input []any) (*reviewVerdict, []string, error) {
	b := r.b
	verdict, _ := args["verdict"].(string)
	list, isList := args["findings"].([]any)
	if (verdict != "approve" && verdict != "changes") || !isList {
		return nil, []string{"submit_review needs verdict (approve or changes) and a findings list"}, nil
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
	if verdict == "approve" {
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
