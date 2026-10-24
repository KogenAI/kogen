# Preserve the fixture

Slug: fixture
Model: not applicable — no model for this fixture

Acceptance:
- .kogen/intents/fixture/acceptance.feature
- features/steps/integration_steps.js

## Tests
- the fixture stays as it is: the acceptance scenario (existing)

## Source comparison
- addressed: preserve app.txt fixture behavior; source request; contract Tests and acceptance.feature.

## Feasibility
- none

## Stages
```json
{"stages":[{"checks":["test -f app.txt","grep -q . app.txt"],"goal":"First runnable section — é","id":"foundation","title":"Foundation"},{"checks":["true"],"goal":"Integrate the second section","id":"surface","title":"Surface"}],"version":1}
```
