Feature: Reject empty values for path options
  This feature checks that the Kogen command-line parser refuses an empty value for --project, --context and --output and keeps nonempty values working.

  Scenario: Parsing an empty project option is refused
    When reject-empty-cli-option-values: kogen parses "intent shape demo request.md --project="
    Then reject-empty-cli-option-values: the parse is refused with a usage error that names "--project" and says the value is empty

  Scenario: An empty separate project value is refused
    When reject-empty-cli-option-values: kogen parses "intent resume build-1 --project ''"
    Then reject-empty-cli-option-values: the parse is refused with a usage error that names "--project" and says the value is empty

  Scenario: Parsing an empty context option is refused
    When reject-empty-cli-option-values: kogen parses "intent build demo --context="
    Then reject-empty-cli-option-values: the parse is refused with a usage error that names "--context" and says the value is empty

  Scenario: Parsing an empty output option is refused
    When reject-empty-cli-option-values: kogen parses "intent recover build-1 --output="
    Then reject-empty-cli-option-values: the parse is refused with a usage error that names "--output" and says the value is empty

  Scenario: Recover without an output option keeps its required-output error
    When reject-empty-cli-option-values: kogen parses "intent recover build-1"
    Then reject-empty-cli-option-values: the usage error is exactly "kogen intent recover: missing --output <directory>"

  Scenario: Nonempty equals-form values populate the options
    When reject-empty-cli-option-values: kogen parses "intent build demo --project=/work/repo --context=/tmp/ctx.json"
    Then reject-empty-cli-option-values: the parse succeeds
    And reject-empty-cli-option-values: the parsed project is "/work/repo"
    And reject-empty-cli-option-values: the parsed context is "/tmp/ctx.json"

  Scenario: Nonempty separate values populate the options
    When reject-empty-cli-option-values: kogen parses "intent build demo --project /work/repo --context /tmp/ctx.json"
    Then reject-empty-cli-option-values: the parse succeeds
    And reject-empty-cli-option-values: the parsed project is "/work/repo"
    And reject-empty-cli-option-values: the parsed context is "/tmp/ctx.json"

  Scenario: Nonempty recover output populates the option in both forms
    When reject-empty-cli-option-values: kogen parses "intent recover build-1 --output=/tmp/out"
    Then reject-empty-cli-option-values: the parse succeeds
    And reject-empty-cli-option-values: the parsed output is "/tmp/out"
    When reject-empty-cli-option-values: kogen parses "intent recover build-1 --output /tmp/out2"
    Then reject-empty-cli-option-values: the parse succeeds
    And reject-empty-cli-option-values: the parsed output is "/tmp/out2"
