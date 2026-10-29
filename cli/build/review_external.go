package build

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"kogen-loop/sys"
	"kogen/agent"
	"kogen/executor"
	"kogen/verify"
)

// reviewExternal is the independent review by an external executor (Claude Code): the review
// role's own fresh session, never the builder's conversation, claims or transcript. Kogen
// delivers the complete exact authority and source as outgoing prompt data (no Read-tool
// receipt is claimed), validates the verdict with the same rules as the native reviewer and
// evaluates it with the same exact-tree logic (reviewRun.evaluate). Red verification and
// concrete failures return to this same reviewer session. It has no exact resume.
type reviewExternal struct {
	exec      executor.Executor
	desc      executor.Descriptor
	maxRounds int
}

// reviewMaterial is the private evidence of what one review was given: exact bytes and hashes
// of the authority and the source, and the identity of every changed path (the parts). Delivery
// counts only after a completed round of the matching session.
type reviewMaterial struct {
	Review    int              `json:"review"`
	Tree      string           `json:"tree"`
	Authority fileEvidence     `json:"authority"`
	Source    fileEvidence     `json:"source"`
	Parts     []map[string]any `json:"parts"`
	Session   string           `json:"session_id,omitempty"`
	Delivered bool             `json:"delivered"`
	Round     int              `json:"delivered_round,omitempty"`
}

type fileEvidence struct {
	File   string `json:"file"`
	Bytes  int    `json:"bytes"`
	SHA256 string `json:"sha256"`
}

// reviewTask is what the external reviewer is asked, besides the authority and the source.
const reviewTask = "# Review task\n\n" +
	"Review the candidate above against the approved Intent. The complete authority, the check results, the diff and the full text of every changed file are included in this message; they are Kogen's exact data for this candidate.\n" +
	"Repair concrete defects within the approved Intent with your tools; protected paths cannot be edited. Maintenance preferences are non-blocking notes.\n" +
	agent.LimitRaises + "\n" +
	"Finish with the structured verdict: verdict approve or changes, and findings {path, line, severity blocking|note, message}. A changes verdict needs a blocking finding; an approve verdict has none. Kogen verifies any contents you changed and tells you the actual results."

func (x reviewExternal) Resume(context.Context, *Attempt) (Approved, error) {
	return Approved{}, resumeRefused("an independent review by an external executor cannot be resumed (resume capability: none)")
}

func reviewSchema() json.RawMessage {
	params := agent.Defs(agent.SubmitReviewTool)[0]["parameters"]
	b, _ := json.Marshal(params)
	return b
}

