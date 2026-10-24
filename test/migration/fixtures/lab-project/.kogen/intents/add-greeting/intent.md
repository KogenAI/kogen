# Add the hello greeting

Slug: add-greeting
Model: not applicable — the fixture has no meaningful state
Acceptance:
- .kogen/intents/add-greeting/acceptance.feature
- features/steps/add_greeting_steps.js

Add hello.txt saying hello.

## Decisions
- hello.txt holds the greeting. (source: request)

## Source comparison
- Requested: hello.txt saying hello. Addressed by the scenario in acceptance.feature (request, contract acceptance.feature).

## Tests
- hello.txt holds the greeting: the greeting scenario (scenario)

## Feasibility
- none
