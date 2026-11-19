Feature: Read commands name the refused argument
  This feature runs the real command entry of kogen with wrong arguments of the read-only commands and checks the error detail of the one JSON answer.

  Scenario: An unknown option on inspect is named without its value
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent inspect --bogus=1 0a1b2c3d"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent inspect: unknown option '--bogus'"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: A project option without a value is named
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent list --project"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent list: --project needs a value"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: The cursor option is unknown on context
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "context --cursor=x"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen context: unknown option '--cursor'"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: An extra positional on list is named
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent list extra"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent list: unexpected argument 'extra'"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: The second run id of inspect is the unexpected one
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent inspect --project <project> 0a1b2c3d 1a1b2c3d"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent inspect: unexpected argument '1a1b2c3d'"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: Inspect without a run id says so
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent inspect --project <project>"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent inspect: missing the run id"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: Preflight without a slug says so
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent preflight --project <project>"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent preflight: missing the slug"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: An invalid slug is explained
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent preflight --project <project> Is_Even"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent preflight: the slug must be 3 to 48 characters and use lowercase letters, digits and dashes"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: A zero limit on list is refused with the range
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent list --limit 0"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent list: --limit must be a whole number from 1 to 100"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: A limit that is not a number on list is refused with the range
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent list --limit x"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent list: --limit must be a whole number from 1 to 100"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: A limit above 100 on usage is refused with the range
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent usage --limit 101"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent usage: --limit must be a whole number from 1 to 100"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: A bad cursor is refused after the project lookup
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent list --project <project> --cursor=x"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent list: --cursor is not a cursor of the current list"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: Lineage without a run id is refused
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent usage --lineage"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent usage: --lineage needs a run id"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: The first unknown group-by field is named
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent usage --group-by phase,bogus"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent usage: --group-by field 'bogus' is unknown (fields: project, slug, lineage, phase, role, model, effective-model, effort, effective-effort, outcome, pass, repair)"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: A since value that is not UTC is refused with the option name
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent usage --since 2026-11-16"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent usage: --since must be a UTC time such as 2026-11-16T00:00:00Z"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: An until value that is not UTC is refused with its own name
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent usage --until 2026-11-16"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent usage: --until must be a UTC time such as 2026-11-16T00:00:00Z"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: An option problem is reported before an extra positional
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent usage extra --bogus"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent usage: unknown option '--bogus'"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths

  Scenario: A bad positional on usage is named
    Given read-command-usage-errors-name-the-argument: the kogen command line package builds for the acceptance probe
    When read-command-usage-errors-name-the-argument: kogen is run with the words "intent usage extra"
    Then read-command-usage-errors-name-the-argument: the error detail is exactly "kogen intent usage: unexpected argument 'extra'"
    And read-command-usage-errors-name-the-argument: the exit code is 2 and the error has only the class intent, the reason invalid_argument, the detail and no paths
