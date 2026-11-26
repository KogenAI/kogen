Feature: Isolate the unclosed flow fixture
  This feature repairs only the input in cli/consumes/kogen-coordinator/config_test.go
  for TestParseConfigRefusalsAreSysErrorsWithLines/unclosed_flow. Nothing else in the
  source, Coordinator pin, YAML parsing, or qualification checks changes.

  Operational delivery is ordinary chatgpt-full because registered Claude Team
  reserve is closed; normal dispatch and capacity gates apply.

  After landing, Release/Recovery must run go test -count=1 ./consumes/kogen-coordinator
  from cli against the retained exact candidate pin b5b23ff5738a, with the landed
  one-line fix, and then run the normal full release gate without weakening it.
  The reported isolated passes on both pins do not satisfy that release obligation.

  Scenario: The Coordinator consumer package passes with an isolated unclosed sequence
    Then assembly-coordinator-unclosed-flow-fixture: go test -count=1 ./consumes/kogen-coordinator passes from cli and runs TestParseConfigRefusalsAreSysErrorsWithLines/unclosed_flow
    And assembly-coordinator-unclosed-flow-fixture: the tracked refusal case has this exact input and unchanged assertions
      """
      		{"unclosed flow", "version: 1\ncommands: [\n", []string{"line 2: unclosed ["}},
      	}
      	for _, c := range cases {
      		t.Run(c.name, func(t *testing.T) {
      			cfg, err := project.ParseConfig(c.text, "project.yaml")
      			if err == nil || cfg != nil {
      				t.Fatalf("ParseConfig = %+v, %v; want an error", cfg, err)
      			}
      			e, ok := sys.AsError(err)
      			if !ok {
      				t.Fatalf("error %v (%T), want *sys.Error", err, err)
      			}
      			if e.Detail != "project.yaml" || e.Exit != 3 || !slices.Equal(e.Lines, c.lines) {
      				t.Fatalf("Detail %q, Exit %d, Lines %q; want project.yaml, 3, %q", e.Detail, e.Exit, e.Lines, c.lines)
      			}
      			if want := "environment/project_config_invalid: project.yaml\n  " + strings.Join(c.lines, "\n  ") + "\n"; e.Render() != want {
      				t.Fatalf("Render = %q, want %q", e.Render(), want)
      			}
      		})
      	}
      }
      """
