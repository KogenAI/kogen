package project

import (
	"strings"
	"testing"
)

func TestYAMLBlockScalarsKeepCommasAndLines(t *testing.T) {
	// ExUnit: SET-4 / SET-8: block command scalars preserve commas and YAML source lines
	node, problems := parseYAML("version: 1\ncommands:\n  checks:\n    - name: test\n      run: python3 -c \"print(1, 2)\"\n")
	if node == nil {
		t.Fatal(problems)
	}
	if node.kind != kindMap || node.line != 1 {
		t.Fatalf("root %+v", node)
	}
	commands := node.pairs[1]
	if commands.key != "commands" || commands.line != 2 || commands.node.kind != kindMap || commands.node.line != 3 {
		t.Fatalf("commands %+v", commands)
	}
	checks := commands.node.pairs[0]
	if checks.key != "checks" || checks.line != 3 || checks.node.kind != kindSeq || checks.node.line != 4 || len(checks.node.items) != 1 {
		t.Fatalf("checks %+v", checks)
	}
	check := checks.node.items[0]
	if check.kind != kindMap || check.line != 4 {
		t.Fatalf("check %+v", check)
	}
	run := check.pairs[1]
	if run.key != "run" || run.line != 5 || run.node.line != 5 || run.node.quoted || run.node.text != `python3 -c "print(1, 2)"` {
		t.Fatalf("run %+v %+v", run, run.node)
	}
}

func TestYAMLDuplicateKeyReportsRepeatLine(t *testing.T) {
	// ExUnit: SET-4: a duplicate YAML key reports the line where it is repeated
	node, problems := parseYAML("version: 1\ncommands:\n  acceptance:\n    run: first\n    run: second\n")
	if node != nil || len(problems) != 1 || problems[0] != (problem{5, "duplicate key run"}) {
		t.Fatalf("got %v %v", node, problems)
	}
}

func TestYAMLProblems(t *testing.T) {
	cases := []struct {
		name, text string
		line       int
		msg        string
	}{
		{"empty", "", 1, "the file is empty"},
		{"only comments", "# a\n  \n", 1, "the file is empty"},
		{"stray indent", "a: 1\n  b: 2\n", 2, "unexpected indentation"},
		{"dedent into nothing", "a:\n    b: 1\n  c: 2\n", 3, "unexpected indentation"},
		{"no colon", "a: 1\nb\n", 2, "expected key: value"},
		{"key without space", "a:b\n", 1, "expected key: value"},
		{"dash without space", "a:\n  -b\n", 2, "expected a space after -"},
		{"seq item continuation", "a:\n  - x\n    y\n", 3, "unexpected indentation"},
		{"duplicate", "a: 1\na: 2\n", 2, "duplicate key a"},
		{"duplicate in flow map", "a: {b: 1, b: 2}\n", 1, "duplicate key b"},
		{"unclosed seq", "a: [1, 2\n", 1, "unclosed ["},
		{"unclosed map", "a: {b: 1\n", 1, "unclosed {"},
		{"flow pair without key", "a: {b}\n", 1, "expected key: value in {...}"},
		{"unclosed quote", "a: \"x\n", 1, "unclosed quote"},
		{"unclosed single quote", "a: 'x\n", 1, "unclosed quote"},
		{"unknown escape", "a: \"x\\q\"\n", 1, `unknown escape \q`},
		{"text after quote", "a: \"x\" y\n", 1, "unexpected text y"},
		{"block scalar", "a: |\n", 1, "unsupported YAML: |; use a quoted string"},
		{"block scalar with body", "a: |\n  x\n", 2, "unexpected indentation"},
		{"anchor", "a: &x y\n", 1, "unsupported YAML: &x y; use a quoted string"},
		{"tag", "a: !t y\n", 1, "unsupported YAML: !t y; use a quoted string"},
		{"alias in flow", "a: [*x]\n", 1, "unsupported YAML: *x; use a quoted string"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			node, problems := parseYAML(c.text)
			if node != nil || len(problems) != 1 || problems[0].line != c.line || problems[0].msg != c.msg {
				t.Fatalf("got %v %v, want line %d %q", node, problems, c.line, c.msg)
			}
		})
	}
}

func TestYAMLScalars(t *testing.T) {
	node, problems := parseYAML("plain: some text, with [brackets] # comment\nq1: \"a \\\"b\\\" \\n c\"\nq2: 'it''s # not a comment'\nn1: null\nn2: ~\nn3:\nflow: [a, 'b', \"c\", null, {k: v}]\n")
	if node == nil {
		t.Fatal(problems)
	}
	want := map[string]string{
		"plain": "some text, with [brackets]",
		"q1":    "a \"b\" \n c",
		"q2":    "it's # not a comment",
	}
	for _, p := range node.pairs {
		if w, ok := want[p.key]; ok && p.node.text != w {
			t.Errorf("%s = %q, want %q", p.key, p.node.text, w)
		}
		switch p.key {
		case "n1", "n2", "n3":
			if !p.node.null {
				t.Errorf("%s is not null", p.key)
			}
		case "q1", "q2":
			if !p.node.quoted {
				t.Errorf("%s is not quoted", p.key)
			}
		case "flow":
			if p.node.kind != kindSeq || len(p.node.items) != 5 || !p.node.items[3].null || p.node.items[4].kind != kindMap {
				t.Errorf("flow = %+v", p.node)
			}
		}
	}
}

func TestYAMLSequenceAtKeyIndent(t *testing.T) {
	node, problems := parseYAML("a:\n- x\n- y\nb: 1\n")
	if node == nil {
		t.Fatal(problems)
	}
	if got := node.pairs[0].node; got.kind != kindSeq || len(got.items) != 2 || node.pairs[1].key != "b" {
		t.Fatalf("got %+v", node)
	}
}

func TestStripComment(t *testing.T) {
	for in, want := range map[string]string{
		"a: b # c":        "a: b",
		"a: b#c":          "a: b#c",
		"a: 'b # c' # d":  "a: 'b # c'",
		"# only":          "",
		"a: \"b #\" #":    "a: \"b #\"",
		"a:\tb\t# c":      "a:\tb",
		"it's # a quote'": "it's # a quote'",
	} {
		if got := stripComment(strings.TrimRight(in, " ")); got != want {
			t.Errorf("stripComment(%q) = %q, want %q", in, got, want)
		}
	}
}
