Feature: Shape checks the step code it writes before publishing
  The driver mounts as a test with go -overlay and runs the real Shape path (scripted external session or scripted native provider) with step files that are correct or carry one defect.

  Scenario: A correct package publishes with one step_selfcheck event and no extra round
    When the k20 Shape plays "ok"
    Then the k20 package published after one round with one step_selfcheck event listing every item checked

  Scenario: A step that builds the binary for an asserted exit code is not flagged
    When the k20 Shape plays "built"
    Then the k20 package published after one round with one step_selfcheck event listing every item checked

  Scenario: A syntax error is fed back and the corrected submission publishes
    When the k20 Shape plays "syntax"
    Then the k20 first submission was fed back for the "syntax" failure and the corrected second submission published

  Scenario: An unresolvable require is fed back and the corrected submission publishes
    When the k20 Shape plays "require"
    Then the k20 first submission was fed back for the "require" failure and the corrected second submission published

  Scenario: An undefined step is fed back and the corrected submission publishes
    When the k20 Shape plays "undefined"
    Then the k20 first submission was fed back for the "undefined" failure and the corrected second submission published

  Scenario: An ambiguous step is fed back and the corrected submission publishes
    When the k20 Shape plays "ambiguous"
    Then the k20 first submission was fed back for the "ambiguous" failure and the corrected second submission published

  Scenario: An unused definition is fed back and the corrected submission publishes
    When the k20 Shape plays "unused"
    Then the k20 first submission was fed back for the "unused" failure and the corrected second submission published

  Scenario: go run for an asserted exit code is fed back and the corrected submission publishes
    When the k20 Shape plays "gorun"
    Then the k20 first submission was fed back for the "gorun" failure and the corrected second submission published

  Scenario: Observer controls that do not reproduce their recorded exits are fed back
    When the k20 Shape plays "observer"
    Then the k20 first submission was fed back for the "observer" failure and the corrected second submission published

  Scenario: Native Shape publishes a correct package with one step_selfcheck event
    When the k20 Shape plays "native-ok"
    Then the k20 package published after one round with one step_selfcheck event listing every item checked

  Scenario: Native Shape feeds a syntax error back and the corrected submission publishes
    When the k20 Shape plays "native-syntax"
    Then the k20 first submission was fed back for the "syntax" failure and the corrected second submission published
