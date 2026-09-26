# Whole-Intent review, 2026-09-26 (continuation visit)

Requested by the Shaper: "use astra medium, sol high, and opus high to review your
work, the whole intent". One shared read-only question (`question.md`), run at
7ed41f66 on the Draft with 28 scenarios:
- Astra: `gpt-6-astra` medium via the Shaper's `plan/tools/codex.sh astra`
  (managed Codex 0.156.1) → `astra-medium.md`;
- Sol: `gpt-6-sol` high via `mix kogen.expert` (the route's Expert) → `sol-high.md`;
- Opus: `claude-opus-5-5` high via headless `claude -p`, tools limited to
  Read, Grep, Glob and git log/show → `opus-high.md`.

Only the final answers are kept; raw harness logs stay in the scratchpad. The
Shaping root checked every applied finding against source bytes at 7ed41f66.

| Finding | From | Verified | Disposition |
|---|---|---|---|
| Removing a stale catalog row requires editing `priv/kogen/test-reliability-remediation.yaml` (`validate_remediation/2`, `test_reliability_catalog.ex:33-51`), which was not guarded | Opus B1 | yes | Guarded; added to `affected_paths`; the scenario says removals update it |
| The generator copies declarations from an ignored runtime matrix (`generate_test_reliability.py:14,66`), so "the generator reads full names" is unmeetable | Opus B2 | yes | Clause dropped; the two rows are repaired by hand; REPORT §1 corrected |
| "Every backticked path exists" fails on today's README (`.kogen/build.lock`, `deps/`, runtime paths, short module aliases) | Opus B3 | yes (README :84-86, :109, :206, :557) | Rule defined: fixed path prefixes, placeholders, globs and runtime locations skipped, file-system based, short aliases resolve to exactly one `Kogen.*` module |
| INTENT says rehearsals.exs requires `prepare` on every live target, contradicting the three-target scenario | Opus B4 | yes (INTENT :92) | Reworded to "rehearsing every declared `prepare`" |
| At 7ed41f66 the controller renders prompts from control (`build.ex:2260-2262`, `:2312-2314`); risk, scenario, INTENT and README said Candidate | Opus non-blocking | yes | Risk `self-hosting-review`, `per-launch-verdict-schema`, INTENT corrected; README fix assigned to `docs-and-prompts-checked-by-meaning` |
| Git-based tests must skip in gitless `cold-offline` | Opus non-blocking | yes (`offline.py:144-156`) | `no-tracked-caches` skips with a reason; the doc path rule reads the file system |
| Stale text: defect (d) destination, Q3 vs custody edits, `build_prerequisite`, 9ff7af6e | Opus non-blocking | yes | Corrected or annotated as historical |
| Smoke never run through `make` in a Build; 156 s vs a 300 s bound | Opus non-blocking | yes | Risk `smoke-timing`; bound not raised |
| `proof.base` is not enforced (catalog has no integrity fields) | Opus non-blocking | not re-checked | Noted; Review assesses the `base` claims |
| REPORT §5 lists prompt rendering as a Candidate caller | Opus non-blocking | yes (`build.ex:2223` loads control) | REPORT corrected |
| `no-tracked-caches` deletes evidence files missing from `affected_paths` | Astra | yes | The three guard globs added to `affected_paths` |
| Owners of unselected live targets are editable under `test/kogen/**` | Astra | known | Unchanged; risk `owner-edit-selection` already assigns it to Review |
| `offline_retries` enforcement is only for the Candidate and later Builds | Astra, Sol 1 | known | Already in `self-hosting-accounting`; `self-hosting-relaxations` now states that controller-side changes are proven by the Candidate's offline tests only |
| Main's Review can't get `receipt` | Astra | known | Already in `self-hosting-review` |
| Helper Make targets are only fixture-proven | Sol 2 | yes | Same clarification in `self-hosting-relaxations`; this Candidate adds none |
| Receipt catalog digest and `source_sha256` consumers after the change | Sol 3 | yes (`offline.py:158`) | Assertion added to `test-catalog-binds-declarations` |
| Appetite: 28 scenarios in one Developer conversation | all three | — | **Open for the Shaper** (questions.md) |

## Confirmation pass (Opus high, after the fixes and the split; `opus-high-confirm.md`)

No blocking items. Applied after root verification: the doc path rule skips
`.kogen/codex` and `.codex/sessions` (cited in README :206, shaping.md :221); the
no-tracked-caches test skips entirely without Git, since cold-offline also
excludes `.kogen/intents` (`cold_offline_test.exs:36-40`); `declaration_count`
is checked against the rows rather than pinned to 346; the garbled `prepare`
sentence repaired; the duplicated appetite text and `184-271 s` fixed;
citations corrected (`build.ex:2260-2262`, `generate_test_reliability.py:66`,
`contract.ex:154-158`); Q2 and the Assumed items annotated. Rejected: "the
catalog key is `depends_on`". The catalog file uses `dependencies`, which the
loader maps to `depends_on` (`verification_plan.ex:405`).
