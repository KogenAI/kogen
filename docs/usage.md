# Retained prompt usage

`kogen intent usage [RUN-ID] [--lineage] [--project DIR] [--json]` reads local
retained evidence, without credentials, the core, inference or account queries.
The project is one canonical Git checkout (current checkout by default).
Without a run ID it scans bounded Build, Shape and refinement history. A run ID
selects one attempt; `--lineage` includes its root and descendants and requires
an ID. This is observation, never authorization to resume.

Exact filters: `--slug`, `--phase`, `--role`, `--model`, `--effective-model`,
`--effort`, `--effective-effort`, `--outcome`, `--pass`, `--repair`.
`--since` is inclusive and `--until` exclusive, both UTC RFC3339 (ending in Z).
Unknown timestamps/fields do not match filters; timestamps never come from mtime.
Configured model/effort are not evidence of effective model/effort.
`--group-by` accepts comma-separated project,slug,lineage,phase,role,model,
effective-model,effort,effective-effort,outcome,pass,repair; default phase,role.
Unknown group values are null.

`--limit 1..100` defaults to 20 and bounds displayed rows, not totals. Rows sort
by descending timestamp, then source path/line. `omitted_rows` discloses the rest.
Discovery reads only immediate directories in `.kogen/local/runs`, `shaping` and
`refinements` (10,000 per root), never recursive projects, archives or symlinked
run directories. Scans are bounded by 256 MiB and 100,000 attempts; oversized lines (over
4 MiB) are skipped so good neighbors remain usable.
Malformed lines do not discard good neighbors. Missing/damaged evidence is
listed in sorted `limitations`; caps set `truncated:true`. Checkpoints, tool
bodies, review totals and cumulative usage are not request ledgers.

JSON uses the facts envelope, one object/newline:
`{schema_version:1,kind:"usage",checkout,data,error}`. `data` contains scope,
totals, groups, requests, limitations, truncated and omitted_rows. Empty history
is success. Exit codes: 0 success (including partial evidence), 1 unknown run,
2 argument error, 3 unavailable project. Requests expose only safe analytical
metadata and source provenance, never raw events or opaque continuation.

Totals count transport attempts once. Logical request summaries linked by
operation ID are not added again. Nonempty response IDs deduplicate copied
observations; conflicting same-ID usage is inconsistent and excluded, with all
attempt provenance retained. Legacy requests lacking IDs remain separate and
are disclosed. Summary-only history does not manufacture requests.

`known_*` sums only supplied validated counts; `unknown_fields` counts missing
or inconsistent observations per token category. Missing write counts are not
zero writes. `unknown_usage` means missing input/cached/output/reasoning or
inconsistent usage. Reasoning is a subset of output; cached and writes are
disjoint subsets of input. When all write lifetimes are known they must sum to
total writes. Inconsistent rows are labelled, not clamped.

`cached_input_percent` is 100 × sum(cached) / sum(input), over rows with both
counts valid; it is null at zero denominator. `paired_input`, `paired_cached`
and `paired_requests` disclose denominator and coverage. Percentages are never
averaged. Zero hits require known positive input and cached=0. Response wall
milliseconds are separate from retained measured phase durations. Phase wall
is reported for unfiltered scope or phase-only selection when measurements exist;
role/model/date slices without corresponding phase measurements are null with a
limitation, never inferred from response time. Miss categories are provider
classifications, not explanations inferred from local fingerprints.

## Best-effort reuse, correctness independent

Supported documented GPT-5.6+ routes request implicit 30m caching. Unchanged
policy is an initial developer input_text block; the complete stable contract
is a separate block in its original role, before changing evidence. These two
explicit breakpoints plus the implicit slot use three of four writes. No filler,
prewarm, cache key, model/effort switch or extra inference is used. Public
Responses stays `store:false,stream:true`, with full manual replay, including
valid encrypted reasoning and assistant phase; no server conversation loading.
Responses requests include `reasoning.encrypted_content` so stateless continuation
can retain the returned opaque item rather than relying on stored server state.

Comparison uses the latest validated completed response ID only within that
independent conversation. New reviewers do not inherit builder state. Saved
continuation retains capability and comparison through safe resume. Old v2
checkpoints default optional cache metadata to unknown; all existing exact
approval/tree/index/tool uncertainty checks remain mandatory.

Earlier/unrecognized models omit controls and markers. A definite nonexecuting
400 naming cache controls allows one compatibility retry with identical content,
authority, model and effort, sharing the absolute deadline. Unsupported state is
retained. Unrelated refusals and uncertain stream execution never cause a
cache-stripping replay. Missing or malformed optional diagnostics need no retry.

`applied` records accepted controls, not a physical write, hit, or proven TTL.
Effective configuration and applied TTL are null absent response evidence.
Policy/tools/schema/contract/prefix fingerprints are **local UTF-8 byte** hashes,
not provider tokens, rendered prompts or cache facts. IDs are analytical
identifiers, not bearer authorization. Analytical evidence excludes prompts,
tool bodies, credentials and encrypted continuation (which remains solely in
existing conversation/checkpoint custody).

12h provider write counts are retained. Enabling 12h later requires measured
stable cross-gap reuse and exact account acceptance; its write rate is 2.5x,
not 30m's 1.25x. TTL is not a deletion deadline. Synthetic loopback fixtures do
not prove live account support. This report is not an account ledger or weekly
quota conversion, and promises no percentage, speed or dollar savings. Cache
reuse never substitutes for inference, tools, verification, independent review
or authorization. Combining exported reports is not automatic account accounting.

