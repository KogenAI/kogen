# Go migration evidence

Kogen is one Go program (`cli/`): packages `sys`, `project`, `git`, `provider`, `agent`, `verify`, `shape`, `build` and the `cli` main. The Elixir application, the Go↔Elixir bridge, the core process and the BEAM part of packaging are gone. Current completion reconciles main `76109e1a` with signed caching `828dfa5d`, plus the two approved changes in `.kogen/intents/go-core-migration/intent.md`: prompt caching (KOGEN-054) and open model selection with an OpenAI-compatible provider (KOGEN-057).

- `coverage.md` — what proves each original test and contract now: ExUnit tests, accumulated Intent contracts, public chapters, the two approved changes, superseded scenarios with their reasons, and implementation-necessitated differences.
- `ledger.md` — every ExUnit test of main `76109e1a` (270 tests) and the Go test or installed scenario that now covers it, plus the earlier bdfd607 rows.
- `accumulated-suites.md` — the accumulated Intent suites and public chapters run against the final Go candidate.
- `replay.md` — the bounded production-transition replay against `spec/quint/build.qnt` (`sh test/migration/replay.sh <kogen> <out>`): four journeys, five production mutants.
- `qualification.json` — dependencies, timings, platforms and real use; missing evidence is marked missing.

Implementation-necessitated differences users could notice (named in `coverage.md` §5): the Build lock is an operating-system lock that a killed kogen releases at once (an earlier Kogen's leftover lock is still removed with the old notice); debug logging is `KOGEN_LOG_LEVEL=debug` (stderr only), in place of the Erlang logger switch; a resume after kogen was killed inside its commit step names the commit on HEAD; Elixir version-3 checkpoints resume in Go, and version 2 stays refused as on main.

Current completion and its original red/targeted green evidence are distinguished in
`accumulated-suites.md` and `qualification.json`. Production Go remained unchanged
through final observer corrections. The real installed mixed-provider journey
passed on the same runtime; private darwin-arm64 adoption is separate from a public
release or unperformed Linux qualification.
