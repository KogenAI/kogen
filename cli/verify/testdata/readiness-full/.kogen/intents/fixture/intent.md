# Fixture intent

Slug: fixture
Model: .kogen/intents/fixture/model.qnt invariants=Safe seed=7 samples=40 steps=12
Acceptance:
- .kogen/intents/fixture/acceptance.feature
- features/steps/fixture_steps.js

The fixture.

## Decisions
- Fixture decision. (source: request)

## Tests
- none: fixture

## Feasibility
- evidence: {"id":"route","kind":"capability","inputs":["route.cjs"],"observers":[],"checks":[{"name":"support","command":"cat route.cjs","exit":0,"output":"route bytes\n"}]}
