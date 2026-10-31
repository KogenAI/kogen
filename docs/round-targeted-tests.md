# Round-targeted tests: research decision record

Studio kogen round-targeted-tests r2; research-only decision, 31 October 2026.

## Decision and status

**No adoption. No measured speedup.** Preserve the Lab adoption gate and proceed with existing evidence only. The caller reported on 31 October that `buildspeed-screen-20261030` has no result or ledger row and nothing was adopted. The bss1 main study (Kogen `d42f6ccc`, g0 vs g1) was admitted and pending; its dry run graded one cell per arm and decides nothing. These are caller-reported facts, not a fetched Lab result or export. Do not duplicate the screen, poll it, or promote guidance. Obtain the current bss1 results and adoption decision before considering adoption. A pending result authorizes neither adoption nor a speedup claim.

This record makes no builder prompt, default, command, flag, option, timeout, retry, limit, verification or review change and does not fix builder execution time now. Complete configured verification and independent review remain in place for every native and external lineup; all configured checks remain as-is. No new option is proposed.

Targeted test **execution** is separate from fast test **authoring**: Studio issue `f877f021` and Lab study `test-authoring-guidance-20261031` are unrun, and their wording is not accepted.

## Rendered capture provenance and comparison

The source revision inspected is `575228462e483bda1f7ead91d85feac0bbaac7e4`, not the bss1 study revision. No live provider was called. For native instructions, a temporary local Go program in the `cli` module printed `agent.Prompt(agent.Builder)`; the native excerpts below are from that output. `cli/agent/prompts.go` renders the prompt and `cli/build/executor_native.go` passes it as Build instructions. The project-specific opening message is separate: `cli/build/golden_test.go` exercises `openingMessage()` against `cli/build/testdata/context-golden.json`. This is an instruction rendering, not a capture of a whole provider request.

For external Build, a temporary test used the existing `newHarness` and fake Claude capture in `cli/executor/claudecode/adapter_test.go` and `fake_test.go`, called `Session.Round`, and printed the first round's captured stdin and `--append-system-prompt` argument. Both contained the same Constraints text quoted below; stdin continued with the fixture's `STABLE brief` and `DYNAMIC files`. The test passed via `cd cli && go test ./executor/claudecode -run '^TestResearchCapture$' -count=1 -v`, and the temporary test was removed. The existing `TestArgvRounds` tests this framing and subsequent feedback. `cli/executor/claudecode/args.go` and the adapter implement the separate preface and argument. This is a local fixture capture, not a live Claude session or a real project task; task-specific content may itself contain other instructions.

### Native builder instructions

The rendered native instructions say:

> Write and update tests as the Intent's `## Tests` section and the testing rules say. Use focused tests or fail-fast runs while debugging. Kogen owns the complete acceptance/project gate at finish; avoid duplicating that whole gate in shell. Preserve failed test exit statuses when printing diagnostic logs.

They also say:

> Run finite tests and browser suites in the foreground until completion, even when they take minutes; do not poll them through repeated sleep/tail/ps calls.

And they assign verification and review ownership:

> When the implementation is complete, call finish. Kogen runs the fixers, the acceptance scenarios, the model and every check. Verification failures come back to you; fix them and call finish again. After a green pass an independent reviewer investigates and repairs supported defects, then Kogen verifies any changed contents.

### External Claude Code Build framing

The separate `Constraints` preface is also passed verbatim as `--append-system-prompt` in the first round; it does not copy the native prompt. The captured framing includes:

> You are implementing one requested feature in this Git checkout, the current directory. Kogen will independently run the configured checks, an independent review and the single commit.
> Do not commit, push, switch branches, stash or rewrite Git state.
> Do not edit the protected paths named in the task: edits to them are refused, and any change to them is detected and stops the Build.

It also gives protected-fixture blocker reporting instructions and ends:

> When you believe the work is complete, stop and summarize what you changed.

Unlike the native instructions, this Constraints framing contains no scoped-repair/focused-test, duplicate-gate or finite-test polling guidance. That is a framing gap, not evidence that Claude necessarily ran a particular test or that adding guidance would save time. The comparison makes no adoption change; Kogen retains complete configured checks and independent review in both lineups.

## Reported Build profile and limits

The request reports 42 Builds on 30 October: in-round builder tests accounted for 19.8 ks, 34% of summed Kogen Build wall; kogen-loop accounted for 25%; total tests accounted for 76%. Reported individual builder-test times were:

| Build | Builder tests | Build phase wall |
| --- | ---: | ---: |
| `0fe59528` | 8,660 s | 10,918 s |
| `416c6a6c` | 2,932 s | not reported |
| `f942dd77` | 2,210 s | not reported |
| `d84e3244` | 1,498 s | not reported |
| `312149a3` | 1,497 s | not reported |

The request reports repeated `go test ./...`, `go test ./build` and the full race pass (`go test -race ./...`), including sleep-polling of logs. Transcripts show commands, not unchanged-package trees, so the amount of unchanged-package retesting is unknown. About 1,100 s per Build is a reported upper bound, not measured savings; it overlaps `K-GO-TEST-CRITICAL-PATH` and `K-ROUND-FULL-SUITE` and must not be added to their bounds. Historical roadmap screenshots establish neither landing nor a priority change.

## Separate sharding evidence

The caller's sharding screen is distinct evidence, not proof of targeted-test adoption or savings. On a laptop, n=3 per arm, plain Go tests failed 3/3 on the `./build` 10-minute timeout; four concurrent `-run` shards passed 3/3 at a mean of 461 s, p=0.05. On a MacBook plain failed 2/2; one sharded run took 474 s with one flaky test. Sharding raised load from 9–10 to 15–18. Separately, builder test commands occupied 50% of Build wall in 19 MacBook Kogen + Claude Code cells. Small samples, a flaky test, and changed load limit generalization; these results do not decide bss1.

## Before/after measurement gate

First obtain current bss1 results and its adoption decision; do not execute a duplicate study. If future work is authorized after that gate, compare the same kinds of Builds, native/external lineup, change scope and host conditions. Separate in-round builder test wall time from Kogen verification and total Build wall; record failures and complete configured-check and independent-review coverage in each arm. Report observed savings separately from upper bounds and the unknown amount of unchanged-package retesting. No new tooling or study runner is requested.
