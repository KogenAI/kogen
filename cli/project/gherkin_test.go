package project

import (
	"slices"
	"strconv"
	"testing"
)

func scenarioNames(ss []Scenario) []string {
	var out []string
	for _, s := range ss {
		out = append(out, s.Name)
	}
	return out
}

func stepTexts(s Scenario) []string {
	var out []string
	for _, st := range s.Steps {
		out = append(out, st.Text)
	}
	return out
}

func hasThen(s Scenario) bool {
	return slices.ContainsFunc(s.Steps, func(st Step) bool { return st.Keyword == "Then " })
}

func TestGherkinScenariosExposeReportLines(t *testing.T) {
	// ExUnit: VER-3 / VER-4 / SHP-5: scenarios expose their report lines, inherited steps, tags, and Then steps
	feature := `@feature-tag
Feature: Accounting
  Background:
    Given the project is ready

  @rule-tag
  Rule: an example rule
    Background:
      And the rule is active

    @scenario-tag
    Scenario: ordinary scenario
      When the action runs
      Then the result is visible

    Scenario Outline: value <value>
      When the value is <value>
      Then it is accepted
      @example-tag
      Examples:
        | value |
        | first |
        | second |
`
	scenarios, err := ParseGherkin(feature)
	if err != nil {
		t.Fatal(err)
	}
	type nl struct {
		name string
		line int
	}
	var got []nl
	for _, s := range scenarios {
		got = append(got, nl{s.Name, s.Line})
	}
	want := []nl{{"ordinary scenario", 12}, {"value first", 22}, {"value second", 23}}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	ordinary, first, second := scenarios[0], scenarios[1], scenarios[2]
	if !slices.Equal(ordinary.Tags, []string{"@feature-tag", "@rule-tag", "@scenario-tag"}) {
		t.Errorf("ordinary tags %v", ordinary.Tags)
	}
	if want := []string{"the project is ready", "the rule is active", "the action runs", "the result is visible"}; !slices.Equal(stepTexts(ordinary), want) {
		t.Errorf("ordinary steps %v", stepTexts(ordinary))
	}
	if !slices.Equal(first.Tags, []string{"@feature-tag", "@rule-tag", "@example-tag"}) {
		t.Errorf("first tags %v", first.Tags)
	}
	if !hasThen(first) || !hasThen(second) {
		t.Error("outline examples lack their Then step")
	}
	if want := []string{"the project is ready", "the rule is active", "the value is first", "it is accepted"}; !slices.Equal(stepTexts(first), want) {
		t.Errorf("first steps %v", stepTexts(first))
	}
	if first.Outline == nil || *first.Outline != (Outline{Name: "value <value>", Line: 16, Examples: 2}) || ordinary.Outline != nil {
		t.Errorf("outline %+v", first.Outline)
	}
}

func TestGherkinMalformedOutlineReturnsLineProblem(t *testing.T) {
	// ExUnit: SHP-5: malformed outline structure returns a source-line problem
	_, err := ParseGherkin("Feature: Invalid\n  Scenario: ordinary\n  Examples:\n")
	ge, ok := err.(*GherkinError)
	if !ok || ge.Line != 3 || ge.Message != "Examples: belongs to a Scenario Outline" {
		t.Fatalf("got %v", err)
	}
	if ge.Error() != "line 3: Examples: belongs to a Scenario Outline" {
		t.Errorf("Error() = %q", ge.Error())
	}
}

