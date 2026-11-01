package shape

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

func TestExamplesRevertShapeApproval(t *testing.T) {
	const feature = `Feature: Formatting output
  Scenario Outline: Formatted output
    Given the derived value <derived>
    Then the output is <expected>
    Examples:
      | expected                    | derived                         |
      | "status":0,"out":"61610a0a" | {"status":0,"out":"61610a0a"} |
`
	const steps = `const {Given, Then} = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
Given(/^the derived value (.*)$/, function (value) { this.value = value; });
Then(/^the output is (.*)$/, function (expected) { assert.equal(require('../../calc').format(this.value), expected); });
`
	files := shpFiles()
	list := files["files"].([]any)
	list[0].(map[string]any)["content"] = strings.Replace(shpIntentMD, "calc.is_even(n) returns True for even integers.", "Formatting produces the requested output for the given value.", 1)
	list[1].(map[string]any)["content"] = feature
	list[2].(map[string]any)["content"] = steps
	ack := shpSubmit("ack", map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": feature}}})
	f := newShpFx(t, shpSubmit("submit", files), ack)
	f.Prov.route = func(req map[string]any) *shpStep {
		if strings.Contains(shpBody(req), "submit_example_check") {
			return &shpStep{status: 400, code: "unexpected_example_check"}
		}
		return nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	modules := filepath.Join(cwd, "..", "..", "test", "acceptance", "node_modules")
	runner := filepath.Join(modules, "@cucumber/cucumber/bin/cucumber.js")
	f.write("features/steps/calc_steps.js", "// existing steps\n")
	f.write("calc.js", "exports.format = () => '';\n")
	f.write("accept.sh", fmt.Sprintf("#!/bin/sh\necho run >> '%s/trace'\ncase \"$KOGEN_ACCEPTANCE_FEATURES\" in */check.feature) : > \"$KOGEN_ACCEPTANCE_REPORT\"; exit 0;; esac\nNODE_PATH='%s' node '%s' --strict --require 'features/steps/*.js' --format \"message:$KOGEN_ACCEPTANCE_REPORT\" $KOGEN_ACCEPTANCE_FEATURES\n", f.Aux, modules, runner))
	f.git("add", "-A")
	f.git("commit", "-qm", "prepare missing format feature")
	exit, err := f.shape("Add the requested format output.")
	if err != nil || exit != 0 {
		t.Fatalf("shape: %d %v\n%s\n%s\n%v", exit, err, f.Stdout, f.Stderr, f.Prov.requests())
	}
	if f.runs() < 2 {
		t.Fatal("readiness did not run")
	}
	for _, r := range f.Prov.requests() {
		if strings.Contains(shpBody(r), "submit_example_check") {
			t.Fatal("unexpected example check request")
		}
	}
	for _, e := range f.events() {
		if e["event"] == "example_check" || (e["event"] == "submission_refused" && e["gate"] == "example_check") {
			t.Fatalf("unexpected event %v", e)
		}
	}
	record := ".kogen/local/shaping/is-even/example-contradictions.json"
	if f.exists(record) {
		t.Fatal("new contradiction record")
	}
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := project.Baseline(f.Root, shpSlug, cfg)
	if err != nil {
		t.Fatal(err)
	}
	hash := project.Hash(f.Root, baseline)
	f.write(record, fmt.Sprintf(`{"sha256":%q,"lines":["legacy contradiction"]}`, hash))
	for _, h := range []string{"", hash} {
		f.newSession()
		code, err := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Hash: h})
		want := 5
		if h != "" {
			want = 0
		}
		if err != nil || code != want || strings.Contains(f.Stdout.String()+f.Stderr.String(), "examples_contradict") {
			t.Fatalf("approve %q: %d %v\n%s\n%s", h, code, err, f.Stdout, f.Stderr)
		}
		if h == "" && (!strings.Contains(f.Stdout.String(), hash) || !strings.Contains(f.Stdout.String(), "fails now")) {
			t.Fatalf("card missing hash: %s", f.Stdout)
		}
	}
	if !f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("missing approval marker")
	}
}
