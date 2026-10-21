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
