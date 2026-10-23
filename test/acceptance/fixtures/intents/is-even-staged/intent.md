# Add an is-even helper

Slug: is-even
Model: not applicable — a pure function without state
Acceptance:
- .kogen/intents/is-even/acceptance.feature
- features/steps/is_even_steps.js

calc.is_even(n) returns True for even integers and False for odd ones; non-integers raise TypeError.

## Decisions
- Non-integers raise TypeError instead of returning False. (source: request)

## Tests
- calc.is_even returns True for even and False for odd integers: add test_is_even in tests/test_calc.py (unit)
- calc.is_even raises TypeError for a non-integer: add test_is_even_rejects_floats in tests/test_calc.py (unit)

## Feasibility
- none

## Stages
```json
{"version":1,"stages":[{"id":"calculation","title":"Calculation","goal":"Runnable integer calculation","checks":["python3 -c 'import calc; assert calc.is_even(4); assert not calc.is_even(3)'"]},{"id":"compatibility","title":"Compatibility","goal":"Integrate the helper with the existing calculator tests","checks":["python3 -m unittest"]}]}
```