func (x reviewExternal) Review(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
	b.Review++
	if err := b.Track(); err != nil {
		return Approved{}, err
	}
	b.s.Progress(fmt.Sprintf("kogen: reviewing (review %d)", b.Review))
	role := b.Config.Models["review"]
	m, err := b.materialOf(pass)
	if err != nil {
		return Approved{}, err
	}
	// The caller's diagnostic data and the staged plan context follow the authority, exactly as
	// the native reviewer receives them; never the builder's replay, progress or reasoning.
	stable := m.Authority
	if oc := b.WorkingContext["build"]; oc != nil && len(oc.Mandatory) > 1 {
		for _, item := range oc.Mandatory[1:] {
			stable += "\n" + diagnosticText(item) + "\n"
		}
	}
	if nav := b.State.navigationIn(phaseReview); nav != "" {
		stable += "\nStaged plan context for this independent review." + nav + "\n"
	}
	stable += "\n" + reviewTask
	dynamic := m.Source

	dir := filepath.Join(b.Run.Dir, "executor-review")
	ev, err := writeReviewMaterial(dir, b.Review, pass.Tree, stable, dynamic, m.Files)
	if err != nil {
		return Approved{}, err
	}
	if err := ev.check(dir); err != nil {
		return Approved{}, err
	}
	if cur, err := b.repo.Tree(b.Start, b.Excluded); err != nil {
		return Approved{}, err
	} else if cur != pass.Tree {
		return Approved{}, custodyInvalid("the candidate changed after its green pass and before the review was sent")
	}

	task := executor.Task{
		Role: executor.RoleReview, Root: b.Root, Brief: executor.Brief{Stable: stable, Dynamic: dynamic},
		Protected: b.Baseline, Excluded: b.Excluded, Model: role.Model, Effort: role.Effort,
		StartTree: b.Start, RunID: b.Run.ID, Home: b.s.Getenv("HOME"), MaxRounds: x.maxRounds,
		Schema: reviewSchema(), Dir: filepath.Join(dir, "session"),
	}
	if approval, err := decodeBase64(b.ApprovalBytes); err == nil {
		task.Approval = hashHex(approval)
	}
	if err := os.MkdirAll(task.Dir, 0o700); err != nil {
		return Approved{}, err
	}
	sess, err := x.exec.Start(ctx, task, func(event map[string]any) { b.Run.Event(event) })
	if err != nil {
		return Approved{}, err
	}
	defer sess.Close()
	h := sess.Handle()
	if h.SessionID == "" || (b.Executor != nil && h.SessionID == b.Executor.SessionID) {
		return Approved{}, executor.Fail(executor.ReasonProtocol, "the reviewer session is not distinct from the builder's")
	}
	caps, _ := x.desc.For(executor.RoleReview)
	// A fresh review after one that ended without a verdict is its own session; the usage of
	// the earlier sessions stays in the Build's known totals.
	earlier := b.ReviewExecutor
	b.ReviewExecutor = &ExecutorState{
		Name: x.desc.Name, Version: h.Version, SessionID: h.SessionID,
		Usage: ExecutorUsage{Input: count(0), Cached: count(0), Output: count(0), Reasoning: count(0), State: executor.UsageComplete,
			Source: caps.Usage, CostUSD: new(float64)},
	}
	if earlier != nil {
		b.ReviewExecutor.Usage = earlier.Usage
	}
	ev.Session = h.SessionID
	if err := b.Track(); err != nil {
		return Approved{}, err
	}

	r := &reviewRun{b: b, pass: pass, external: true, sess: reviewSession{Role: role, Usage: zeroTokens()}}
	feedback, invalid := "", 0
	for round := 1; ; round++ {
		if round > x.maxRounds {
			return Approved{}, executor.RoundLimit(x.maxRounds)
		}
		if err := ev.check(dir); err != nil {
			return Approved{}, err
		}
		if err := r.save(StageReview); err != nil {
			return Approved{}, err
		}
		if err := b.facts.update(b, "reviewing", ""); err != nil {
			return Approved{}, err
		}
		res, err := b.runGuardedRound(ctx, sess, executor.Input{Feedback: feedback})
		if err != nil {
			return Approved{}, err
		}
		if res.Ending != executor.EndFinish && res.Ending != executor.EndNoCall {
			return Approved{}, executor.Fail(executor.ReasonProtocol, "executor "+x.desc.Name+" returned the unknown round ending "+inspectString(string(res.Ending)))
		}
		b.ReviewExecutor.Rounds = round
		b.ReviewExecutor.Usage = b.ReviewExecutor.Usage.plus(res.Usage, round == 1 && earlier == nil)
		if res.Handle.Version != "" {
			b.ReviewExecutor.Version = res.Handle.Version
		}
		b.Run.Event(map[string]any{
			"event": "executor_round", "role": executor.RoleReview, "review": b.Review, "round": round,
			"executor": x.desc.Name, "ending": string(res.Ending), "usage": res.Usage, "session_id": res.Handle.SessionID,
		})
		if res.Handle.SessionID == h.SessionID && res.Ending == executor.EndFinish && !ev.Delivered {
			ev.Delivered, ev.Round = true, round
			if err := ev.persist(dir); err != nil {
				return Approved{}, err
			}
		}
		if err := b.Track(); err != nil {
			return Approved{}, err
		}
		if res.Ending == executor.EndNoCall {
			return Approved{}, executor.Fail(executor.ReasonProtocol, "the reviewer ended its round without a verdict")
		}
		verdict, problems, err := x.verdictOf(r, res.Structured)
		if err != nil {
			return Approved{}, err
		}
		if problems != nil {
			if invalid >= 1 {
				r.sess.Rejected = invalid
				return Approved{}, r.invalidStop(problems, "rejected_verdict_exhausted")
			}
			invalid++
			r.sess.Rejected = invalid
			r.allowance("rejected_verdict")
			// An external executor's structured verdict has no API-level tool choice to force: the
			// correction goes back as text only.
			b.Run.Event(map[string]any{
				"event": "review_tool_choice", "review": b.Review, "tool": agent.SubmitReviewTool, "mode": "text_fallback",
				"executor": x.desc.Name, "rejected_verdicts": r.sess.Rejected, "no_tool_reminders": r.sess.NoTool,
			})
			feedback = "Not a valid verdict: " + strings.Join(problems, "; ") + ". Submit a corrected structured verdict."
			continue
		}
		if verdict.Verdict == "approve" {
			// Before accepting an approval: the material it rests on was delivered completely in
			// a completed round of this session and its custody is unchanged.
			if !ev.Delivered || ev.Session != h.SessionID {
				return Approved{}, custodyInvalid("the review material was not completely delivered in a completed round of the reviewer session")
			}
			if err := ev.check(dir); err != nil {
				return Approved{}, err
			}
		}
		tree, err := b.repo.Tree(b.Start, b.Excluded)
		if err != nil {
			return Approved{}, err
		}
		approved, again, err := r.evaluate(ctx, *verdict, tree)
		if err != nil || !again {
			return approved, err
		}
		feedback = lastUserContent(r.sess.Input)
		r.sess.Input = nil
		// The reviewer's repairs changed the candidate: this review is no read-only boundary.
		r.sess.Mutating = true
		invalid = 0
	}
}

