# Probe: the smoke rehearsal's setUp under the new pinned_smoke_config (2026-09-28)

## Setup

- `git archive dece3e84` extracted into a scratch directory (`sq3/probe/smokefix/head`). The repository was not
  touched.
- `new` is a copy of that tree with two files changed, `driver.diff` and `rehearsal.diff` here:
  - `driver.py`: only `pinned_smoke_config` (the new function INTENT.md "Smoke fixture" describes, written by hand
    from the Draft, not qb's version). qb's whole-file `driver.py` rewrite belongs to `shaping-evaluation-live` and
    was not applied.
  - `driver_smoke_rehearsal_test.py`: the `difflib` import, `setUp`'s five `codex-fake` route lines and the
    `.kogen/runtime/` ignore line, `run_smoke`'s `hook_files=False` keyword, K1's exact diff and refusals, and K3.
- `run.sh` builds two more variants from `new` and runs `driver_smoke_rehearsal_test.py` directly with
  `python3 -B`, with `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` unset. The output is in `run.out`.

## Observations

| Variant | Catalogued controls | K1 | K3 | Invalid manifest |
|---|---|---|---|---|
| 1. HEAD as is | pass | (HEAD's body) pass | n/a | pass |
| 2. New `pinned_smoke_config`, HEAD's `setUp` | **both ERROR**: "smoke: the codex route has no auditor entry to remove" | pass | ERROR (same) | pass |
| 3. Plus `setUp`'s five route lines, no `.kogen/runtime/` ignore | pass | pass | **FAIL**: exit 1 | pass |
| 4. Plus `.kogen/runtime/` in the rehearsal `.gitignore` (the Draft) | pass | pass | pass | pass |

- Variant 2 reproduces Opus finding 1. `run_smoke()` calls `smoke_files()` first, so both
  `test_smoke_rehearsal_dispatches_real_functions_and_manifests_once` and
  `test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast` raise before any transport.
- Variant 3 reproduces Opus finding 2. The receipt shows `git_status.baseline_unchanged: false` and
  `source_identity.unchanged: false`, and the snapshot gains the two `.kogen/runtime/shaping-audits/eval-smoke/…`
  files.
- Variant 4 passed all five tests on four runs in a row. On the tracked config, K1's diff is exactly the four
  `-` and three `+` lines of the scenario. Removing the codex `auditor:` line raises "smoke: the codex route has no
  auditor entry to remove". Removing its `expert:` line raises "smoke: the codex route has no single flow-map
  expert helper line to pin".
- K3 runs `run_smoke()` twice in one `setUp`. A second run first needed `<runtime>/runs` removed ("fixture
  exists … runs/smoke"), then the sessions directory emptied ("observed root efforts []" from the reused rollout).
  The scenario states both resets.

## P1 substrings

`p1-subs.txt` holds the 42 substrings P1 asserts, one per line. `p1-check.out` checks them against zuj's
`shaping.md` applied to dece3e84, after compacting whitespace. 36 are present word for word. Six are missing:
items 1, 2, 4, 5 and 6 of the Prompts list, and "A probe that launches a provider in a disposable directory is
not a verification gate.". These are the six sentences the scenario inserts. None of the removed passages occurs
in zuj's three prompt files. The six existing t003 assertions are all present in zuj's `shaping.md`.

## Folded into

- scenario `smoke-fixture-without-auditor`: its given, then (the exact `setUp` lines and `.gitignore` text),
  wrong result, K3 and K4.
- INTENT.md "Existing files and tests this slice changes" and "Smoke fixture".
- risk `self-hosting`, and evidence/CANDIDATE.md.

## Limitations

- The Python file was run directly, not through `test/kogen/shaping_smoke_rehearsal_test.exs` (K4) or `check`.
- `mix compile` and `mix run` are faked in the rehearsal, as they are at HEAD.
