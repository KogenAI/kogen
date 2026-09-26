# build-reliability: state for the next Shaping session (2026-09-26)

- **Intent:** `build-reliability`, id `01a0dc14-070e-75b3-8669-e12ce5f65229`, title "Harden Build reliability".
- **Package:** `.kogen/intents/drafts/build-reliability/`. It is a **Draft and not approved**. Two
  approvals (06:19Z and 09:14Z) are kept as historical in `intent.yaml`; both were superseded by
  scope changes or audit fixes.
- **Baseline:** main `7ed41f66` (isolated-candidate-workspace). The checkout was clean when this was
  written.
- **Launch after approval:** `mix kogen.build --route claude-dominant-adversarial-codex build-reliability`.

## Package now
26 scenarios, 2 paid targets (`live-shaping-smoke`, added by this Intent, and `live-reviewer-rework`),
all guarded paths covered, risk links and `verified_by` targets valid (checked with YamlElixir,
2026-09-26 continuation). Every probe is listed in `evidence/PROBES.md`.

## Continuation 2026-09-26 (10:02Z visit)
- The Shaper's principle: flexible enough that ordinary changes pass, strict enough that code
  quality stays high. Recorded in INTENT.md "Flexible rules, kept quality" and questions.md.
- Audit items 1-6 folded as five scenarios after probes (evidence/probe-rigidity):
  `test-catalog-binds-declarations`, `config-checked-by-reader`,
  `docs-and-prompts-checked-by-meaning`, `hooks-checked-by-behavior`,
  `helper-make-targets-allowed`. New risks `self-hosting-relaxations` and `quality-floor`.
- Items 7, 8 and the "consider or defer" list are non-goals (INTENT.md).
- The Shaper asked for Astra medium, Sol high and Opus high reviews of the whole Intent.
  Their answers and the dispositions go in `evidence/review-2026-09-26/`.

- Reviews done; findings verified and applied (`evidence/review-2026-09-26/DISPOSITIONS.md`).

- The Shaper split out the Build status output and `--notify` (evidence/split-build-status-notify);
  everything else stays. 26 scenarios.

## Next steps
1. Ask for approval only when the Shaper directs the conversation there.

Remove this file at approval; it is session bookkeeping, not contract.