## Retained observations and summary coverage

Successful reports also include `data.coverage`, separate from retained totals
and groups. Native Build `result.json` files are read alongside the canonical
logs, within the same byte/directory bounds and regular-file checks (each result
is at most 4 MiB). Neither `usage` nor `attempt_usage` from a result is added to
retained tokens. Results, logs and other historical evidence are never rewritten.
Context and completion do not perform these usage scans.

Coverage exposes:

- `retained_attempts` and `retained_unknown_attempts`: selected, deduplicated
  physical attempts and their existing `unknown_usage` count, before display
  limiting. These are not logical failure counts.
- `completed_operations`: distinct operation IDs with a selected completed
  physical attempt, or null when selected rows lack the necessary identities.
  A failed compatibility attempt followed by completion counts as two physical
  attempts and one completed operation. Legacy rows get no invented IDs.
- `summary_unknown_requests`: the applicable native unresolved logical-request
  counter, or null when comparison is unavailable or cannot be attributed.
- `unrepresented_unknown_requests`: applicable summary uncertainty minus retained
  unresolved operations (failed/cancelled evidence with an actual operation ID
  and no completion in the covered chain). Completed fallback operations and
  legacy completed rows do not represent unresolved requests. Unidentified
  failures, conflicting evidence or contradictory subtraction yield unknown,
  never a clamped residual.
- `status`: `reconciled` only when that counter comparison is available, attributable
  and leaves no residual; otherwise `uncertain`. Reconciled does **not** establish
  complete usage, token knowledge or billing coverage.
- `summaries`: safe Build evidence sorted by run ID, containing `run_id`,
  checkout-relative canonical `source`, nullable `unknown_requests`, `outcome`
  and `provider_failure_code`. Identifiers are bounded analytical values, not
  provider prose. Missing/invalid counters are null, not zero. Results declaring
  a different Build identity are not matched and disclose a limitation.
  `omitted_summaries` reports display omissions: `--limit` bounds summaries
  separately from request rows, while comparison uses all selected evidence.

A standalone root result applies to its run. Resumed results inherit a cumulative
counter; a fully selected, established linear root-to-leaf chain uses its terminal
counter once, matching unresolved operations across the chain by their IDs.
Independent established roots can be combined. An isolated child, branching,
missing ancestry or conflicting identities cannot allocate inherited uncertainty.
Unrelated summaries are not assigned to a selected run. Copied attempt provenance
is retained for this comparison: copies within a chain count once, while an
operation evidenced in independent roots prevents treating those counters as
nonoverlapping. No timestamp or lexical run ordering establishes ancestry or
chooses a branch.

Role/model/effort/outcome/pass/repair/time (and phase) filters still select retained
rows exactly as before, but do not allocate run-level uncertainty to that slice.
Available summaries remain visible with null comparison counts and
`summary_scope_unattributed`. A matching known slug can establish run scope;
unknown fields cannot establish a match. A row identity that conflicts with its
canonical run or known run slug prevents allocation even if a filter hides that
row. Damage in a known unrelated run's log is not assigned to a matching slug's
scope. Groups remain retained-row aggregates.
Missing/damaged/capped evidence, including empty history or an absent summary,
is not proof of zero unobserved calls. Sorted limitations include
`summary_coverage_unavailable`, `summary_usage_unrepresented` for a known positive
residual, and `summary_scope_unattributed` for uncertain allocation, alongside the
existing legacy/unknown-field disclosures.

Human output labels the same distinction explicitly:

```text
Retained attempts: N; unknown usage attempts: U; completed logical operations: C
Summary unknown requests: S; unrepresented unknown requests: M; reconciliation: STATUS
Coverage summary: <JSON>
Omitted summaries: N
```

Nullable counts print as `unknown`. In particular, 84 retained completed legacy
rows with retained failed=0 and unknown_usage=0 can coexist with a native
`context_exhausted` result, `context_length_exceeded` provider failure code and
summary unknown_requests=1. This reports one unrepresented unknown request,
without adding a failed row or changing known token sums. Retained failed=0
never establishes absence of run failures. Summary-only evidence adds no
physical failure, completion, request or token totals. Legacy write counts and
lifetimes remain unknown even when aggregate known-write sums are zero.

## Image evidence and request accounting

Explicit `view_image(path)` in Shape, Build and independent Review supplies one
validated static non-interlaced RGB8 PNG (1..131072 bytes, dimensions 1..2048).
The exact selected bytes are frozen in typed function output; shell/read_file and
browser capture/export remain distinct text/artifact operations. Metadata records
read-time candidate when known, not capture provenance inferred from a filename.
Capture candidate, route, viewport and fixture state otherwise remain `UNKNOWN`.

The complete outbound JSON includes base64 overhead and typed envelopes in the
524288-byte inclusive limit with 131072-token reserve. Multiple invocations are
subject to this request budget, not a new setting or total-run cap. Oversized
irreducible input stops before inference: prepare a smaller supported image externally
or use ordinary Refine/new approval. Provider errors below the proxy remain failures.
Frozen private replay/checkpoint bytes are not reread from changed/deleted paths.

`image_read` facts mean successful selection only. `image_delivery` facts identify
logical image-bearing requests and report completed only for validated completed
responses, failed for explicit rejection, unknown for uncertain transport. Bounded
metadata events contain no data URLs/base64 or opaque reasoning. Explicit fallible
observations remain assistant content in private replay; none of these events grants
visual/design approval or bypasses checks. Fresh Review inspects its own pixels.