func TestGherkinProblems(t *testing.T) {
	cases := []struct {
		name, text string
		line       int
		msg        string
	}{
		{"empty", "", 1, "the file has no Feature:"},
		{"comment only", "# nothing\n", 1, "the file has no Feature:"},
		{"tags only", "@a\n", 1, "the file has no Feature:"},
		{"not a feature", "Scenario: s\n  Then x\n", 1, "expected Feature:, got: Scenario: s"},
		{"tag without at", "Feature: A\n  @a #c\n  @a b\n  Scenario: s\n", 3, "a tag must start with @: b"},
		{"stray text in scenario", "Feature: A\n  Scenario: s\n    Then x\n  stray words\n", 4, "unexpected text: stray words"},
		{"step before scenario", "Feature: A\n  Then x\n", 2, "a step must belong to a Scenario or Background: Then x"},
		{"step after examples", "Feature: A\n  Scenario Outline: o\n    Examples:\n      | a |\n      | 1 |\n    Then late\n", 6, "a step must belong to a Scenario or Background: Then late"},
		{"examples in scenario", "Feature: A\n  Scenario: s\n    Then x\n    Examples:\n", 4, "Examples: belongs to a Scenario Outline"},
		{"examples before scenario", "Feature: A\n  Examples:\n", 2, "Examples: belongs to a Scenario Outline"},
		{"outline without rows", "Feature: A\n  Scenario Outline: o\n    Then x\n    Examples:\n      | a |\n", 2, "Scenario Outline o has no Examples rows"},
		{"outline without examples", "Feature: A\n  Scenario Template: t\n    Then x\n", 2, "Scenario Outline t has no Examples rows"},
		{"row width", "Feature: A\n  Scenario Outline: o\n    Then x\n    Examples:\n      | a | b |\n      | 1 |\n", 6, "this row has 1 cells, the header 2"},
		{"row without end", "Feature: A\n  Scenario: s\n    Then x\n      | a |\n      | b\n", 5, "a table row must end with |"},
		{"table in description", "Feature: A\n  Scenario: s\n    | a |\n", 3, "a table must follow a step or Examples:"},
		{"table before scenario", "Feature: A\n  | a |\n", 2, "a table must follow a step or Examples:"},
		{"doc string without step", "Feature: A\n  Scenario: s\n    \"\"\"\n    x\n    \"\"\"\n", 3, "a doc string must follow a step"},
		{"doc string not closed", "Feature: A\n  Scenario: s\n    Then x\n      ```\n      open\n", 4, "the doc string is not closed"},
		{"keyword without space", "Feature: A\n  Scenario: s\n    Then x\n    Thenx\n", 4, "unexpected text: Thenx"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ParseGherkin(c.text)
			ge, ok := err.(*GherkinError)
			if !ok || ge.Line != c.line || ge.Message != c.msg {
				t.Fatalf("got %v, want line %d %q", err, c.line, c.msg)
			}
		})
	}
}

func TestGherkinRules(t *testing.T) {
	cases := []struct {
		name, text string
		want       []string // "name|line|steps joined by /|tags joined by ,"
	}{
		{"keywords and star", "Feature: A\n  Example: e\n    * star\n    But not\n    Then x\n", []string{"e|2|star/not/x|"}},
		{"feature background applies to all", "Feature: A\n  Background:\n    Given bg\n  Scenario: a\n    Then x\n  Scenario: b\n    Then y\n", []string{"a|4|bg/x|", "b|6|bg/y|"}},
		{"background after first scenario applies to the later ones", "Feature: A\n  Scenario: a\n    Then x\n  Background:\n    Given late\n  Scenario: b\n    Then y\n", []string{"a|2|x|", "b|6|late/y|"}},
		{"rule background is for its rule", "Feature: A\n  Rule: r1\n    Background:\n      Given rbg\n    Scenario: a\n      Then x\n  Rule: r2\n    Scenario: b\n      Then y\n", []string{"a|5|rbg/x|", "b|8|y|"}},
		{"rule tags end with the rule's scenarios only by in_rule", "@f\nFeature: A\n  @r\n  Rule: r\n    @s\n    Scenario: a\n      Then x\n", []string{"a|6|x|@f,@r,@s"}},
		{"tag comments", "Feature: A\n  @a @b # @c\n  Scenario: s\n    Then x\n", []string{"s|3|x|@a,@b"}},
		{"doc strings hide their content", "Feature: A\n  Scenario: s\n    Then x\n      \"\"\"\n      Given not a step\n      \"\"\"\n    And y\n", []string{"s|2|x/y|"}},
		{"backtick doc strings", "Feature: A\n  Scenario: s\n    Then x\n      ```json\n      | no table\n      ```\n", []string{"s|2|x|"}},
		{"tables after steps are skipped", "Feature: A\n  Scenario: s\n    Given rows\n      | a | b\\|c |\n      | 1 | 2 |\n    Then x\n", []string{"s|2|rows/x|"}},
		{"outline placeholders replace in order", "Feature: A\n  Scenario Outline: o <a>\n    Then <a><b>\n    Examples:\n      | a | b |\n      | 1 | <a> |\n", []string{"o 1|6|1<a>|"}},
		{"outline examples with their own tags", "Feature: A\n  Scenario Outline: o <n>\n    Then x\n    @one\n    Examples:\n      | n |\n      | 1 |\n    @two\n    Examples:\n      | n |\n      | 2 |\n", []string{"o 1|7|x|@one", "o 2|11|x|@two"}},
		{"crlf line endings", "Feature: A\r\n  Scenario: s\r\n    Given a\r\n    Then b\r\n", []string{"s|2|a/b|"}},
		{"description text is ignored", "Feature: A\n  free text\n  Scenario: s\n    more text\n    Then x\n", []string{"s|3|x|"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			scenarios, err := ParseGherkin(c.text)
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, s := range scenarios {
				steps := ""
				for i, st := range s.Steps {
					if i > 0 {
						steps += "/"
					}
					steps += st.Text
				}
				tags := ""
				for i, tg := range s.Tags {
					if i > 0 {
						tags += ","
					}
					tags += tg
				}
				got = append(got, s.Name+"|"+strconv.Itoa(s.Line)+"|"+steps+"|"+tags)
			}
			if !slices.Equal(got, c.want) {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}
