Feature: Native builder and reviewer shell calls are not stopped for being silent
  K-SILENCE-REVERT (ruling kogen-main, 31 Oct 2026, h04 review): revert rule 1 of
  K-HUNG-CHECK (kogen d42f6cc) and keep rule 2. Working commands are often silent for
  longer than 10 minutes: Studio's mix test ran 696-1158 s on the shared Macs, and
  Kogen's own go test ./... prints nothing until a package finishes.

  Scenario: The no-output shell watch is gone from Kogen's own code
    When silence revert collects Go sources under cli that mention the no-output shell watch
    Then silence revert source paths are "[]"
    And silence revert finds no file "cli/build/hungshell.go"
    And silence revert finds no file "cli/build/hungshell_test.go"

  Scenario: A silent native builder shell call returns its ordinary result and the Build lands
    Then the namedfeedback regression "TestSilentBuildShellNotStopped" runs exactly once and passes in "./build"

  Scenario: A silent independent reviewer shell call returns its ordinary result and the review reaches its verdict
    Then the namedfeedback regression "TestSilentReviewShellNotStopped" runs exactly once and passes in "./build"

  Scenario: LOOP-5 is back to its wording before the no-output stop
    Then silence revert finds the line starting "**LOOP-5 — Shell.**" in "spec/prose/04-building.md" is:
      """
      **LOOP-5 — Shell.** A `shell` call runs `/bin/sh -c <command>` in the repository root, in a new process group, with stdin closed (`/dev/null`), so a command that asks for input fails at once instead of waiting. Native shell calls in Build and independent Review have no time limit and no setting adds one; cancellation or interruption stops the run. The call returns when its `sh` process exits, with the exit status and the combined stdout and stderr (stderr included even when stdout is empty). A finite command, including a test or browser suite, runs in the foreground until completion even when it takes minutes; the tool waits without another model request. Do not poll such tests through repeated sleep/tail/ps calls. Only a persistent command — a dev server, a watch mode — is started by the builder in the background (`<command> > <log file> 2>&1 &`); the builder reads its log file and stops it (`kill`) with further `shell` calls. When the Build ends — commit, failure or Ctrl-C (CLI-7) — Kogen terminates the process groups of every command it started, background ones included.
      """

  Scenario: The removed shell time limit note is back to its wording before the no-output stop
    Then silence revert finds the section "## Removed shell time limit" of "docs/configuration.md" is:
      """
      The opt-in `tool_shell_timeout_seconds` option was removed. Native Build and
      independent Review shell calls have no time limit, and no setting adds one. A
      `.kogen/project.yaml` that still names the key is refused as an unknown key, not
      ignored or migrated; delete the line. There is no per-call model-shell limit.
      """

  Scenario: Rule 2 still stops a verification step with no live process whose result never arrives
    Then the namedfeedback regression "TestVerifyEndedCommandNoticed" runs exactly once and passes in "./verify"

  Scenario: Rule 2 still waits for a live but silent verification command
    Then the namedfeedback regression "TestVerifyLiveSilentCommandWaits" runs exactly once and passes in "./verify"

  Scenario: LOOP-11 keeps the rule 2 wording
    Then silence revert finds the line starting "**LOOP-11 — Environment.**" in "spec/prose/04-building.md" is:
      """
      **LOOP-11 — Environment.** Setup, `shell` calls, fixers, checks, the acceptance command and Quint run with stdin closed; these commands have no time limit (a project command whose process group has had no live process for 60 seconds while its result has not reached Kogen is no longer waited for: the Build stops with `environment/command_no_progress`, naming the step and command, and the run log records `command_no_progress` with rule `no_live_process`; a command with a live process is never stopped by this, however long it is silent), and run with the caller's environment unchanged except for the two acceptance variables of VER-3, plus `KOGEN_NODE` (the absolute path of Kogen's own Node, INS-4), `KOGEN_CUCUMBER` (the `node_modules` folder of the Cucumber Kogen ships, INS-2), which the acceptance commands of SET-10 use, and `KOGEN_QUINT` (Kogen's Quint `cli.js`, which a shaping probe runs with `KOGEN_NODE` to check a model before submitting, SHP-10); Kogen adds nothing else, and never its credentials. A real `shell` call of the installed default configuration succeeds.
      """
