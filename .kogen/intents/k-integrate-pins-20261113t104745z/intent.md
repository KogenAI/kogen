# Fix kogen on the new component pins

Slug: k-integrate-pins-20261113t104745z
Model: not applicable — pin integration fix with no meaningful state
Acceptance:
- .kogen/intents/k-integrate-pins-20261113t104745z/acceptance.feature
- features/steps/k-integrate-pins-20261113t104745z__commit.js

With kogen-shaping at 849a98aaa63d and kogen-review at 401eb24058ff (pins fixed in cli/go.mod and cli/go.sum), kogen's full qualification must be green: gofmt -l empty in cli/, and go build, go vet and go test ./... in cli/, the acceptance suite, the spec check and the packaging suite pass. The Build finds the cause of each failure in kogen's own code (cli/ code and tests, including the consumes/<component> contract tests) and fixes it, following any contract the new component versions changed. It must not skip tests, raise timeouts, or move a pin, and must not edit protected paths.

Failing at the base:

```
== step acceptance (logs/adopt/20261113T104745Z-final-acceptance.out) ==
full-acceptance 200s 267/268 passed; 1 failing scenario(s) not failing on main or the base
  spec/features/07-committing.feature:14 A verified, approved Build makes one commit
    step: Then the exit code is 0
    AssertionError [ERR_ASSERTION]: building is-even
    stopped is-even: interrupted (Build 87943dbc)
    candidate/interrupted: Build 87943dbc stopped by SIGTERM; edits are left in place
      checks, before the Build → after (no verification pass):
        1. test: passed → not run
      edited: calc.py, tests/test_calc.py
```

## Decisions
- Fix the root cause in cli/ rather than weakening the spec scenario, timeouts or pins (source: request)
- Acceptance runs the real failing spec scenario through the cucumber runner in test/acceptance (evidence: test/acceptance; spec/features/07-committing.feature) (assumption: the cause lies in kogen's cli/ code, not in the pinned components) (source: request)

## Source comparison
- Request: fixed pins, gofmt/build/vet/test, acceptance, spec check, packaging all green; addressed by the scenario below plus the project's configured checks.
- Failing scenario spec/features/07-committing.feature:14 addressed directly by acceptance.feature.

## Tests
- A verified, approved Build makes one commit with exit code 0 on the new pins: run spec scenario 07-committing.feature:14 (scenario)
- cli unit and consumes contract tests follow the new component contracts: existing go test ./... in cli (existing)

## Feasibility
- none
