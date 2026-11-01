# Shard the race pass by top-level test

Slug: k-checktime-shard
Model: not applicable — deterministic inventory partitioning and subprocess execution have no meaningful product state machine
Acceptance:
- .kogen/intents/k-checktime-shard/acceptance.feature
- features/steps/k_checktime_shard_steps.js

Deliver a standalone race runner at `test/race-shards.cjs`, invoked from `cli` as `node ../test/race-shards.cjs` in place of `go test -race -count=1 ./...`. Optional positional package patterns serve the fixture and otherwise default to `./...`; this is an internal test script, not a change to the kogen CLI. Do not switch configured checks in this Build. Delivery switches the configured race command in a separate reviewed commit immediately after landing.

Enumerate packages with Go and compile each package's race test binary once per pass using `go test -c -race` into a private temporary directory. Enumerate runnable top-level names from that binary using `-test.list`. Use the fixed singleton policy: sorted names, one top-level name per shard, sequential execution. There is no shard-size or policy option. Use escaped fully anchored `-test.run` expressions so prefix collisions do not duplicate execution and all subtests still run. Include ordinary example tests and fuzz seed execution that the original race command runs; do not run benchmarks. Preserve package working directories, environment, race detection, uncached execution, and the existing vet coverage. Packages without runnable tests must still compile successfully and not create an accidental match-all shard.

Direct test binaries need an explicit `-test.timeout=10m` to preserve the unchanged Go command default (not zero/unlimited). Every shard uses that same timeout. Do not change any existing timeout, retry or limit value, test timing, test contents, tags, or package boundaries. Each top-level test executes exactly once per successful pass with none skipped or weakened. A compile, enumeration or shard failure makes the runner nonzero, with diagnostics; never retry or silently succeed. Temporary artifacts only; clean up owned artifacts and never stop processes by name or pattern. Only processes started by this runner may be stopped. No synthetic CPU load.

Runner stdout is NDJSON. Each completed shard emits `{ "type": "shard", "package": "<import path>", "tests": ["<top-level name>"], "elapsedSeconds": <positive wall seconds>, "status": <integer exit> }`. Measure actual elapsed wall time around the binary, including race runtime overhead. Send tool/test diagnostics to stderr so stdout remains parseable. Additional NDJSON records may describe compilation and packages without tests. Record failed shard timing too. This is a drop-in check command by package scope and exit semantics, not a promise of identical textual output.

Acceptance measures mechanism on a small real Go race fixture, not the full slow build package. The full ten-pass stability measurement is explicitly delivery work after landing: on the MacBook (the only Build host since 31 October), run ten separate sharded passes over Kogen's race packages, retaining commands, revision, host, pass identity, exit statuses and every shard wall time; verify every shard is strictly below 180 seconds. Do not claim this measurement from fixture acceptance. All configured checks still must pass in Build, including the current race command and its host wrappers, unchanged.

## Decisions
- Use sharding rather than package splitting; no test timing changes (source: request)
- Keep `.kogen/project.yaml` untouched; delivery switches the race check separately after landing (source: request)
- Use a small fixture for approval within 120 seconds; defer only the ten actual stability passes to post-landing delivery (source: request)

## Source comparison
- Addressed: Request K-CHECKTIME-SHARD What/Acceptance: compile-once race binaries, fixed shards, exact top-level coverage and wall-time reporting are specified above and exercised by acceptance; singleton shards are the settled technical partition policy.
- Addressed: Why records Linux eu2 GOMAXPROCS=2 taking over ten minutes for `go test -race ./build`; no Linux timing claim is substituted for MacBook delivery measurement. Regression tests exercise the mechanism without running that reproducer during approval.
- Addressed: Must stay, Out of scope and Host safety: unchanged CLI, timeouts/retries/limits/checks, no clock edits or package splitting, owned-process-only safety and temporary artifacts as above.
- Addressed: Protected configuration dated 31 October: no edit to `.kogen/project.yaml`; separate reviewed delivery commit remains required. Current configured host wrappers remain unchanged.
- Addressed: 31 October acceptance revision: two small fixture passes inside the 120-second approval command, ten real passes only after landing; no full stability run in Intent acceptance.
- Historical context retained, not a new implementation obligation: split from K-CHECKTIME by kogen-main on 30 October after Build 592ca392 passed checks but review material was 511728 bytes against a 524288 ceiling. This Intent does not alter review limits. K-CHECKTIME-CLOCK remains out of scope. No requested behavior is deliberately omitted or superseded.

## Tests
- Fixed partition covers every top-level name exactly once, escaping prefix collisions: add focused partition unit tests (unit)
- Compile once per package per pass and execute real race binaries from package directories with wall times: fixture acceptance audits actual Go compiler calls and test-side effects over two passes (integration)
- Regression for the monolithic race pass exceeding default timeout: fixture acceptance proves separate singleton executions while preserving the default 10m timeout; no long build-package run at approval (regression)
- Preserve check coverage including empty packages, examples, fuzz seeds, compile/shard failure and default timeout propagation: add real temporary Go-package integration tests for the runner (integration)
- Existing configured checks retain their present meaning and configuration: run all configured checks unchanged (existing)

## Feasibility
- Go command documentation was retrieved at https://pkg.go.dev/cmd/go (untrusted documentation data); it documents `-c`, mandatory `-test.` prefixes for direct binaries, package working directories and the 10m Go test timeout. Search returned irrelevant results; retrieval, not that search, supplied the technical facts.
- evidence: {"id":"fixture-observer","kind":"observer","inputs":["features/steps/k_checktime_shard_steps.js"],"observers":["features/steps/k_checktime_shard_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_checktime_shard_steps.js good","exit":0,"output":"observer accepted control\n"},{"name":"bad","command":"node features/steps/k_checktime_shard_steps.js bad","exit":1,"output":"observer rejected control\n"}]}
