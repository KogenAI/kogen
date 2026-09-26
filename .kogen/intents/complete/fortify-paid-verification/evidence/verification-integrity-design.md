# Verification-integrity design (expert advice, 2026-09-25)

Provenance: a read-only `kogen-expert` helper (configured profile
claude-opus-5-5, high effort) during the fifth continuation turn. The Shaper
had asked for Codex Sol, but the Shaping delegation policy here lists only the
Claude agents, so it wasn't used. The root Shaping Controller checked the
consequential source claims (below) against the source bytes. This is advice,
not an accepted decision; see `questions.md`.

## Source facts (root-verified)

- Offline proof selectors are only checked for existence
  (`lib/kogen/build/verification_plan.ex:94-103`, `missing_selectors/3`). An
  empty file at the declared path satisfies that check.
- `GuardedPaths.check/2` (`lib/kogen/build/guarded_paths.ex:16-27`) rejects any
  changed path outside `may_change_guarded_paths`. So unlisted files, such as
  `Makefile` and `mix.exs` in this Draft, are already frozen as whole files.
- The handoff report lists changed paths only under each scenario's
  `affected_paths` (`lib/kogen/build/report.ex:69-92`). A weakened test
  elsewhere never appears in Review input.
- `scripts/check/offline.py:22-26` runs `mix test --exclude live`, so a
  scenario test tagged `:live` never runs in `check`.
- README (line 67) promises that Jev never receives the diff or Candidate files.

## Recommended rules (summary)

1. Trust anchors are the admission base commit, the admission catalog, the
   approved Intent and controller code. Candidate-authored definitions are
   never evidence of their own strength.
2. The admission catalog declares `verification_surface` globs (tests, runner
   files), a `focused_runner` argv template, and a `base_cache` to copy.
3. Permission to change a file stays in `may_change_guarded_paths`. There is no
   recipe or transitive freeze.
4. Each scenario's `proof.base: fail | pass` is set by the Shaper. Legacy
   contracts are labelled `unproven-on-base`.
5. The controller runs each scenario's file selectors on the Candidate every
   cycle, with the admission `focused_runner`.
6. For `base: fail`: the selectors run in a controller-owned `git archive`
   base workspace, with only the Candidate's selector and test-class files
   overlaid. They are run by base's runner and must exit nonzero. The receipt
   records `red_kind` (assertion or load) and the workspace digest is
   re-checked.
7. For `base: pass`: selectors should be byte-identical to base, otherwise
   they become ledger items.
8. Targets: the Build runs the union of `verified_by`. `catalog_changes.add`
   allows new names. A missing selected target fails verification.
9. The verification-surface ledger (a git diff of surface paths against base)
   goes into the handoff report and Review input, never Jev.
10. The Reviewer must disposition every ledger item (`justified` or
    `weakening`), enforced by code.
11. Drop recipe freezing, target-level red-on-base, the replacement owner
    partition, `red_on_base: exempt`, and `remove`/`replaced_by`. `command`
    entries are portability only, with no safety value.

## Caught vs left to Review

Caught in code: an empty or `assert true` selector, a scenario test hidden
behind `:live` or a skip, a selector that doesn't run, a weakened shared helper
that makes a `fail` selector pass on base, a removed or renamed selected target,
and a tampered base workspace.
Left to Review, through the ledger: runner edits inside the allowlist, tests
that detect which tree they run on, compile failures counted as red (labelled),
weakened or deleted existing tests, edited preservation tests, and regressions
no scenario covers.

## Rejected by the expert

Freezing transitive definitions (the set has no bound); target-level
red-on-base with a Candidate recipe (it runs the Candidate's definition); the
owner-partition rule (no safety gain); a test-count floor (gameable, and it
blocks rewrites); diffs to Jev (breaks the README promise); mutation testing
(expensive and language-specific).

## Unverified by root

- Whether copied Mix `_build` caches are reused by the base workspace. The
  expert flagged this as unverified; the worst case is a ~2 minute cold
  compile.
- Line-level details of `contract.ex:188-204` (the exact `proof` keys) and
  `verification_plan.ex:219-245` (the hardcoded selector layout) are the
  expert's report and weren't re-read by root.
