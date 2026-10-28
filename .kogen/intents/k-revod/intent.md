# Add review_material on-demand reading lever

Slug: k-revod
Model: not applicable — a configuration lever and a choice of what the reviewer's opening message carries; no interacting state machine
Acceptance:
- .kogen/intents/k-revod/acceptance.feature
- features/steps/krevod_steps.js
- features/steps/krevod_driver.go

Add the optional `.kogen/project.yaml` key `review_material: {mode: parts | on_demand}`. Absent or `parts` is exactly today's behaviour. The default is off; the mode is experimental. This is the K-REVOD lever: on long reviews the candidate source overflows the working window and moves into private, hash-bound pinned parts of about 6 KB (`cli/build/material.go`) that the reviewer must read in full before any verdict (`cli/build/review.go`). With `on_demand` the reviewer instead gets a manifest and reads what it needs.

## Configuration (cli/project/config.go, docs/configuration.md)
`Config.ReviewMaterial.Mode` is `parts` when the key is absent. Validation follows `shape_audit`/`shape_decision_check`:
- `review_material` not a mapping: `line N: review_material must be a mapping`.
- Any key other than `mode`: `line N: unknown key <key>`.
- `mode` not exactly the unquoted scalar `parts` or `on_demand`: `line N: review_material.mode must be parts or on_demand` (N is the line of the `mode` pair).
The refusal is the usual `environment/project_config_invalid` at config load. Document the key in `docs/configuration.md` after the `shape_decision_check` paragraph, in ONE line/paragraph that names `review_material`, `parts`, `on_demand`, and states it is experimental and off by default.

## Behaviour with on_demand, native reviewer, only when the source does not fit inline
That is every path that creates pinned parts today: `materialPrepare` when the complete request does not fit, and `materialRelocate` when an inline review outgrows its window. When the source fits inline, `on_demand` behaves exactly like `parts`: the request is identical, no parts exist, no `review_material` event is written. The external (Claude Code) reviewer path is unchanged.

1. Parts are created, pinned, hash-bound and recorded in the working-context history exactly as today (same chunking, same JSON part files and hashes, same `review_source_evidence` event). Reading a part by path (`read_file`) and a candidate file by `start_line`/`end_line` return the same bytes as today. Replay and custody validation are unchanged.
2. The opening message keeps the authority block verbatim and the check results. The catalog JSON line (after `# Pinned complete candidate source evidence\n`) is extended, only in this mode, so it is the hash-bound manifest of the changed material. Existing keys stay (`version, candidate_tree, binding, start_head, source_bytes, source_sha256, files, parts`). Added:
   - top level `"mode":"on_demand"`;
   - per `files` entry (existing `path, status, mode, git_object, bytes, sha256`): `"diff_stat":{"added":int,"deleted":int}` (lines; for an added file all its lines are added) and `"hunks":[{"old_start","old_count","new_start","new_count","header"}]` taken from the diff against the start HEAD (`header` is the `@@ ... @@` text without trailing context). An added file has one synthesized hunk `@@ -0,0 +1,N @@` (old_start 0, old_count 0, new_start 1, new_count N). A changed one-line file that becomes 14000 lines has `@@ -1 +1,14000 @@` with old_start 1, old_count 1, new_start 1, new_count 14000. Binary, deleted and gitlink entries get zero `diff_stat` values and `hunks: []`;
   - per `parts` entry (existing `path, sha256`): `"part":<1-based part number>` and `"covers":[{"path","kind","first_line","last_line"}]`, at most one entry per (path, kind) per part. `kind` is `file` (1-based line numbers within the candidate file's text, counting a line as covered when any of its bytes are in the part, so adjacent parts may share one boundary line) or `diff` (1-based line numbers within that path's block of the diff text). The `file` ranges of one path ascend, each starting at most one line after the previous one ends, the first starting at line 1 and the last ending at the file's last line.
   - The guidance text after the catalog line replaces `Read EVERY part ... before approving` (and the sentences that require delivery before approval) with on-demand guidance that contains exactly the sentence `Read only the parts you need; no part is required before a verdict.` and still states that the catalog is evidence not authority, how to read a part by path and `review_source.text` order, and how to read candidate files by path and line range.
   The opening message carries no part body: the native source-data prefill of unread parts (`prefillSource`) appends nothing in this mode. The diff and file texts stay only in the parts, as today.
