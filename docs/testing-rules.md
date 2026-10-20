# Testing rules

These rules decide which tests a change needs, and how a change is specified so that it can be built and tested (section 6). They apply to every change made with Kogen, in Kogen's own code and in every product built with it. Follow them exactly. Choose tests from the requested behavior, not from the number of functions, modules or files that changed.

## 1. Identify what changed

List the behavioral rules the request adds, changes or removes. For each rule, name the existing test to update or the new test to add. Do not add rules, validation or error handling only to create more test cases.

## 2. Choose the test

Use this table. Use the narrowest test that exercises the rule. Add another layer only when it catches a named mistake that the first test would miss.

| Change | Required evidence |
| --- | --- |
| A calculation, transformation, filtering or validation rule | Focused unit tests of the result through a callable interface. |
| Behavior involving files, database queries, Git, processes or communication between components | An integration test using the relevant local dependency. |
| User interaction or command-line behavior | A scenario through the actual UI or CLI boundary. |
| Wiring existing, already-tested behavior into another entry point | An integration, UI or CLI test that proves the connection. No new unit tests unless logic also changes. |
| A bug fix | A regression test that reproduces the reported failure. |
| A refactor without behavior changes | The existing behavior tests pass unchanged. Add a test only for an identified gap. |
| Copy, styling or documentation | Verify the changed output or appearance. No unit test unless executable behavior changes. |

Native Kogen Build and review tools return text only. Reading an image file, printing its path or base64, or successfully capturing a screenshot does not deliver pixels to the model. Do not claim to have viewed or visually approved a PNG from those results.

For programmatic UI evidence, exercise the actual browser DOM and interactions, and inspect accessible text, computed styles and layout measurements at the required viewports. Keep required real-browser behavior checks and requested artifact exports. Image exports are for a human or outside agent with pixel input to inspect; a saved capture or textual measurements do not complete a required pixel review. Report what was actually checked and what still needs outside pixel inspection. This guidance does not add image input or a browser tool to Kogen.

Layers used in an Intent's `## Tests` section: `unit`, `integration`, `scenario`, `regression`, `existing` (an existing test already covers the rule).

## 3. Derive the cases from the contract

- A condition with two specified outcomes: test both outcomes.
- A specified boundary: test the boundary and its adjacent valid values.
- Explicitly rejected input: test the rejection and its specified effect.
- A state transition: test the resulting state and its observable effect.
- A bug: test the reproducing input.

Invent no other input categories, failure modes or combinations. An existing test can satisfy a case. A separate test function per case is not required.

## 4. Restrictions

- Assert outputs, observable effects and contractual state. Never assert private helper calls, internal call order or module structure, unless they are a public contract.
- Add no production abstraction only to allow mocking.
- Reuse existing test tools and fixtures before adding a dependency.
- Keep useful existing tests. Update the tests of changed behavior. Delete the tests of removed behavior.
- A new regression test must fail on the unfixed behavior. A new feature test must distinguish the requested implementation from the old behavior.

## 5. Fixed sequence

1. During implementation: run the affected tests.
2. Before a commit: run the configured fast regression suite and the change's acceptance scenarios.
3. Before a release: run the full suite and the supported-platform checks.
4. Run live external-service tests only when changing that integration, or for release acceptance.

## 6. Specify the change so it can be built and tested

Shaping writes the Intent, its scenarios and its model by these principles. Each one prevents a mistake that, left in a specification, makes a correct Build impossible or lets a wrong one pass.

- **Precise interfaces.** Name every interface the scenarios and tests call: the command, function or endpoint, its arguments, its output and error shapes, and exact formats. Where a real response has been observed (a probe, an external service), quote its exact shape, and make any fake serve that recorded shape.
- **Consistent preconditions.** State the state each rule starts from. Where two rules touch the same files or state, say which one wins, with one example. Check cheap preconditions (setup, tools, a check that already fails on the unchanged tree) before expensive work. Every loop or retry without a limit names what makes it end, and fails fast when it cannot.
- **Complete execution inputs.** Every value a step uses comes from something an earlier step can observe. Name every file, setting, tool and version the commands need. Run each command once in the environment the scenarios use before writing it into the Intent.
- **Observable outcomes.** State guarantees as an end state a user can check, such as "no new commit on the branch". Check lists exactly and in order. A pass depends on what must have run, not on an exit status alone. Check every output format against each state of its inputs: empty and non-empty, first and later runs.
- **Acceptance that exercises the central claim.** At least one scenario runs the requested behavior end to end through its real entry point; checks of single components do not replace it. The scenarios tell the requested behavior apart from the old behavior and from a plausible wrong implementation.
- **Nothing without a present need.** Every option, fallback or setting answers a sentence of the request. Summaries point to the rule they summarize instead of restating it.

## The reviewer

The reviewer checks that meaningful tests establish each required outcome and makes scoped repairs. A false-passing fixture, missing evidence of required behavior, or flakiness that breaks a supported use case is substantive. Existing coverage may establish the outcome; a missing preferred layer alone is not an application defect.

Review is against the approved Intent and explicit existing project conventions, including documented requirements without a deterministic tool rule. Delegate mechanical formatting and style to the existing configured formatters, linters, checks and fixers, preserving their checks and settings. Repair demonstrated current correctness, safety, scope and meaningful-test defects and violations of those requirements or conventions. Every substantive concern identifies its applicable requirement, concrete counterexample or violating path, and observable consequence.

Do not make preference-only renamings, rearrangements, abstraction changes, speculative refactors or harmless nearby dead-code cleanup. Minimal incidental changes necessary for a demonstrated repair or configured style or project requirement are allowed; proximity or personal preference alone is not justification. Test duplication and implementation coupling are notes unless a demonstrated current consequence makes them substantive. Harmless preferences may be nonblocking notes, never required edits. Approving unchanged correct code is success, with no edit quota.

Make scoped repairs and add or update useful regression coverage; do not remove useful tests or weaken configured checks to obtain a pass. Kogen externally verifies changed final contents, returning failures to the same reviewer conversation.

## Adopting Kogen in an existing project

Do these steps in order. Do not do a project-wide cleanup first.

1. Sign in with `kogen provider login chatgpt`, then run `kogen init`.
2. Review the setup, fixers, checks and acceptance runner that `init` selected and checked in `.kogen/project.yaml`, including what it left out. Correct project-specific omissions and commit the configuration changes. `init` adds the Gherkin bridge when needed and keeps the existing test framework.
3. Make the project's `README.md` useful to Kogen: its purpose, how to run and check it, its conventions, links to maintained specifications, and this testing policy. Shaping and review read it.
4. Request one real feature or fix. Shaping inspects its implementation, callers, tests and documentation.
5. Fill the specification gap around that change: the desired behavior and the existing behavior it must preserve, executable scenarios, and a Quint model where state or interacting rules warrant one (not for copy changes or plain wiring). Existing code and tests are evidence of current behavior, not proof of intended behavior: shaping separates "the code does this now" from "the product should do this".
6. Review, approve and build. The Build changes the implementation and its tests, and removes obsolete paths and tests within that change. Keep useful existing tests. Update tests for changed behavior. Replace brittle implementation-detail assertions when you touch them. Delete tests of removed behavior.

A change needs, besides a Quint model and Gherkin scenarios where they apply: short prose (outcome, boundaries, decisions, what is replaced or removed), executable step definitions, implementation tests chosen by the rules above, and the project's relevant checks.
