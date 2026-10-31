package shape

import (
	"context"
	"fmt"
	"kogen/executor"
	"testing"
)

func retryShape(t *testing.T, limit, invalid int, success bool) {
	t.Helper()
	both := map[string]any{"questions": []any{shpQuestion("Q?")}, "files": shpFiles()["files"]}
	var steps []shpStep
	for i := 0; i < invalid; i++ {
		steps = append(steps, shpSubmit(fmt.Sprint(i), both))
	}
	if success {
		steps = append(steps, shpSubmit("valid", shpFiles()), shpAck("ack"))
	}
	f := newShpFx(t, steps...)
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client, SubmissionRetryLimit: limit})
	if success {
		if err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		shpEq(t, "published", f.read(refIntentPath), shpIntentMD)
		shpEq(t, "requests", len(f.Prov.requests()), invalid+2)
	} else {
		effective := submissionRetryLimit(limit)
		e := shpWantError(t, err, "shape", "invalid_output", "", 1)
		shpEq(t, "detail", e.Detail, fmt.Sprintf("the shaper's output was not a valid Intent after %d attempts", effective))
		shpEq(t, "exit", exit, 1)
		shpEq(t, "requests", len(f.Prov.requests()), effective)
		shapeAbsent(t, f)
	}
	events := shpNamed(f.events(), "submission_retry_limit")
	effective := submissionRetryLimit(limit)
	if effective == 3 {
		shpEq(t, "events", len(events), 0)
	} else {
		shpEq(t, "events", len(events), 1)
		shpEq(t, "limit", events[0]["limit"], any(float64(effective)))
	}
}
func TestSubmissionRetryDefault(t *testing.T) {
	parallel(t)
	retryShape(t, 0, 2, true)
	retryShape(t, 0, 3, false)
}
func TestSubmissionRetryOne(t *testing.T) {
	parallel(t)
	retryShape(t, 1, 1, false)
	t.Run("title fallback", func(t *testing.T) {
		parallel(t)
		const long = "Add an is-even check for integers and also reject every string"
		f := newShpFx(t, shpSubmit("one", shpTitled(long, "")))
		f.setReport("PASSED", 0)
		f.newSession()
		exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client, SubmissionRetryLimit: 1})
		if err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		shpEq(t, "requests", len(f.Prov.requests()), 1)
		shpEq(t, "title events", len(shpNamed(f.events(), "title_shortened")), 1)
	})
	t.Run("audit fallback", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t)
		f.useExternalShape(6)
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
		f.git("add", ".kogen/project.yaml")
		f.git("commit", "-qm", "audit")
		f.setReport("PASSED", 0)
		audit := map[string]any{"examples": []any{map[string]any{"quote": "QA"}}, "rules": []any{map[string]any{"quote": "QB"}}, "cells": []any{map[string]any{"example": 0, "rule": 0, "result": "conflicts"}}, "defects": []any{map[string]any{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "is_even(0)", "result_a": "True", "result_b": "False"}}}
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(audit), result(shpFiles())}}
		f.newSession()
		exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n). QA QB", External: x.external(), SubmissionRetryLimit: 1})
		if err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		shpEq(t, "rounds", x.calls, 2)
		shpEq(t, "published", f.read(refIntentPath), shpIntentMD)
		ev := shpNamed(f.events(), "request_audit")
		if len(ev) != 2 {
			t.Fatalf("audit events: %v", ev)
		}
		if u, ok := ev[1]["uncovered"].([]any); !ok || len(u) != 1 {
			t.Fatalf("uncovered: %v", ev[1])
		}
	})
	t.Run("decision fallback", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t)
		f.useExternalShape(6)
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_decision_check:\n  enabled: true\n")
		f.git("add", ".kogen/project.yaml")
		f.git("commit", "-qm", "decision")
		f.setReport("PASSED", 0)
		check := map[string]any{"items": []any{map[string]any{"statement": "- Non-integers raise TypeError. (source: request)", "request_quotes": []any{}, "verdict": "unsupported", "why": "not stated"}}}
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(shpFiles()), result(check)}}
		f.newSession()
		exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", External: x.external(), SubmissionRetryLimit: 1})
		if err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		shpEq(t, "rounds", x.calls, 2)
		shpContains(t, "published assumption", f.read(refIntentPath), "(assumption: not stated) (source: request)")
		shpEq(t, "assumption events", len(shpNamed(f.events(), "decision_assumptions_marked")), 1)
	})

}
func TestSubmissionRetryFive(t *testing.T) {
	parallel(t)
	retryShape(t, 5, 4, true)
	retryShape(t, 5, 5, false)
}
func TestSubmissionRetryEvidence(t *testing.T) {
	parallel(t)
	for _, n := range []int{0, 3, 1, 5, -1} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			parallel(t)
			retryShape(t, n, submissionRetryLimit(n), false)
		})
	}
}
func TestSubmissionRetryRefine(t *testing.T) {
	parallel(t)
	for _, n := range []int{0, 1, 3, 5} {
		for _, success := range []bool{false, true} {
			t.Run(fmt.Sprintf("%d/%v", n, success), func(t *testing.T) {
				parallel(t)
				limit := submissionRetryLimit(n)
				count := limit
				if success {
					count--
				}
				var steps []shpStep
				for i := 0; i < count; i++ {
					steps = append(steps, shpAnswer(shpCall(fmt.Sprint("i", i), "submit_refinement", map[string]any{"files": []any{}})))
				}
				if success {
					steps = append(steps, refSubmit("valid", refIntentPath, refTitled))
				}
				f := newRefFx(t, refOpts{}, steps...)
				before := f.pkg()
				f.newSession()
				exit, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0, Request: "Clarify existing draft", Client: f.Client, SubmissionRetryLimit: n})
				if success {
					if err != nil || exit != 0 {
						t.Fatalf("exit %d: %v", exit, err)
					}
					refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
				} else {
					e := shpWantError(t, err, "shape", "refinement_invalid", "", 1)
					shpEq(t, "detail", e.Detail, fmt.Sprintf("no valid ready correction after %d submissions; the original draft is preserved", limit))
					refEqual(t, "preserved", f.pkg(), before)
				}
				shpEq(t, "requests", len(f.Prov.requests()), count+boolInt(success))
				ev := shpNamed(f.evidenceEvents(), "submission_retry_limit")
				if limit == 3 {
					shpEq(t, "events", len(ev), 0)
				} else {
					shpEq(t, "events", len(ev), 1)
					shpEq(t, "limit", ev[0]["limit"], any(float64(limit)))
				}
			})
		}
	}
}
func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
func TestSubmissionRetryExternal(t *testing.T) {
	parallel(t)
	both := map[string]any{"questions": []any{shpQuestion("Q?")}, "files": shpFiles()["files"]}
	t.Run("shape", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t)
		f.useExternalShape(6)
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(both)}}
		f.newSession()
		_, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "x", External: x.external(), SubmissionRetryLimit: 1})
		shpWantError(t, err, "shape", "invalid_output", "after 1 attempts", 1)
		shpEq(t, "rounds", x.calls, 1)
		shapeAbsent(t, f)
	})
	t.Run("refine", func(t *testing.T) {
		parallel(t)
		f := newRefFx(t, refOpts{external: 6})
		before := f.pkg()
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(map[string]any{"files": []any{}})}}
		f.newSession()
		_, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0, Request: "x", External: x.external(), SubmissionRetryLimit: 1})
		shpWantError(t, err, "shape", "refinement_invalid", "after 1 submissions", 1)
		shpEq(t, "rounds", x.calls, 1)
		refEqual(t, "preserved", f.pkg(), before)
	})
}
