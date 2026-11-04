Feature: The shaping specification describes the per-Intent step-file namespace

  Scenario: The shaping chapter states the per-Intent step-file namespace and its refusals
    Given k-spec-shape-step-namespace: the specification file "spec/prose/02-shaping.md"
    Then k-spec-shape-step-namespace: it contains "each named `<slug>__<suffix>.js` with a nonempty suffix (for `is-even`, `features/steps/is-even__steps.js`)"
    And k-spec-shape-step-namespace: it contains "starts with the literal prefix `<slug>: ` (for example `Given is-even: the input is 4`)"
    And k-spec-shape-step-namespace: it contains "keep their step file names and need not be renamed"
    And k-spec-shape-step-namespace: it contains "Files may only be the Intent's own files and step files named `<steps_dir>/<slug>__<suffix>.js` (nonempty suffix), new or existing"
    And k-spec-shape-step-namespace: it contains "`<path>: new step files must be named <steps_dir>/<slug>__<suffix>.js (nonempty suffix); prefix step sentences and definitions with <slug>: `"
    And k-spec-shape-step-namespace: it contains "`step sentence must start with <slug>: `"
    And k-spec-shape-step-namespace: it contains "`definition must start with <slug>: `"
    And k-spec-shape-step-namespace: it contains "`binding comes from a step file outside this Intent: <file>`"
    And k-spec-shape-step-namespace: it does not contain "existing files that are reused or edited, or new ones"
    And k-spec-shape-step-namespace: it does not contain "step files under `steps_dir`, new or existing"

  Scenario: The shaping chapter's examples name the namespaced step file
    Given k-spec-shape-step-namespace: the specification file "spec/prose/02-shaping.md"
    Then k-spec-shape-step-namespace: it contains:
      """
      Acceptance:
      - .kogen/intents/is-even/acceptance.feature
      - features/steps/is-even__steps.js
      """
    And k-spec-shape-step-namespace: it contains "Step files: features/steps/is-even__steps.js (new)"
    And k-spec-shape-step-namespace: it does not contain "Step files: features/steps/is_even_steps.js (new)"
    And k-spec-shape-step-namespace: it does not contain "- features/steps/is_even_steps.js"

  Scenario: The step vocabulary describes the namespaced shaper fixtures
    Given k-spec-shape-step-namespace: the specification file "spec/features/STEPS.md"
    Then k-spec-shape-step-namespace: it contains "`features/steps/is-even__existing.js` (an existing step file in the `is-even` namespace that shaping may edit)"
    And k-spec-shape-step-namespace: it contains "Every script that submits a new `is-even` package names its step file `features/steps/is-even__steps.js` and starts every step sentence and definition with `is-even: `"
    And k-spec-shape-step-namespace: it contains "`shape-failing-invariant` submits `counter` with `features/steps/counter__steps.js` and the prefix `counter: `"
    And k-spec-shape-step-namespace: it contains "submits `is-even` with an edit to the existing `features/steps/is-even__existing.js`"
    And k-spec-shape-step-namespace: it does not contain "with an edit to the existing `features/steps/calc_steps.js`"
