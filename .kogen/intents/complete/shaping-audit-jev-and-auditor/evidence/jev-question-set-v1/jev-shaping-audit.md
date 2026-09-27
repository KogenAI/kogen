# Jev in the Shaping audit: validated question set (v1)

Written 2026-09-25 by a driver subagent. Status: **advisory-first**, calibrated on
real and planted Drafts. Model `jev-1.13.0`. Question wording version:
`shaping-audit-v1`.

Sources: the Jev guide (`Areas/ChatGPT Work/artifacts/jev-guide/{README,COOKBOOK}.md`),
`lib/kogen/jev.ex`, `priv/kogen/prompts/shaping.md`, a read-only design review by
GPT-6 Sol high and GPT-6 Astra medium (`jev-trials-2026-09-25/sol-gpt-6-sol-high.md`,
`astra-gpt-6-astra-medium.md`), and about 2,050 real Jev requests (2.4M input
tokens, **$0.10 in total**). All raw requests and responses are in
`jev-trials-2026-09-25/raw/` and `real-packages/`.

## The short version

1. **Ask about one scenario at a time, and one clause or one wrong-result
   alternative at a time.** Code splits `then` into clauses, `wrong_result`
   into alternatives, and `evidence` into items. The whole-package Noul
   questions used so far don't discriminate. "Is the `then` observable?" over
   the whole `scenarios.yaml` returned 0.13–0.44 for every real *and* every
   broken scenario. "Plausible and caught?" returned 0.86–0.93 for all of them.
2. **Ask Jev to pick the evidence item that catches a mistake, rather than
   asking "is it caught?".** A Choice over the `evidence` items plus `none`
   never chose `none` for a caught mistake (0 of 12). Together with a strict
   Noul, it flagged 7–9 of the 9 uncaught ones.
3. **Nine questions work** (table below). They cover clause observability,
   clauses without described proof, uncaught wrong results, the hard rules
   (timeout, effort, weakened checks), outcome coverage, non-goal leakage,
   questions provenance, finding dedupe across auditors, and whether a
   revision addresses a finding. Most were right on every labelled case at
   their gate. Paid-target necessity and citation checks work only with the
   reformulations below.
4. **Four ideas don't work, so drop them:** "is this finding blocking /
   advisory / not a defect" (it can't see that the Draft already handles
   something), risk-to-scenario linkage, one-Build scope Score, and anything
   that needs a baseline value or arithmetic.
5. **Cost and speed.** A full audit of a 7–12 scenario Draft takes 40–210
   requests and 40k–240k input tokens, which is **$0.002–$0.01**. Latency is
   p50 about 1.1 s and max 7 s per request, so with 12 in parallel a whole
   audit finishes in about 15 s. Repeats are stable: across two full runs, only
   choices below confidence 0.4 flipped.
6. **The driver can use it today:** `python3 plan/tools/jev_audit.py
   <package-dir> <out-dir>` runs the v1 set and writes `jev-audit.md` (flags)
   and `jev-audit.json` (every exchange).

## Boundary: what Jev receives

- Default: **Draft contract text only.** That is `scenarios.yaml` fields,
  INTENT.md's Outcome and Non-goals sections, `questions.md` entries, and
  auditor finding text. Never a diff, Candidate files, working-tree bytes,
  `evidence/`, or transcripts.
- **Citation checks send code.** Excerpts of cited lines of git-tracked files
  read from `HEAD` are not the diff or Candidate files that Kogen's README
  promise names. They are still repository source. Sol and Astra both say this
  needs an explicit opt-in. Recommendation: make it a documented default of
  the audit command with a `--no-source-excerpts` switch, and add a README
  sentence next to the Build promise. Read excerpts from `HEAD` (as the Draft
  already requires), never from the working tree. During this study the main
  checkout's working tree *was* a Candidate (a Build was running). That makes
  the `HEAD` rule concrete, not theoretical.
- Keep each request state small and single-hop. Jev reads literally, and
  long unrelated context lowers confidence.

