# Add an is-even helper

Slug: is-even
Model: not applicable — a pure function without state
Acceptance:
- .kogen/intents/is-even/acceptance.feature
- features/steps/is_even_steps.js

calc.is_even(n) returns True for even integers and False for odd ones; non-integers raise TypeError.

## Decisions
- Non-integers raise TypeError instead of returning False. (source: request)

## Feasibility
- none
