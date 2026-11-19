Feature: Kogen follows Claude Code's native distribution once a version passes its hook self-test
  This feature runs the shipped Kogen against a loopback origin that serves latest, manifests and scripted candidate runtimes.

  Background:
    Given claude-code-daily-update-after-hook-self-test: a user with Kogen's pinned Claude Code 2.1.318 installed, a saved Claude Code token and two fixture Intents

  Scenario: A candidate whose hooks work becomes active and runs the next Build
    Given claude-code-daily-update-after-hook-self-test: the origin announces "2.1.319" and serves a candidate that "works"
    And claude-code-daily-update-after-hook-self-test: I note the state of the 2.1.318 directory
    When claude-code-daily-update-after-hook-self-test: I run kogen provider update claude-code
    Then claude-code-daily-update-after-hook-self-test: the update output has the line "kogen: Claude Code 2.1.319 passed Kogen's hook self-test; now active (was 2.1.318)"
    And claude-code-daily-update-after-hook-self-test: the candidate ran its self-test with the real argument list and its own throwaway sign-in
    And claude-code-daily-update-after-hook-self-test: the active version is "2.1.319"
    And claude-code-daily-update-after-hook-self-test: the 2.1.318 directory is unchanged
    When claude-code-daily-update-after-hook-self-test: I build the "first" fixture Intent
    Then claude-code-daily-update-after-hook-self-test: the Build landed and its Claude Code roles ran ".kogen/claude-code/2.1.319/claude"
    And claude-code-daily-update-after-hook-self-test: the Build result says claude_code_version "2.1.319" and claude_code_source "updated"
    When claude-code-daily-update-after-hook-self-test: I list the providers with kogen provider list
    Then claude-code-daily-update-after-hook-self-test: the provider list has the line "claude-code runtime: Claude Code 2.1.319 installed (<home>/.kogen/claude-code/2.1.319/claude)"

  Scenario: A candidate that never runs the hook for guarded writes is refused and not downloaded again
    Given claude-code-daily-update-after-hook-self-test: the origin announces "2.1.319" and serves a candidate that "skips-hook"
    When claude-code-daily-update-after-hook-self-test: I run kogen provider update claude-code
    Then claude-code-daily-update-after-hook-self-test: the update output has the line "kogen: Claude Code 2.1.319 failed Kogen's hook self-test (guarded call ran without a hook record); staying on 2.1.318"
    And claude-code-daily-update-after-hook-self-test: the directory "2.1.319" does not exist in the Claude Code directory
    And claude-code-daily-update-after-hook-self-test: harness.json records "2.1.319" as failed
    And claude-code-daily-update-after-hook-self-test: the active version is not changed from 2.1.318
    When claude-code-daily-update-after-hook-self-test: I build the "first" fixture Intent
    Then claude-code-daily-update-after-hook-self-test: the Build landed and its Claude Code roles ran ".kogen/claude-code/2.1.318/claude"
    When claude-code-daily-update-after-hook-self-test: I run kogen provider update claude-code
    Then claude-code-daily-update-after-hook-self-test: the origin served the "2.1.319" binary 1 time
    And claude-code-daily-update-after-hook-self-test: the directory "2.1.319" does not exist in the Claude Code directory

  Scenario: A candidate whose hook allows the protected write is refused
    Given claude-code-daily-update-after-hook-self-test: the origin announces "2.1.319" and serves a candidate that "allows-protected"
    When claude-code-daily-update-after-hook-self-test: I run kogen provider update claude-code
    Then claude-code-daily-update-after-hook-self-test: the update output has the line "kogen: Claude Code 2.1.319 failed Kogen's hook self-test (protected edit was not refused); staying on 2.1.318"
    And claude-code-daily-update-after-hook-self-test: harness.json records "2.1.319" as failed
    And claude-code-daily-update-after-hook-self-test: the directory "2.1.319" does not exist in the Claude Code directory
    And claude-code-daily-update-after-hook-self-test: the active version is not changed from 2.1.318

  Scenario: With a check 23 hours old a Build start makes no request and the receipt says pinned
    Given claude-code-daily-update-after-hook-self-test: the origin announces "2.1.318" and serves no candidate
    And claude-code-daily-update-after-hook-self-test: harness.json says the last check ended 23 hours ago
    When claude-code-daily-update-after-hook-self-test: I build the "first" fixture Intent
    Then claude-code-daily-update-after-hook-self-test: the Build landed
    And claude-code-daily-update-after-hook-self-test: the origin received 0 lookups of latest
    And claude-code-daily-update-after-hook-self-test: harness.json holds a checked_at older than 22 hours
    And claude-code-daily-update-after-hook-self-test: the Build result says claude_code_version "2.1.318" and claude_code_source "pinned"

  Scenario: One check after 25 hours and none at the next Build start
    Given claude-code-daily-update-after-hook-self-test: the origin announces "2.1.318" and serves no candidate
    And claude-code-daily-update-after-hook-self-test: harness.json says the last check ended 25 hours ago
    When claude-code-daily-update-after-hook-self-test: I build the "first" fixture Intent
    Then claude-code-daily-update-after-hook-self-test: the Build landed
    And claude-code-daily-update-after-hook-self-test: the origin received 1 lookup of latest
    And claude-code-daily-update-after-hook-self-test: harness.json holds a checked_at within the last 10 minutes
    When claude-code-daily-update-after-hook-self-test: I build the "second" fixture Intent
    Then claude-code-daily-update-after-hook-self-test: the Build landed
    And claude-code-daily-update-after-hook-self-test: the origin received 1 lookup of latest

  Scenario: An unreachable origin never stops a role
    Given claude-code-daily-update-after-hook-self-test: the origin announces "2.1.319" and serves a candidate that "works"
    And claude-code-daily-update-after-hook-self-test: harness.json says the last check ended 25 hours ago
    And claude-code-daily-update-after-hook-self-test: the origin refuses connections
    When claude-code-daily-update-after-hook-self-test: I build the "first" fixture Intent
    Then claude-code-daily-update-after-hook-self-test: the Build landed and its Claude Code roles ran ".kogen/claude-code/2.1.318/claude"
    And claude-code-daily-update-after-hook-self-test: harness.json records an unreachable origin
    And claude-code-daily-update-after-hook-self-test: harness.json holds a checked_at within the last 10 minutes
    And claude-code-daily-update-after-hook-self-test: the active version is not changed from 2.1.318

  Scenario: A Build started before an update keeps the version it started with
    Given claude-code-daily-update-after-hook-self-test: the origin announces "2.1.319" and serves a working candidate and the pinned runtime runs the update itself during its Build round
    And claude-code-daily-update-after-hook-self-test: harness.json says the last check ended 1 hours ago
    When claude-code-daily-update-after-hook-self-test: I build the "first" fixture Intent
    Then claude-code-daily-update-after-hook-self-test: the update ran from inside the Build round and succeeded
    And claude-code-daily-update-after-hook-self-test: the active version is "2.1.319"
    And claude-code-daily-update-after-hook-self-test: the Build's first Claude Code role ran ".kogen/claude-code/2.1.318/claude"
    And claude-code-daily-update-after-hook-self-test: the Build result says claude_code_version "2.1.318" and claude_code_source "pinned"
