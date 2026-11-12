# Pin kogen's outcome for init without a login

Slug: k-acceptance-init-provider
Model: not applicable — the change edits one acceptance scenario and has no state
Acceptance:
- .kogen/intents/k-acceptance-init-provider/acceptance.feature
- features/steps/k-acceptance-init-provider__steps.js

In spec/features/01-project-setup.feature, the scenario "Init without a login writes nothing" stops asserting kogen-setup's exact stdout text ("And stdout is:" with the login guidance). It asserts kogen's outcome: exit code 4, stdout contains the stop code `provider/login`, the file `.kogen/project.yaml` does not exist, and the working tree is unchanged. A init that wrote any file still fails it through the working-tree step. Only acceptance files change; cli/go.mod and cli/go.sum are not touched.

## Decisions
- Replace the exact-stdout step with `And stdout contains "provider/login"` and add `And the working tree is unchanged` (existing steps, used by the scenario "Two invalid configuration replies end init without writing anything"); keep the exit-code and project.yaml steps. (evidence: spec/features/01-project-setup.feature) (source: request)
- Do not edit cli/go.mod or cli/go.sum; the kogen-setup pin is moved by adoption. In this checkout it already is v0.0.0-20261112083410-2aed318282ce, newer than c45c7b6. (evidence: cli/go.mod) (source: request)
- The scenario "Init leaves out a setup command that cannot run twice on the same tree" needs no change: with the current pin it passed when run alone in this checkout, so the scripted model in test/acceptance/support/fake-servers.js stays as is. (evidence: test/acceptance/support/fake-servers.js; spec/features/01-project-setup.feature) (assumption: confirm that scenario still passes at the pin the Build starts from) (source: request)

## Source comparison
- Need 1 (no foreign wording pin in :141): addressed by editing that scenario.
- Need 2 (scripted init configuration accepted by setup): checked; no edit needed at the current pin.
- Need 3 (bump cli/go.mod): superseded by the changed input; omitted, protected.
- Fault test: an init that writes a file fails the retained working-tree step.

## Tests
- init without a login is asserted by outcome only: acceptance.feature reads the scenario and checks its steps (scenario)
- init without a login still stops with exit 4 and writes nothing: the edited scenario in spec/features/01-project-setup.feature (existing)

## Feasibility
- none
