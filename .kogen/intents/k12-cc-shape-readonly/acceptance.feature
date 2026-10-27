Feature: Claude Code Shape stays read-only without stopping on harmless events
  The drivers mount as tests with go -overlay and run the real adapter against the package's fake claude, and the real external Shape path with a scripted session.

  Scenario: The Shape child gets the disallowed write tools and GIT_OPTIONAL_LOCKS=0
    When the k12 Claude Code adapter runs a "shape" session
    Then the k12 Shape child has the write tools disallowed and GIT_OPTIONAL_LOCKS=0

  Scenario: The Build child is unchanged
    When the k12 Claude Code adapter runs a "build" session
    Then the k12 Build child has its unchanged arguments

  Scenario: A Shape write call without a hook event gets feedback and the round completes
    When the k12 Claude Code adapter runs a "shape-no-hook" session
    Then the k12 Shape session got feedback that write tools are not available during Shape and both rounds completed

  Scenario: A Build write call without a hook event is still a protocol failure
    When the k12 Claude Code adapter runs a "build-no-hook" session
    Then the k12 Build round still stops with an executor protocol failure because the hook did not run

  Scenario: A git status stat-cache refresh during a Shape round is not a baseline change
    When the k12 Shape round plays "stat-refresh"
    Then the k12 Shape published an Intent although the index stat data was refreshed

  Scenario: Staging a file during a Shape round is a baseline change
    When the k12 Shape round plays "stage-existing"
    Then the k12 Shape stopped with a candidate baseline_changed naming the Git index and published nothing

  Scenario: A file created outside the Intent is removed before publishing
    When the k12 Shape round plays "keep-note"
    Then the k12 Shape published an Intent without the keep note and no untracked path outside the Intent remains

  Scenario: A pre-existing untracked file is left alone
    When the k12 Shape round plays "keep-note-preexisting"
    Then the k12 Shape published without the keep note and left the pre-existing untracked file alone
