# Coverage: what proves the Go Kogen keeps each original test and contract

A review aid for the go-core-migration Intent, not proof by ledger count. Every claim below names the executable evidence: a Go test, an installed-candidate scenario, or an explained obsolete bridge/harness assertion. Reference behaviour is Kogen main `76109e1a`.

## 1. Kogen's own ExUnit tests (main 76109e1a: 270 tests in 49 files)

`ledger.md` maps every one of them, by exact ExUnit file and test name, to the Go tests that now carry its assertions. A script compares the ledger with the test names extracted from `git archive 76109e1a test/` and with the Go test functions in `cli/`. Result: 270 of 270 tests have a row, and every Go test name a row cites exists (the `TestChatGPT*`/`TestSuperGrok*` prefixes name test families). Rows that cover an assertion only in part say so in the row (for example "git part", "verify part").

Assertions that are obsolete because they tested the removed implementation, not Kogen's behaviour:
- `test/integration/integration_helpers_test.exs`: three tests of the ExUnit harness's own process bookkeeping (a failed invocation reaps descendants after its parent exited, a startup error keeps custody of a running invocation, completed invocations clean up harmlessly). Kogen's own process-group behaviour is covered by `cli/sys` (`TestRunStdinClosedOwnGroup`, `TestKilledKogenStopsCommands`, `TestInterruptKillsAGroupThatIgnoresSIGTERM`). The installed deterministic-check-gate lifecycle scenario checks the real relay and kogen pids. The other three harness tests (marker readiness, cleanup after the owner ends or is killed, preparation stops descendants) are covered by that same installed lifecycle scenario.
- "a core death during resumed commit…": the shell-level crash report of the two-process design is gone with that design; the commit-step resume itself is covered (see the ledger row).
- deterministic-check-gate's two observer controls "comparison tokenization" and "outer input scope" evaluated Elixir expressions with `Code.eval_string`. With no Elixir, they hold the recorded Elixir results, and they still drive the six-control observer loop.
- `test/support/compact_context/` (`render.exs`, `compare.py`): a manual operator comparison for historical KOGEN-031 evidence that drove Elixir internals. It is removed with the core; the compact-shaping-context suite is the maintained contract.

Installed-binary ExUnit tests ported as installed tests: `TestInstalledKeyLoginUnderPipesAndATerminal` (`cli/login_installed_test.go`). It runs the original Python PTY drivers, unchanged, against the real built binary for opencode-go, anthropic and openai-compatible: invalid UTF-8 on a pipe, no echo, terminal restored on success, error, SIGINT, SIGTERM and SIGHUP.

Elixir-pinned parity data stays as test history, beside the generators that produced it from main's real modules: `cli/project/testdata/golden.json` (configuration, YAML, rendering), `cli/build/testdata/legacy76/` (version-3 builder/reviewer checkpoints written by `Kogen.Build.save/2`, `Kogen.Stages.retain/2` and `Kogen.ReviewMaterial.prepare/8` at 76109e1a), `cli/build/testdata/legacy/` (bdfd607 checkpoints), and `cli/*/testdata/gen*/`. The generators (`*.exs`) need main's Elixir to run again; they are provenance, not part of the candidate.

## 2. Accumulated Intent contracts (39 suites)

Each `.kogen/intents/<slug>/acceptance.feature` runs with its step library against the installed candidate (`accumulated-suites.md` has the per-suite results of the final run). The step libraries were ported off Elixir without weakening observations: build-unblocking-recovery, staged-intent-builds, deterministic-check-gate, review-refine-working-room and shape-working-summary now observe the Go candidate, or a Go driver program importing `kogen/...` packages where an observation has no user-visible form.

