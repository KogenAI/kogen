Feature: Kogen continues a Build when Claude Code rejects a guarded write before the hook
  The driver mounts as a test with go -overlay and runs the real Build over the real Claude Code adapter and its real PreToolUse hook, against this test binary re-executed as a scripted fake claude: no real claude and no paid request.
  Round 1 of the fake first changes app.txt through Bash, then makes the incident's Write call toolu_014z3hLJe9neZ1V8rmXgJRRi on app.txt with the content "candidate", then a NotebookEdit of the missing analysis.ipynb, a Read of app.txt and a retried Write of "candidate" through the hook.

  Scenario: A Write rejected as modified since read, with nothing written, lets the round continue and the Build land
    When the k-hook-prevalidation fake Claude Code build round plays "rejected-before-hook"
    Then the k-hook-prevalidation Build continued the round, landed exactly one commit with app.txt "candidate" and created no notebook
    And the k-hook-prevalidation run log has exactly these executor_tool events in order:
      | name         | tool_use_id                    | denied | rejected_before_hook |
      | Bash         | toolu_khp_bash                 | false  |                      |
      | Write        | toolu_014z3hLJe9neZ1V8rmXgJRRi | false  | true                 |
      | NotebookEdit | toolu_khp_notebook             | false  | true                 |
      | Read         | toolu_khp_read                 | false  |                      |
      | Write        | toolu_khp_retry                | false  |                      |
    And the k-hook-prevalidation hook ran only for the call "toolu_khp_retry", which it allowed

  Scenario: A Write that changed the file without the hook still stops the round, even when reported as an error
    When the k-hook-prevalidation fake Claude Code build round plays "written-without-hook"
    Then the k-hook-prevalidation Build stopped as executor/protocol with the detail 'hook did not run for the Write call "toolu_014z3hLJe9neZ1V8rmXgJRRi"; the round was stopped' and made no commit
