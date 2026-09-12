# Rework-session comparison v2 — results

## Result

Both arms repaired the same Candidate correctly. The independent oracle accepted
all 11 semantic checks for each arm, both disputed the misleading whitespace
suggestion, and both produced byte-identical final `auth.py` files. The resume arm
finished 10.84 seconds (11.7%) faster. The fresh arm used 32,982 (15.7%) fewer
input tokens. This modest-context contrast demonstrates a real tradeoff rather
than a universal winner.

| Measured repair | Correct | Wall time | Input | Cached input | Output | Reasoning | Requests |
|---|---:|---:|---:|---:|---:|---:|---:|
| Exact seed-session resume | yes | 81.96 s | 210,636 | 196,992 | 2,755 | 451 | 7 |
| Genuinely fresh + factual handoff | yes | 92.79 s | 177,654 | 158,080 | 3,384 | 597 | 8 |

Resume usage is the exact delta between its final cumulative thread counters and
the seed counters. Fresh usage is its own thread total. Recorded native counters
include cached input within input; the columns must not be summed. No currency or
subscription-allowance cost was exposed.

The common seed investigation cost 115.93 seconds and 289,410 cumulative input,
227,584 cached input, 3,919 output, and 633 reasoning tokens. It is shared setup,
not occupied context and not charged to either measured repair row.

## Correctness and behavior

The oracle verified:

- ordinary match allows and wrong/missing values deny;
- ASCII header casing is accepted;
- leading/trailing whitespace remains accepted;
- equal duplicates and conflicting duplicates in both orders deny;
- legacy mode cannot bypass missing or wrong requirements;
- the `authorize(headers, required)` signature remains;
- the rejected direct dictionary-comprehension collapse is absent; and
- each arm's public unit suite passes.

Resume added four focused regressions and passed 8 public tests. Fresh added six
and passed 10, additionally covering unrelated duplicate headers and significant
internal whitespace. These extra tests did not change oracle acceptance. Both
changed only `auth.py` and `test_auth.py`; each used one native file-change event.
The final implementation hash for both was
`b1db7f2c1bcf5981c60e6e060a524a30723fff9393d99d4c152ab48dab7f33e6`.

## Matched baseline and handoff

Both arms began at Git HEAD `c70f5cc27ffb6b2631fa10db8a3c926a7cdf62b6`,
with Candidate hash
`25cd41ae86c9a6d822d164b05b6f76ebc15b5b53ad70e2ccd6a767ac9bbab78c`
and contract hash
`fd6a14ba96b8aeea75029c63df2fb4582171c91e4b096578457d0101cefc22a5`.
Both Git roots were clean after the seed. The retained complete file-hash lists
have identical hash sequences before repair; paths differ only by root name.

The resume prompt was 1,060 bytes. The fresh prompt was 3,276 bytes and contained
the observable baseline identity, the seed Developer's public final record, and
the frozen review packet. `generate_handoff.py` reads only those three sources;
it records zero private-reasoning sources and zero model calls. Generation took
462,166 ns. The exact generated prompt and SHA-256
`305193b1178ce6de33ffcfb1baa09fc6f6892206ea3c1a50785bd093a93e5bbd`
are retained.

Both arms received the same two real blockers and the same misleading reviewer
suggestion. Neither received repair code. The seed public record preserved the
accepted early decisions, rejected and superseded approaches, relevant incident
evidence, ruled-out distractions, observed failures, tests and uncertainties.

## Native identity, context and cleanup

- Seed and resume were exact session
  `01a08f2d-2721-79a1-930a-cecbd3bcf750`.
- Fresh repair was new session
  `01a08f31-80a2-7702-a1b3-fdf9f29fd8dd`.
- All measured turns used `gpt-5.6-sol` at low effort with Kogen's enabled-hooks,
  hook-trust-bypass, and approvals/sandbox-bypass flags. User config was loaded
  and never modified.
- Seed contained 13 meaningful requests spanning decisions, compatibility,
  rejected history, incidents, logs, code/history, tests and focused probes.
  Per-request input rose from 18,432 to 25,488 tokens.
- Resume per-request input was 27,674, 28,561, 29,382, 30,352, 30,809, 31,526,
  and 32,332 tokens.
- Fresh per-request input was 18,838, 19,182, 20,730, 21,932, 22,819, 24,531,
  24,712, and 24,910 tokens.
- No helper, child session, or native compaction event was observed. Compaction
  was not forced.
- Every completed measured receipt reports exit 0, no timeout, and no surviving
  owned process group.

This is therefore a modest-context comparison. The cumulative seed input total is
request usage, not a 289K-token occupied context. It does not answer behavior near
compaction or after natural compaction.

## Preflight and retained invalid provenance

The first mechanism preflight is retained under `preflight/` but rejected because
it used `--ignore-user-config`, unlike Kogen production. The corrected
`preflight-v2/` used the actual production common flags. Fresh and exact resume
both wrote their markers in session `01a08f2b-a02b-7bd0-87a3-7eea7add7db0`,
exited 0, and reported no cleanup survivors. The known-bad oracle control failed
the intended defect checks; the known-correct control passed all semantics.

One attempted measured seed began while an oracle-created `__pycache__` made its
fixture dirty. It was stopped immediately before any model response or token-usage
event and retained under `runs/seed-invalid-dirty-baseline/` as session
`01a08f2c-c0d0-7873-8170-3e336afee3ff`. A subsequent process check found no
survivor. The cache was removed, clean status re-established, and the valid seed
was launched once. A malformed local launch command for the fresh arm was refused
by the path guard before any provider process started; it created no run artifact.

## Interpretation

For a localized repair after a useful session with roughly 25K–32K request
context, exact resume retained enough context to finish faster and with fewer
output/reasoning tokens. A concise fresh handoff reached identical implementation
correctness with lower input usage and slightly broader regression coverage.

Advisory: keep exact-session resume as the default for modest, productive context,
because it was faster here and preserves Kogen's existing provenance model. A
fresh Developer with a generated factual handoff remains credible when input cost
matters or when a session is polluted or unusable. Do not set a context threshold
from this run; combine it with separate long-context and compaction-retention
evidence before changing lifecycle policy.

This native fixture did not run Kogen's Stop hook, `make check`, outer targets,
independent Reviewer, or publication. Its oracle establishes the declared repair
semantics only.