Where a ported library changed what it can observe, the change is named here:
- shape-working-summary: the Elixir driver called `ShapeWorkingContext.prepare`/`RefineWorkingContext.prepare` directly. The port runs real `kogen intent shape`/`refine` conversations against the scripted provider (115 and 2 resets, with 42 and 0 documentation records). It checks the reduced input the provider actually received, the handoff, the archive and documentation custody, and four damage modes. Fixture values that a live conversation cannot reach were adjusted, matching main's behaviour: 2 invalid submissions (the third ends the conversation), an empty Shape manifest, Shape's declared steps `[]`, and Refine documentation rows without bodies (identical to main's `retain_documentation`).
- review-refine-working-room: `Shape.replay_item`, `Tools.run`+`cut`, `ChatGPT.request_body` and `WorkingContext.measure` are the Go driver's `replay`, `tool` and `measure` commands over `agent.ReplayItem`, `agent.Tools.Run`+`Cut`, `provider.Client.Body` and `agent.Measure`. The 524287/524288/524289-byte boundaries hold.
- build-unblocking-recovery: two observer self-controls that evaluated Elixir expressions hold the recorded Elixir results (see §1); every recovery observation is made on the installed candidate.
- deterministic-check-gate: the regression-module scenario runs the ledger-mapped Go tests (`go test -json -p 1`). A missing ledger row fails the run. 29 ExUnit cases are reported (minimum 28).

Step scripts that were stale against main itself were updated so that the scripted model does what main now requires. In each case main's own release fails the old script the same way:
- usable-check-protection: the scripted shaper reads the two manifests before submitting files (main 2ca0e06, required shaping technical discovery).
- build-continuity, native-image-evidence: the resumed reviewer reads every pinned review-source part before approving (main 7e15bf2).
- bounded-tool-results: the second scripted tail after the reset no longer repeats the growth turns (the Elixir driver's second script was only the tail; repeating it left kogen waiting on a never-continued pause).
- supergrok-subscription: `bad_model`/`bad_effort` now expect KOGEN-057 behaviour (sent unchanged, SuperGrok's refusal shown once with the fix, one request).

Superseded scenarios. These are declared in the go-core-migration acceptance by exact scenario name, or by example row; a typo in the table is an error, not a skip. Each one's surviving guarantee is proven elsewhere:

| Superseded by | Suite | Scenario (row) | Why | Surviving guarantee proven by |
|---|---|---|---|---|
| prompt caching | cache-capability-fallback | all 23 | its premise is sending `prompt_cache_options` to ChatGPT and repairing the 400 | caching outline (0 cache-refusal retries), `cli/provider` caching tests |
| prompt caching | prompt-cache-reuse-and-usage | 3 scenarios | require the old ChatGPT cache fields and forbid `prompt_cache_key` | caching outline on 5 providers |
| prompt caching | opencode-go-subscription | ChatGPT keeps the exact recognized rejection compatibility… | the old ChatGPT refusal retry | caching outline; opencode-go suite's other 23 scenarios |
| prompt caching | native-image-evidence | Resume frozen Build pixels… (`fallback` row); Unsupported cache controls do not change image content on retry | script a ChatGPT `prompt_cache_options` 400 and expect the removed retry | the `resume-change`/`resume-delete` rows and the other 10 scenarios still pass |
| open model selection | opencode-go-subscription | Unqualified Go models and efforts are rejected before inference (4 rows) | the allowlist KOGEN-057 removes | "Any model and effort reach every provider unchanged and a refusal is clear" |
| open model selection | claude-api-key-provider | Select documented Claude models and the initial Kogen effort subset independently (rows `claude-invented`/high and `claude-opus-5-5`/xhigh, expected `refused`) | the allowlist KOGEN-057 removes | the same scenario's other 10 rows (including the refused unknown provider) and the open-model scenario |
| main's version-3 checkpoint rule | reopen-blocked-review | Reopen a real retained signed C3 checkpoint (2 rows) | the genuine c3ee2a8e producer writes version-2 checkpoints, which main 76109e1a refuses since 71f7b4f, as build-continuity requires | "A genuine C3 version-2 checkpoint is refused exactly as main 76109e1 refuses it" (the real C3 run, built from the provenance-bound source fixture) |

## 3. Public specification chapters

`spec/features/01`–`10` run through the protected harness against the installed candidate; chapter 11 is `@live` only. Chapter 09's help-page and unknown-provider rows were stale on main itself. Main's CLI prints `recover` and the four-provider list, while its spec still had the bdfd607 pages, so main's own release fails the same rows. They now pin the real pages, which also name openai-compatible.

## 4. The two approved changes

- Prompt caching (KOGEN-054): the go-core-migration outline builds, interrupts, resumes and independently reviews one approved Intent on a caching fake. The fake computes cached tokens from the actual shared byte prefix per routing key, for chatgpt, supergrok, opencode-go, anthropic and openai-compatible. Results are in `accumulated-suites.md`.
- Open model selection (KOGEN-057): the installed scenario "Any model and effort reach every provider unchanged and a refusal is clear" (79 observations), plus `cli/provider/compatible_test.go` and `cli/project/config_test.go`. The Elixir configuration goldens are kept unchanged; `openModelSelection` in `cli/project/golden_test.go` is the explicit, reviewed transform of exactly the allowlist refusals.

## 5. Implementation-necessitated differences (all named, none silent)

Carried over from the first port and still true:
- The Build lock is an operating-system lock that a killed kogen releases at once. An earlier Kogen's leftover lock is still removed with the old notice.
- Debug logging is `KOGEN_LOG_LEVEL=debug` on stderr, in place of the Erlang logger switch.
- A resume after kogen was killed inside its commit step names the commit on HEAD.
- Elixir version-3 checkpoints resume in Go; version 2 stays refused as on main.

### Current caching handoff reconciliation

The final port incorporates the current caching correction: public SIWC uses a stable body prompt_cache_key, no private-backend session header, and one exact-key-only compatibility retry. Legacy options suppression cannot suppress a newly introduced key; key suppression persists once recorded. Anthropic API output cap is128000; the internal131072-token reserve remains unchanged. Refine uses compact revision-bound navigation with complete owned originals.

Named request-layout difference: Go retains the policy in the public Responses instructions field, whereas the current Elixir candidate uses a leading developer block for GPT5.6+. Both retain the full same policy and fixed placement within a conversation; source prefixes/checkpoints are never mixed across implementations. This is not a claim of byte-identical request layout or comparative cache benefit.
