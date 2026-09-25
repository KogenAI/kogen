# Codex compatibility probe runs (Shaping, 2026-09-25)

Each run executed `mix test --only live test/kogen/codex_compatibility_test.exs` from a
disposable `git archive` copy of `main` at `2909f557`, placed in the Shaping scratchpad.
Runs were one at a time, and no other live test ran during them. Per-turn times come
from the `elapsed_ms` that each probe patch adds to the fixture's `turn-*.json`. The
Shaping turn time is measured from the discovery receipt to the Shaping receipt. The
fixtures are retained under
`~/Library/Application Support/Kogen/codex/compatibility/<fixture>`.

## v1: tailored stand-in Reviewer prompts (REJECTED by the Shaper)

Patch: `compatibility-probe-v1-rejected.patch`. It keeps the stand-in Reviewer turns
but lists the exact files for them to read, and raises the limit to 360 s.

| Run | Fixture | Result | Total | Shaping | Developer | initial Reviewer | Resume | final Reviewer |
|---|---|---|---|---|---|---|---|---|
| 1 | compatibility-1790316112944-578 | pass | 312 s | ~26 s | 72 s | 79 s | 56 s | 76 s |
| 2 | compatibility-1790316447448-610 | pass | 372 s | ~16 s | 107 s | 47 s | 90 s | 108 s |

The Shaper rejected this design: a tailored stand-in Reviewer tests the fixture, not
the Reviewer. The only finding kept from v1 is that the Reviewer turns drive the runtime.

## v2: no stand-in Reviewers (the design this Intent adopts)

Patch: `compatibility-probe-v2.patch`. It removes both stand-in Reviewer turns, drives the
resume from a fixed rework request, removes only the Reviewer requirements from
`verify_evidence` and keeps every native-boundary requirement, sets
`KOGEN_BOUNDED_EXEC_TIMEOUT=300` inside the owner, and adds timing. It has no retry or
manifest, because the probe measures raw reliability.

| Run | Fixture | Result | Total | Shaping | Developer | Resume |
|---|---|---|---|---|---|---|
| 3 | compatibility-1790317112983-610 | pass | 229 s | ~17 s | 135 s | 73 s |

## Limitations

- v2 has one run. The Shaper chose to build without further probe runs
  ("let's build"). The Build's own `live-native` run is the next evidence.
- No `live-reviewer-rework` run was made with a Codex Reviewer, so that risk is unmeasured
  (see `risks.yaml`, `codex-reviewer-rework-duration`).
- The probe patches are reference material for the Developer, not reviewed code. The
  offline tests were not updated in the probe.
