Feature: Distinguish missing configuration from read errors
  This feature preserves the missing, valid and line-specific malformed reports
  while correcting the existing-directory failure from evidence ev-f796440d.

  Scenario: Preserve missing config guidance
    Given readiness-config-read-errors: a project whose config path is "missing"
    When readiness-config-read-errors: the readiness report is produced
    Then readiness-config-read-errors: the config report is:
      """json
      {"Check":{"Check":"config","Status":"fail","Detail":".kogen/project.yaml is missing","Fix":"in your project, run kogen init"},"Text":"fail config - .kogen/project.yaml is missing\n  fix: in your project, run kogen init\n"}
      """

  Scenario: Report an existing directory as a read failure
    Given readiness-config-read-errors: a project whose config path is "directory"
    When readiness-config-read-errors: the readiness report is produced
    Then readiness-config-read-errors: the existing directory at ".kogen/project.yaml" is reported as unreadable with a file repair instead of init

  Scenario: Preserve valid config reporting
    Given readiness-config-read-errors: a project whose config path is "missing"
    And readiness-config-read-errors: the config file contains:
      """yaml
      version: 1
      """
    When readiness-config-read-errors: the readiness report is produced
    Then readiness-config-read-errors: the config report is:
      """json
      {"Check":{"Check":"config","Status":"ok","Detail":".kogen/project.yaml is valid","Fix":""},"Text":"ok config - .kogen/project.yaml is valid\n"}
      """

  Scenario: Preserve line-specific malformed config reporting
    Given readiness-config-read-errors: a project whose config path is "missing"
    And readiness-config-read-errors: the config file contains:
      """yaml
      version: 1
      commands: [
      """
    When readiness-config-read-errors: the readiness report is produced
    Then readiness-config-read-errors: the config report is:
      """json
      {"Check":{"Check":"config","Status":"fail","Detail":"line 2: unclosed [","Fix":"edit .kogen/project.yaml at line 2"},"Text":"fail config - line 2: unclosed [\n  fix: edit .kogen/project.yaml at line 2\n"}
      """