## Validated question set v1

The exact bytes are in `plan/tools/jev_audit.py`. Every question keeps its full
distribution in the report. "Gate" means *raise an advisory finding*.

| # | Finding id | Primitive and state | Options / criteria (short) | Gate | Calibration result |
|---|---|---|---|---|---|
| 1 | `then-unobservable` | Choice per `then` clause; state = the one scenario + indexed clauses | `observable` / `unobservable` (quality, feeling, improvement with no measure) / `not_behaviour` (scoping note, reference to another Intent) | `unobservable` ≥ 0.80 | Planted 3/3 at 1.00 (e.g. "Codex Reviews become noticeably faster", "Hybrid routes feel natural…"). 0 of 64 real clauses flagged. `not_behaviour` correctly tags "This Intent claims only…" notes, which code then excludes from other questions. |
| 2 | `then-without-described-proof` | Choice per clause, same request as 1 | `asserted` / `partly` / `not_described` by `evidence` + `proof.offline` | `not_described` ≥ 0.80 and clause not `not_behaviour` | Planted 4/6 (0444 mode 0.93, timeout 1.00, two unobservable clauses 1.00 and 0.82; missed a vague clause at 0.43 and the weakened-assertion clause at 0.28). On real packages it found true gaps: `fixture-outside-checkout` "asserts … logged-in … login scope" (0.92), `superseded-objection` "Readings below the threshold are unchanged" (0.92), and 3 in `isolated-candidate-workspace`, 14 in `fortify`. `partly` is noise; ignore it. |
| 3 | `wrong-result-not-caught` | Two questions per wrong-result alternative: a Choice over `evidence_items` e0..en + `none`, and a strict Noul ("names an assertion, negative control or case that directly checks it; a general or happy-path test does not count"). Batch all alternatives of a scenario in one request (`wrong_behaviours.wN`); that tested as well as or better than one request each | — | **strong:** Choice `none` ≥ 0.5 **and** Noul < 0.6. **weak:** either one | Labelled set of 21 (12 caught, 9 not). One request per alternative: strong 6/9 recall, either 8/9, 0/12 false. **Batched per scenario: strong 7/9, either 9/9, 0/12 false** (`t7-r1.json`). On real Drafts, strong flags were real gaps (missing login found only after a paid launch, the prompt steering the Reviewer away, an edit to the shared `live_rework_audit.ex`, reviewer.md edited). The weak tier had some noise on the preflight Draft (3 weak, 0 strong). |
| 4 | `wrong-result-implausible` | Choice per alternative, same request as 1 | `plausible` / `implausible` / `not_a_mistake` | non-`plausible` ≥ 0.80 | Planted "rewrites the Codex harness in Rust" 1.00. Softer plants were missed ("too slow" 0.39, "path printed in console" 0.26). 0 real flagged. Low recall, no false positives. Cheap, so keep it. |
| 5 | `hard-rule-risk` | Three Nouls per clause, state `{clause}` alone: timeout raised/extended; effort lowered or weaker model; existing assertion/validator/check removed or loosened | literal criteria with the negation spelled out ("stating that they stay unweakened is false") | any ≥ 0.75 | Planted: timeout 0.98, effort 0.97, weaken 0.88 / 0.77 / 0.87. Negations were handled: "Timeouts are unchanged" 0.02, "none of their assertions is weakened" 0.03. On `fortify` it flags 4 deliberate loosenings at 0.78–0.89 ("Admission no longer requires a `check` target", "catalog no longer byte-frozen"). That is correct: a Shaper should confirm those. **Blind spot:** "per-turn limit … 300 s" scored 0.10, because the old 240 s isn't in the clause. A raise relative to a baseline must be stated in the clause, or code must compare numbers. A 4th Noul (retry added) is informational only, ≥ 0.9, because it fires on legitimate designs. |
| 6 | `outcome-without-scenario` | Choice per INTENT Outcome item over scenario ids + `none`; state = outcome items + each scenario's `then` | "directly states this outcome's result"; topic mention is `none` | `none` ≥ 0.80 | 20/20 across the full package and three packages each with one scenario deleted. Deleted scenario → `none` at 0.95–1.00. Every other outcome was mapped to the right scenario at ≥ 0.96. |
| 7 | `non-goal-leakage` | Choice per scenario over the Non-goals items + `none` | "requires the excluded behaviour itself; mentioning or promising not to do it is none" | non-`none` ≥ 0.60 | 10/11: 3 of 4 plants caught at 0.71–0.85 (Makefile target, read-only sandbox, timeout raise). Missed "other fixtures also move" (none 0.70). 0 false on 7 real scenarios. |
| 8 | `question-unresolved` / `question-without-provenance` | Choice per numbered `questions.md` entry | `with_provenance` / `without_provenance` / `unresolved` | non-`with_provenance` ≥ 0.80 | 8/8 at 0.89–1.00. |
| 9 | `paid-observation-offline-checkable` | Choice on the `observation:` text code parses out of `paid_reason`, alone in state | `provider_only` (model choices/tool calls, latency, real auth, runtime acceptance) / `offline` (Kogen's own args, files, sizes, hashes, decisions) | `offline` ≥ 0.80 | 11/12 overall. Planted unnecessary paid targets were caught at ≥ 0.8 for 3 of 6 ("record has no inline self copy", "hashes match", "packet ≤ 65,536 bytes"). The rest were low-confidence correct or wrong. 0 of 6 real provider observations flagged. For scenarios with `paid_target: none`, add a Choice per behaviour clause (`offline` / `provider_only`, gate `provider_only` ≥ 0.9). It correctly flagged "The Build's own live-native run passes" (0.94). |

Questions for the audit loop (driver practice now; Kogen code in the
follow-up `adversarial-shaping-auditor` Intent):

| # | Use | Primitive and state | Gate | Calibration result |
|---|---|---|---|---|
| 10 | **Dedupe findings across auditors** (Sol vs Astra) | One request: all findings of both. Per Sol finding, a Choice over Astra ids + `none` ("same broken mechanism; sharing a file or topic is not enough") | ≥ 0.5 | 12/13. The one miss was at 0.39. All 8 true pairs were found at 0.72–1.00. |
| 11 | **Does the revision address the finding?** | Per (finding, revised scenario): `addressed` / `partly` / `not_addressed` | `not_addressed` ≥ 0.6 → still open | 26/26 (13 true fixes, 13 unrelated pairings). This closes the fix loop cheaply before a second Sol/Astra round. |
| 12 | Finding severity (ordering only) | Per finding: `blocking` / `advisory` / `not_a_defect` | never gates | 36/46. Blocking recall was high. It **cannot** detect `not_a_defect` (Sol 1 and Astra 1 → blocking at 0.86–0.98), because that needs the Draft. It partly copies the auditor's own label: stripping the label lowered confidence. Use only to sort the human's reading order. |

Citation checks (with the source opt-in):

| # | Finding id | Primitive and state | Gate | Calibration result |
|---|---|---|---|---|
| 13 | `citation-contradicted` / `citation-insufficient` | Choice per (claim, ≤ 40 numbered `HEAD` lines): `supported` / `contradicted` / `insufficient` | pass only `supported` ≥ 0.85; anything else is a finding | 17/20. At ≥ 0.85 no wrong `supported`. Misses: an absence claim ("sets `tool_output_token_limit` to 4000" over a list without it) → `insufficient` 1.00, which is the safe side. Arithmetic: "40-minute timeout" against `timeout: 1_200_000` → `supported` 0.27, and even the true "20-minute" claim only reached 0.51. So normalise units in code, or cite the literal. |

## Rejected or demoted, with evidence

- **Whole-scenario "is `then` observable by the proof?" Noul** (the current
  `jev_scenarios.exs` question): real 0.13–0.44 and planted 0.10–0.43. It
  doesn't discriminate. Replace it with questions 1 and 2.
- **"`wrong_result` plausible *and* caught?" Noul.** Conjunctive; every
  scenario scored 0.86–0.93. Replace it with questions 3 and 4.
- **Whole-scenario paid Choice** (`offline_sufficient` / `provider_required`
  over the full scenario). Text that *mentions* providers or other Intents'
  live targets misleads it. `codex-tool-output-limit` (offline by design) →
  `provider_required` at 0.79–0.98. Replace it with question 9.
- **Finding disposition as a gate** (question 12). Advisory ordering only.
- **Risk ↔ scenario linkage.** It works for failure-mode risks (4/4 at 1.00),
  but it calls constraint risks (`no-timeout-change`, `self-hosting-freeze`)
  `unrelated` at up to 0.94. Those risks are rules, not tested behaviour. Drop it.
- **One-Build scope Score.** Real packages scored 0.7–1.4 on a 0–3 scale,
  in no useful order. A two-package merge scored 0.92 and only a three-package
  merge stood out (0.19). Scope stays with Sol/Astra and the Shaper.
- **Anything needing a baseline or numbers** (was a limit raised? how many
  receipts? what pass rate?). That is deterministic code.

## Thresholds and rollout (advisory-first)

- Every Jev finding is **advisory** in the first release. An unavailable Jev
  makes the audit `not_ready` (never a silent pass). A Jev answer is never
  the only reason for `ready` or for `not_ready`.
- Promote a question to blocking only after two rounds of real audits in which
  it has ≥ 0.9 precision at its gate on held-out Drafts, and no false block of
  a Draft that later built cleanly. The likeliest candidates are
  `outcome-without-scenario` (6), `then-unobservable` (1) and `hard-rule-risk`
  (5, timeout and effort only).
- Log with every answer: the model, the wording version, the full
  distribution, the gate and the decision. Re-calibrate on any change to model,
  wording, state construction or gate.
- Never reuse the Build handoff threshold (0.85). It was calibrated for a
  different question.

## How a Kogen implementation should build requests

- Split in code: `then` clauses (sentence or `;` boundaries), `wrong_result`
  alternatives (`;`, "; or", ". Or"), `evidence` items (`;` and sentence
  boundaries), INTENT Outcome items and Non-goals (top-level `-` or `N.`
  items), `questions.md` numbered entries, and the `observation:` part of
  `paid_reason`.
- Per scenario, two requests: (a) questions 1, 2, 4 and the three hard-rule
  Nouls of 5 for every clause and alternative, addressed by index
  (`then_clauses.cN`, `wrong_result_alternatives.wN`); (b) question 3 for
  every alternative, with the evidence items. The batched hard-rule and
  caught forms were checked against the single-question forms (`t7-r1.json`):
  hard-rule decisions were identical, and caught was equal or better.
  (`plan/tools/jev_audit.py` still uses the single forms.)
- Package level: one request for 6, one per scenario for 7 (or all scenarios
  in one), one per `questions.md` entry for 8, and one per paid scenario
  for 9. Total: about 2 requests per scenario plus 3–10, all independent, so
  run them with bounded concurrency. Bounds: state ≤ 32k tokens, request
  ≤ 64 KiB. Split, never truncate silently.
- Parse both answer shapes: Choice `{choice, confidence, probabilities}` and
  Noul `{type: "noul", noul: p}` (no confidence field). `Kogen.Jev` today
  parses Choice only.
- Validate every returned option id against the ids sent (evidence items,
  scenario ids, non-goal ids).

## What could not be confirmed

- Recall on *natural* defects is measured on a small set: the 23 Sol/Astra
  findings, 5 real packages, and planted variants. The planted cases are
  written by the same author as the questions.
- The "real gap" judgements for flags on real packages are this author's, not
  the Shaper's.
- Citation checks were tested on 20 claims over 7 files. Longer or noisier
  excerpts are untested.
- `jev-latest` was not tested. Pin `jev-1.13.0`.