// verdictOf decodes the structured submission and validates it with the native verdict rules.
func (x reviewExternal) verdictOf(r *reviewRun, raw json.RawMessage) (*reviewVerdict, []string, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var args map[string]any
	if err := dec.Decode(&args); err != nil || args == nil {
		return nil, nil, executor.Fail(executor.ReasonProtocol, "the reviewer's structured output is not a JSON object")
	}
	return r.validate(args, nil)
}

func diagnosticText(item any) string {
	m, _ := item.(map[string]any)
	switch c := m["content"].(type) {
	case string:
		return c
	case []any:
		var parts []string
		for _, block := range c {
			if t, ok := materialText(block); ok {
				parts = append(parts, t)
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func lastUserContent(input []any) string {
	if len(input) == 0 {
		return ""
	}
	m, _ := input[len(input)-1].(map[string]any)
	s, _ := m["content"].(string)
	return s
}

func custodyInvalid(detail string) *sys.Error {
	return sys.Fail("candidate", "context_custody_invalid", detail+"; nothing was committed and custody is preserved", 1)
}

// writeReviewMaterial retains the exact outgoing bytes privately (0700 folder, 0600 files) and
// their identity before anything is sent.
func writeReviewMaterial(dir string, review int, tree, authority, source string, files []map[string]any) (*reviewMaterial, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	write := func(name, text string) (fileEvidence, error) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o600); err != nil {
			return fileEvidence{}, err
		}
		return fileEvidence{File: name, Bytes: len(text), SHA256: hashHex([]byte(text))}, nil
	}
	a, err := write(fmt.Sprintf("review-%d-authority.txt", review), authority)
	if err != nil {
		return nil, err
	}
	s, err := write(fmt.Sprintf("review-%d-source.txt", review), source)
	if err != nil {
		return nil, err
	}
	ev := &reviewMaterial{Review: review, Tree: tree, Authority: a, Source: s, Parts: nonNilAny(files)}
	return ev, ev.persist(dir)
}

func (e *reviewMaterial) persist(dir string) error {
	b, err := json.MarshalIndent(e, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, fmt.Sprintf("review-%d-material.json", e.Review)), append(b, '\n'), 0o600)
}

// check re-reads the retained bytes: missing, changed or unsafe custody stops safely.
func (e *reviewMaterial) check(dir string) error {
	for _, f := range []fileEvidence{e.Authority, e.Source} {
		path := filepath.Join(dir, f.File)
		st, err := os.Lstat(path)
		if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o077 != 0 {
			return custodyInvalid("the retained review material " + f.File + " is missing or unsafe")
		}
		data, err := os.ReadFile(path)
		if err != nil || len(data) != f.Bytes || hashHex(data) != f.SHA256 {
			return custodyInvalid("the retained review material " + f.File + " changed")
		}
	}
	return nil
}