3. The rule that every pinned part must be read does not apply: an approval is accepted after reading none or any number of parts (`materialUnread` is not consulted for `approve`, and the k11 unread-parts check for `changes` verdicts is skipped too). All other validity is unchanged: independence, verdict schema, blocking findings, repairs, final verification, commit.
4. Run log: when a review that pinned parts records a verdict, write one `review_material` event `{"event":"review_material","review":N,"mode":"parts"|"on_demand","parts":<pinned part count>,"parts_read":<parts delivered by complete matching read_file outputs or native prefill, by the same rule as `delivered`>}`. Existing `read` events (`tools.ReadEvent`) already carry per-read bytes; add nothing else. No event is written when no parts were pinned.

## Must stay
With the key absent (or `parts`), the review request for the same candidate is byte-identical to before, including the prefill messages. No new command, flag or user-visible output; no timeout, budget or limit changes; authority delivery and review independence unchanged. The only default-mode addition is the `review_material` run-log event for reviews with pinned parts.

## Decisions
- The key is `review_material: {mode: parts | on_demand}`, absent means `parts`, default off, documented as experimental. (source: request)
- Unknown keys or values are refused at config load naming the key, like the other optional keys. (source: request)
- `on_demand` changes behaviour only when the source does not fit inline; parts remain created, pinned and hash-bound. (source: request)
- The manifest is carried in the existing catalog JSON line (hash-bound with the parts through the same catalog); the native prefill of part bodies is off in this mode so the opening carries no bodies. (source: request)
- The "read every part" rule is lifted in this mode for both approve and changes verdicts; nothing else about validity changes. (source: request)
- The run log records mode and parts read in a `review_material` event. (source: request)
- The diff itself is not added inline: today only check results are inline and the diff lives in the parts; that is kept. (source: request)

## Source comparison
- addressed: config key, validation and docs (scenarios 6 and 7; config unit tests).
- addressed: default byte-identical request and unread refusal (scenario 1: catalog key set, exact guidance text, native prefill present, refusal feedback).
- addressed: on_demand manifest with paths, status, bytes, SHA-256, diff stat, hunk headers and ranges, parts with ids and covered line ranges, and no part bodies (scenarios 2 and 3).
- addressed: approval after reading zero or one part; parts and line-range reads return identical bytes and identical part hashes (scenarios 2, 3, 4).
- addressed: inline candidates identical to parts (scenario 5).
- addressed: run log records mode and parts read; per-read bytes come from existing read events (K9 fields were not located in this repository and nothing was invented).
- interpreted: "the diff as today when they fit": today the diff is never inline for overflowing candidates, so it stays in the parts.
- omitted by request: no benchmarking, no enabling by default, no external-reviewer change.

## Tests
- review_material config key parses, defaults to parts, refuses non-mapping, unknown key and bad value naming the key: add cases to `cli/project/config_test.go` (unit)
- with the key absent the overflowing request is unchanged and an approval with unread parts is refused: scenario 1 (scenario)
- on_demand opening has the manifest and no part bodies; approval after zero or one part read accepted; `review_material` event: scenarios 2 and 3 plus a Go integration test in `cli/build/review_test.go` using the fake provider (integration)
- part by id and line-range reads return the same bytes in both modes: scenario 4 (scenario)
- on_demand with an inline-fitting source is identical to parts: scenario 5 (scenario)
- invalid value refused at config load: scenario 6 (scenario)
- documentation names the lever as experimental and off by default: scenario 7 (scenario)
- manifest builder (diff stat, hunks, part covers) for changed, added and deleted paths: unit test in `cli/build/material_test.go` (unit)
- review, material and prefill behavior with the key absent stays unchanged: the existing review, material and prefill tests pass unchanged (existing)

## Feasibility
- The driver compiles against the unchanged tree as a go -overlay test; with the key absent the default scenario ran green on the unchanged code (refused unread approval with 47 unread parts, landed; the opening request carried part bodies through the native prefill, 476893 bytes), and with the key present the unchanged code refuses `line 2: unknown key review_material`, so the on_demand scenarios are legitimate missing-feature red. Two default-mode runs of a small candidate differ only by the per-run temporary folder, which the driver normalizes. (probes: exit 0)
- evidence: {"id":"krevod-observer","kind":"observer","inputs":["features/steps/krevod_steps.js","features/steps/krevod_driver.go"],"observers":["features/steps/krevod_steps.js","features/steps/krevod_driver.go"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/krevod_steps.js --control good","exit":0,"output":"krevod observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/krevod_steps.js --control bad","exit":1,"output":"krevod observer rejected bad fixtures\n"}]}
