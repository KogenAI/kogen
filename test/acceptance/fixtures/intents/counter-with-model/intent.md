# Add a bounded counter

Slug: counter
Model: .kogen/intents/counter/model.qnt invariants=NeverNegative seed=7 samples=500 steps=30
Acceptance:
- .kogen/intents/counter/acceptance.feature
- features/steps/counter_steps.js

A bounded counter begins at zero and remains non-negative.

## Decisions
- The counter begins at zero. (source: request)

## Tests
- Counter state initializes at zero and remains non-negative through increments: add test_counter_state in tests/test_counter.py (unit)

## Feasibility
- none
