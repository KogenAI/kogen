---
status: SHAPED
appetite: small
blocks_on: []
scope: [Makefile, codegen-scaffold, harnesses/claude/hooks/run-tests.sh, harnesses/shared/loop-signal-bridge_test.sh, harnesses/shared/pitch-postflight_test.sh, templates/generator/run-all-tests.sh, templates/generator/run-all-tests_test.sh, test_harness/install/install_pi_round_trip_test.sh, test_harness/lib/codegen_test_harness/fixtures.ex, test_harness/test/codegen_test_harness/fixtures_test.exs, test_harness/test/codegen_test_harness/orchestration_loop_test.exs]
summary: >
  Core-gated tail overlap in run-all-tests.sh (fold hooks ∥ hermetic-ExUnit ∥ rule-render
  into phase 1 when logical cores ≥ threshold), plus ExUnit --max-cases 24 and a parallel
  harness-parity loop in the Makefile, roughly halve `make test`: 201s → ~105s on high-core
  Darwin, proven green ×4. Below the core threshold (2-core Linux studio) the exact current
  serial tail is kept, so there is no regression there. No test is dropped, no tier, no flag.
  Every contributor and the build loop get a ~2× faster gate on high-core machines.
  The overlap threshold parses fail-loud: an invalid TAIL_OVERLAP_MIN_CORES or empty
  core-probe exits non-zero, never silently selecting serial (fixes the first build's
  reviewer-blocking fail-open).
build_failures: 1
shipped_sha: 2b128a92
shipped_range: f21c970a..2b128a92
---
# Halve `make test` with core-gated tail overlap

## Formal verification and ship directive

The 11-file implementation is complete. The latest review found one empty-input snapshot defect; that fix is now present and needs the ordinary final review/gate sequence:

1. The developer must inspect the current dirty WIP and the evidence below, then run exactly **ONE** formal `make test`.
2. Make no redesign and no source change unless that formal run produces an infrastructure red that names a real, reproducible issue in the current implementation.
3. If the formal gate is green, the reviewer verifies the WIP and evidence; then the curator updates context and the committer commits/ships.
4. Do **not** rerun `make install`.
5. Do **not** rerun `make test-stacks`.

The current implementation tree is exactly 11 dirty paths and its pre-recovery `git diff --binary` SHA-256 is `bd0433d1b1cc1b059d6b5bde1192242f309ce8bb97a9d1cd18bbc94a825df7f4`.

### Verification evidence already established

- Focused real-scheduler suite: **66 passed / 0 failed**.
- `loop-signal-bridge_test.sh`: **16 passed / 0 failed**.
- `pitch-postflight_test.sh`: **16 passed / 0 failed**.
- Full harness parity: **green**.
- Concurrent stress: **8/8 green**.
- Real `make test`: literal **`ALL CLEAR ✅ make test`**, completed in **112.91s** against the exact 11-file pre-review snapshot. This is real green evidence, but it predates the final empty-snapshot fix and is not presented as a post-fix gate.
- `make install`, generated parity, harness-path checks, and doctor checks were previously **green**; they are recorded evidence, not authorization to rerun them.
- Earlier reviewer verdict: **QUALITY APPROVED**. The latest reviewer then found the empty `gate-pending/` xargs defect; the final WIP replaces that xargs path with a NUL-safe temp-file/`while read -d ''` snapshot and retains the separate empty-discovery guard. Final re-review remains required.
- Stack root-fix focused tests: **6 passed / 0 failed** and **1 passed / 0 failed**.
- Final empty-input snapshot correction: when `codegen/gate-pending/` is empty, `_gate_pending_snapshot` now emits an actually empty snapshot on BSD/GNU; hook-test discovery likewise skips `xargs` when its NUL-delimited discovery file is empty.

### Stack history — report exactly, do not reinterpret

- A prior harness-parity attempt was red because dirty-tree integration was not yet fixed.
- The final `make test-stacks` run was user-cancelled and terminated by **SIGTERM** during `test-harness-parity`, after the generated-app developer gate and reviewer were green.
- Its literal process result was **exit 143** and it produced **no final ExUnit summary**. It is not a green stack result.
- The user explicitly forbids rerunning `make test-stacks`; preserve and report this truth rather than manufacturing a replacement result.

## Problem

`make test` runs 2–5 times in a normal build, so its wall time dominates feedback and build cost. On a high-core Darwin box a full green gate is ~201s; the serial phase-2 tail (`hooks` → `test-hermetic` → `rule-render-freshness`) is the structural bottleneck even though those leaves are IO-bound and leave CPU idle. The experiment session proved a safe halving to **~105s** (core-gated tail overlap + `--max-cases 24` + parallel `harness-parity`), green ×4, full population, zero dropped tests. The operator accepted ~105s as the deliverable ("we experimented and got to ~105s which is fine for now") and dropped the earlier absolute sub-60 target. This pitch ships the proven halving; the sub-60 pursuit (further hook-file splits + an ExUnit real-time-margin trim, only reachable on a spare-core box) is deferred to rabbit holes.

## Scope

Blast-radius map (edit surface includes the proven halving plus its mandatory recovery regressions):

- **Edit targets (scope)**: exactly `Makefile`, `codegen-scaffold`, `harnesses/claude/hooks/run-tests.sh`, `harnesses/shared/loop-signal-bridge_test.sh`, `harnesses/shared/pitch-postflight_test.sh`, `templates/generator/run-all-tests.sh`, `templates/generator/run-all-tests_test.sh`, `test_harness/install/install_pi_round_trip_test.sh`, `test_harness/lib/codegen_test_harness/fixtures.ex`, `test_harness/test/codegen_test_harness/fixtures_test.exs`, and `test_harness/test/codegen_test_harness/orchestration_loop_test.exs`. These cover the scheduler/harness work plus the generated-stack dirty-integration root fix and focused regressions; there are no other authorized implementation paths.
- **Entry and callers**: `Makefile` target `test` invokes `run-all-tests.sh`; `ci`, `test-all`, and `build-ready` consume `test`; `.claude/gate-config.sh` selects `make test` for the deterministic loop; `AGENTS.md`/`CLAUDE.md` teach it as the repo gate; `record-green` follows `test-all`. None of these contracts change — same target, same verdict string, same population.
- **Populations unchanged**: prebuild (Pi `subagents`/`enforcement` TS builds), phase-1 parallel aggregate, and the serial-tail members all still run exactly once. The overlap only changes WHEN the three tail populations run (folded into phase 1 above the core threshold), never WHETHER or how many.
- **Sibling modes**: developer/build consumes this gate through `LoopGate`; manual contributors invoke the same target. Shape/debug/ops define no alternate gate. Nothing routes on a mode flag.
- **Required platforms**: Darwin (high-core → overlap → halving) and Linux (2-core studio → below threshold → unchanged serial tail, no regression).

`call-dispatch_test.sh`/`pi-dispatch_test.sh` splits and the `loop_queue_drain_test.exs` ExUnit trim are NOT in scope — they belong to the deferred sub-60 pursuit (see Rabbit holes) and gave no aggregate gain on a core-saturated box.

## Solution sketch

Three performance edits, plus the recovery corrections in this pitch, are present in the 11-file candidate:

**Move 1 — core-gated tail overlap (`templates/generator/run-all-tests.sh`).** When logical cores ≥ `TAIL_OVERLAP_MIN_CORES` (default 6; `sysctl -n hw.logicalcpu` / `nproc`), fold the three load-sensitive tail populations (`hooks`, `test-hermetic`, `rule-render-freshness`) into phase 1's concurrent pool instead of the serial phase-2 tail. Below the threshold, keep today's exact serial tail byte-for-byte. Automatic on core count — no operator flag, no per-platform mode, no dropped tests. **Input parses fail-loud, never fails open.** `TAIL_OVERLAP_MIN_CORES` and the detected core count are each validated as a positive integer in a sane range (`1..1024`); a non-numeric, empty, or out-of-range value — or a core-probe (`sysctl`/`nproc`) that returns nothing — `printf`s a named error to stderr and `exit 1`s BEFORE any branch is chosen. It NEVER lets an errored `[ "$cores" -ge "$MIN" ]` test fall through to the serial branch. This is the exact fail-open the first build's reviewer caught: an oversized value makes `[` error inside the `if`, silently selecting serial. A regression in `run-all-tests_test.sh` asserts an oversized/garbage `TAIL_OVERLAP_MIN_CORES` exits non-zero rather than silently serializing. The real gate's `HOOK_DEDUP_EXCLUDE` set (which removes `codegen-propose`/`codegen-build`/`codegen-call`/`prompt-content-parity`/`tools-header-no-dup` from the hooks tail) is what makes hooks ∥ ExUnit safe; the tracked/untracked-tree isolation backstop still runs last. Proven: 201s → **105s best (108.5s avg, ±4%), ALL CLEAR ✅ ×4**.

**Move 1a — ExUnit `--max-cases 24` (`Makefile` `test-hermetic`).** `mix test --exclude slow --max-cases ${EXUNIT_MAX_CASES:-24}`. ExUnit is IO-bound (16 CPU-s / 74s wall); raising `max_cases` past the default core count overlaps blocked subprocess waits. 117s → 63s. Overridable via env for future tuning.

**Move 1b — full-population parallel `harness-parity` (`Makefile`).** Preserve the public `make harness-parity` contract as the full harness-parity population, with every test executed exactly once. The target fans out the entire population, including `loop-signal-bridge_test.sh` and `pitch-postflight_test.sh`, through one NUL-delimited `xargs -P8` aggregate with explicit empty-input guard, worker rc files, and xargs infrastructure rc propagation. `run-all-tests.sh` schedules that one public aggregate in phase 1. The timing-sensitive tests are hardened instead of hidden. 98s → 32s.

Combined proven aggregate on high-core Darwin: **~105s, green ×4.** Below the core threshold (Linux 2-core studio) only Move 1a/1b apply as harmless leaf speedups and Move 1 keeps the serial tail — no behavior change, no regression (forced-serial branch verified green).

## Mandatory recovery corrections

**Blocking pre-gate checklist — every item must pass before any full `make test` gate:**

1. Public `harness-parity` is one full-population `xargs -P8` aggregate. It has NUL-safe input, a portable empty-input guard, per-worker output/rc capture, and xargs infrastructure rc propagation.
2. There is one public full-population `harness-parity` target, scheduled in phase 1, with no timing-sensitive subtarget.
3. `loop-signal-bridge_test.sh` and `pitch-postflight_test.sh` use deterministic fixture-owned readiness/event waits and clean only recorded fixture-owned PIDs/PGIDs/tmp prefixes. No deadline widening and no global process sweep.
4. The real-scheduler fixture executes the actual `templates/generator/run-all-tests.sh` path under forced-overlap and forced-below-threshold branches. Its PATH-injected `make` stub records every real harness-parity basename and asserts raw count, unique count, and exact set equal the actual full population in both branches.
5. The real-scheduler fixture records active PID markers for full stub lifetimes and proves concurrent hermetic stress is present, not a model-only barrier assertion.
6. Before any full gate, persist evidence in a cycle/session-log artifact from the same real `run-all-tests.sh` fixture, concurrently scheduled aggregate, and subprocess used by the focused regression. Record `PATH`, `command -v pi`, the resolved target (`readlink`/`realpath` as available), fixture `npm_config_prefix`, the actual ambient prefix snapshot, and the concurrent round-trip result. The evidence must be non-empty and linked from the session log; a planner `N/A` claim, standalone run, differently scheduled run, or console-only output is explicitly invalid.
7. Before overriding npm state, capture the actual ambient global npm prefix, its bin path, resolved Pi path, and relevant filesystem state read-only. After the isolated round trip, prove those exact ambient paths/state are unchanged; an unrelated temporary sentinel is not a substitute.
8. `templates/generator/run-all-tests_test.sh` must emit a non-empty footer/summary for the focused run. A `test-generator` result with a blank summary is failure evidence, never green evidence.
9. Do not run a full gate until items 1–8 all pass and the persistent same-aggregate evidence is present and linked.
10. Only then run one captured full gate. Its capture file must be non-empty and contain the literal `ALL CLEAR ✅ make test`; exit code 0 with an empty/missing capture is invalid and must not be reported green.
11. Empty input is a first-class portability case: hook discovery skips BSD/GNU `xargs` when its NUL-delimited temp file is empty, and `_gate_pending_snapshot` uses a NUL-safe loop so an empty directory produces empty output. The latter is the final reviewer-requested snapshot correction and must be covered by the final gate.

- **Public contract and full overlap:** preserve public `make harness-parity` as the full population, with every parity test executed exactly once in one P8 aggregate. Static coverage proves one public population, and dynamic coverage executes the actual `templates/generator/run-all-tests.sh` path with stubbed fast population commands, forces both branches, records every real discovered harness-parity basename exactly once in each, and proves concurrent hermetic stress.
- **Owned cleanup and unchanged deadline:** `pitch-postflight_test.sh` must remove the global `pkill -f '^sleep 30$'` cleanup and clean up only recorded fixture-owned PIDs/PGIDs and its temporary fixture. A regression must prove an unrelated `sleep 30` process survives. Killing unrelated processes is explicitly forbidden. Its existing 15-second timing deadline must remain 15 seconds; widening it from 15 to 30 seconds (or otherwise hiding overlap by relaxing the assertion) is explicitly forbidden.
- **Infrastructure failures:** the Makefile must capture and aggregate the `xargs` infrastructure exit status, and the hooks `run-tests` path must guard empty input before invoking `xargs`.
- **Pi exit-127 before any full gate:** diagnose the observed failure inside the same concurrently scheduled harness-parity aggregate and subprocess environment that produced exit 127, capturing its exact `PATH`, `command -v pi`, resolved Pi path, and fixture `npm_config_prefix` there. Persist that evidence in an artifact or session-log section before the full gate; a standalone, differently-scheduled, or console-only invocation is not evidence. If resolution differs, fix deterministic environment propagation first. No blind reruns or green-chasing, and no claim that Pi is absent without that persistent same-concurrent-aggregate subprocess evidence. No full gate may run until this evidence and the preceding partition/barrier checks pass.
- **Pi install round-trip isolation:** `test_harness/install/install_pi_round_trip_test.sh` must first capture the actual ambient global npm prefix, its bin path, resolved Pi path, and relevant filesystem state read-only; then allocate a unique fixture-owned temporary `npm_config_prefix`, prepend that prefix's matching `bin` directory to `PATH`, and clean up only that fixture-owned prefix/temp state. Preserve the existing install/uninstall round-trip assertions and real credential/token preservation; never replace credentials with placeholders. The regression must prove the exact pre-override ambient prefix/bin/Pi paths and state are unchanged after the full round trip — an unrelated temporary sentinel is not evidence that the real ambient global install was untouched.
- **Full-gate evidence is content-bearing:** when the blockers above pass and the full gate is finally allowed, its captured log must be non-empty and contain the literal `ALL CLEAR ✅ make test`. An exit status of 0 paired with an empty or missing capture is invalid, not green.
- **Recovery discipline:** diagnostic load experiments are explicitly forbidden; implement and verify only these deterministic corrections, without killing unrelated processes.

**Currency note.** Measurements were taken at HEAD `3253c180`; current HEAD is `f21c970a` (+3 commits that added `_test.sh`/ExUnit surface but did NOT touch `run-all-tests.sh`). The overlap mechanism is content-agnostic (it schedules populations, not individual tests), so the halving holds; the exact wall may shift a few seconds. The build's own mandatory `make test` gate re-verifies green at current HEAD on the build box — that gate IS the current-HEAD acceptance for this proven mechanism.

### User interaction flow

1. **Persona**: codegen contributor or the managed build loop.
2. **Interface**: CLI `make test` from repo root; no new flag, env override optional (`EXUNIT_MAX_CASES`, `TAIL_OVERLAP_MIN_CORES`).
3. **Happy path**: run `make test` → every current population runs exactly once → on a high-core box the tail overlaps phase 1 → `ALL CLEAR ✅ make test` in ~105s (vs ~200s today); on a sub-threshold box the serial tail runs as today.
4. **Error/fallback paths**: any functional failure stays non-zero and names the failed population (unchanged). A malformed `TAIL_OVERLAP_MIN_CORES` or an empty core-count probe exits non-zero with a named error BEFORE any scheduling decision — never a silent fall to serial (the first-build reviewer's blocking finding). If a newly-added test carries a real-time timing assertion that flakes under overlap on the build box, harden that single test's assertion (documented precedent: the `codegen-propose` dedup double-list and `CLAUDE_ROLE=experiment` fixes) — never widen the dedup-exclude to hide a real flake, never drop the test. The tree-isolation backstop still fails loud on any tracked/untracked-byte leak.
5. **Success signal**: existing `ALL CLEAR ✅ make test` verdict, arriving in roughly half the previous wall time on high-core machines.

## Required-platform acceptance

| platform | applicability | solution coverage | premise evidence | acceptance evidence |
|---|---|---|---|---|
| darwin (high-core build box) | applies — cores ≥ threshold → overlap | Move 1 + 1a + 1b | baseline 201s; overlap 105s best / 108.5s avg (109/107/105/113) ×4; ExUnit 63s; harness-parity 98→32s | ✅ green ×4 at probe HEAD; build re-runs `make test` at current HEAD → must be `ALL CLEAR ✅`, full population, no dropped test |
| linux (2-core studio) | overlap N/A (cores < threshold) — but change must NOT regress the serial path | Move 1 keeps today's exact serial tail; 1a/1b apply as harmless leaf speedups | forced-serial branch (`TAIL_OVERLAP_MIN_CORES=99`) green, 223s on 10-core = serial path intact; studio stays on serial tail (2 < 6) | ✅ no regression: serial tail byte-identical below threshold |

Breaking axes exercised: platform (darwin/linux), core count (≥threshold overlap vs <threshold serial), and green-vs-red (functional red stays red — verdict string unchanged). Cold-vs-warm and quiet-vs-loyd load affect the absolute number, not the ~2× direction or the green verdict; the operator accepted ~105s, so no absolute wall gate is asserted — the acceptance is "green, full population, both platforms safe."

## What stays the same (external contract)

- `make test`, `make ci`, `make test-all`, and `make build-ready` remain available with identical invocation.
- Full current test population remains mandatory and runs exactly once per aggregate invocation.
- `ALL CLEAR ✅ make test` remains the green verdict; functional red stays red and names the failed population.
- No operator selects a scheduler mode, test tier, cache profile, or platform-specific path. Overlap is automatic on core count.

## Decisions

| ID | Decision | Why | Source | Consequence |
|---|---|---|---|---|
| D1 | ~~Absolute 60s outcome~~ **SUPERSEDED by D14** | Gate runs repeatedly per build | User | Held until D14 relaxed it |
| D2 | sub-60 target = high-core; Linux = best-effort | Operator accepted "Linux can't hit sub-60"; redirected to macOS | User | Narrowed the earlier both-platforms/absolute contract |
| D3 | Reject prior scheduler/watchdog plan | It produced 287–392s and functional reds | Probe | No stale implementation instructions remain |
| D7 | Ship Move 1 (core-gated overlap + 1a/1b) as the deliverable | 201→108.5s avg, green ×4, ±4%, zero flakiness; Linux serial path unchanged | Experiment measurement | The shipped change |
| D8 | Core count alone cannot reach sub-60 | `call-dispatch` 68s + ExUnit serial segment are single-process; JOBS sweep flat ~82s | Experiment measurement | Sub-60 would need file splits + ExUnit trim (deferred) |
| D9 | max_cases exhausted at ~63s ExUnit floor | `test-hermetic` FLAT 63/67/63s for 24/48/96 | Experiment measurement | Keep `--max-cases 24` |
| D10 | Measurement/gate runs unset `CLAUDE_ROLE` | Experiment launcher exports `CLAUDE_ROLE=experiment`, spuriously reddening askuserquestion vitest (Finding H) | Experiment | Real gate/CI unaffected (no such env); noted as latent one-line test-hygiene fix, out of scope |
| D11 | On a saturated box, splitting for parallelism does not cut the aggregate | Move 2 lowered hooks-alone 85→61s but full `make test` did not improve (136s) | Finding J | Hook-file splits deferred; not in scope |
| D14 | **Ship the ~105s halving; drop sub-60 from this pitch** | Operator: "we experimented and got to ~105s which is fine for now… start building it" | User (this session) | Deliverable = Move 1+1a+1b; absolute-60 gate removed; Moves 2a/3 → rabbit holes (same motivation); appetite small |
| D15 | **Overlap threshold validates fail-loud, never fails open to serial** | First queue build's reviewer blocked: oversized `TAIL_OVERLAP_MIN_CORES` errors the `[` test → silent serial branch; "must fail exit, not select scheduler path" | Probe 10 | Move 1 sketch now mandates range-validation (`1..1024`) + `exit 1` on malformed input + a `run-all-tests_test.sh` regression; closes the exact defect that failed cycle 1 |

## Interaction audit

- `(hooks, hermetic ExUnit, shared repo state, high-core)` → composes: with the real `HOOK_DEDUP_EXCLUDE` set applied, hooks ∥ ExUnit is green ×4; the serial-tail flake rationale only bites under CPU oversubscription, which core headroom removes. Tree-isolation backstop unchanged.
- `(overlap branch, serial branch, core threshold)` → composes: below threshold the exact serial tail is kept; forced-serial branch verified green. No populations added or removed on either branch.
- `(make test verdict string, downstream consumers)` → composes: `ALL CLEAR ✅ make test` / functional-red contract unchanged; `ci`/`test-all`/`build-ready`/gate-config consume the same target.

## Rabbit holes

- **Sub-60 pursuit — deferred (same motivation).** Reaching ≤60s additionally needs (a) splitting the giant IO-bound hook files (`call-dispatch_test.sh` 68s, `pi-dispatch_test.sh` 43s) into sibling `*_test.sh` so pieces fan out, and (b) trimming ExUnit's one real-time margin (`loop_queue_drain_test.exs:4710` `default_kill_tree` 10s budget-timeout wait → a deterministic seam). Both pay off ONLY on a box with spare cores (on a saturated box the added concurrency raises the contention tax as much as it lowers the pole — Finding J), and (b) is a risky anti-flake-margin cut. Same core motivation as this pitch (faster `make test`), so it stays here as prose rather than a separate draft. Reopen when a high-core box is available to measure and the risk is worth it.
- Tried raising ExUnit `max_cases` past 24 — flat 63/67/63s at 24/48/96; the floor is compile + `async:false` serial segment + real-subprocess IO, not scheduler width.
- Tried raising hooks `JOBS` past 8 — 85/80/82s at P8/12/20; bounded by `call-dispatch_test.sh` as one process.
- Chased `git stash@{6}` and the `de431dea`/`exp-experiment-test-gate` "sub-60" recollection — both debunked: the stash is a `make test-stacks` fixture fix; `de431dea`'s "sub-60" was ExUnit's async segment (48.3s), not aggregate wall time, on a branch with ~69k fewer lines.

## No-gos

- No dropped tests, fast/full tiers, quarantine, platform omission, retry-on-red, or test-count shrink presented as speed. The halving comes only from scheduling, never from doing less work.
- No operator-selected scheduler mode or tier — overlap is automatic on core count.
- No change to the `make test` verdict string or the population that runs.
- No widening of `HOOK_DEDUP_EXCLUDE` to mask a real flake surfaced by overlap.
- No fail-open on the overlap threshold — a malformed `TAIL_OVERLAP_MIN_CORES` or an empty core-probe MUST `exit 1` loud, never silently select the serial branch.

## Dependencies

None — `every-harness-shapes-and-spikes` shipped in `3253c180`. The current scope is the exact 11-file scheduler, parity-fixture, Pi-isolation, scaffold-clean-tree, and focused-regression set named in frontmatter/Scope. Draft siblings `make-developer-gate-single-owner` and `isolate-curator-phase-capabilities` solve distinct invariants and produce no build output this pitch consumes. `blocks_on: []`.

## Claim ledger

| # | Load-bearing claim | Real-contract probe (executed) | Outcome | Verdict |
|---|--------------------|--------------------------------|---------|---------|
| 1 | Move 1+1a+1b halve `make test`, green, full population, on high-core Darwin | 4× `env -u CLAUDE_ROLE make test`, full aggregate | 109/107/105/113s, ALL CLEAR ✅ each, ±4% | ✅ |
| 2 | Below the core threshold the serial tail is kept, no regression | forced-serial branch (`TAIL_OVERLAP_MIN_CORES=99`) full `make test` | 223s, ALL CLEAR ✅, serial path intact | ✅ |
| 3 | The three perf edits are NOT yet on `develop` (real build work remains) | `grep` overlap/max-cases/xargs on develop tree | overlap ABSENT, `--max-cases` ABSENT, harness-parity is serial `for`-loops | ✅ work remains |
| 4 | `run-all-tests.sh` (Move 1 target) unchanged since the ×4-green probe HEAD | `git diff --name-only 3253c180..HEAD` | 3 commits, none touch `run-all-tests.sh`; mechanism is content-agnostic | ✅ halving carries; build re-verifies at HEAD |
| 5 | max_cases lever is exhausted at ~63s ExUnit floor (why 24) | `EXUNIT_MAX_CASES` sweep on real `test-hermetic` | 65/67/63s at 24/48/96 — flat | ✅ |
| 6 | Overlap does not reintroduce tail flakiness on high-core | 4 consecutive real `make test` | ALL CLEAR ✅ every run, ±4% | ✅ (needs the real `HOOK_DEDUP_EXCLUDE`; oversubscription is what the old flake needed) |
| 7 | Studio (2-core Linux) stays on the serial tail (2 < threshold) | `nproc` on studio | 2 logical cores | ✅ overlap never triggers there |
| 8 | Sanctioned candidate-write capability existed for the spike | shipped pitch + launcher wiring | `3253c180`; claude/pi experiment launchers registered | ✅ |
| 9 | Current develop `run-all-tests.sh` carries the phase-2 serial tail (hooks/test-hermetic/rule-render) Move 1 folds, and the `HOOK_DEDUP_EXCLUDE` set that makes hooks∥ExUnit safe | `grep` on current develop file | tail at lines 13-14/257-258; `HOOK_DEDUP_EXCLUDE` at 115-119 = the exact 5-file set the pitch names | ✅ edit target grounded on current tree |
| 10 | Move 1 must validate the overlap threshold fail-loud (no fail-open to serial) — the real cause of the first build's failure | reviewer verdict in `codegen/logging/20260723_201438_.../03-reviewer-phoenix.jsonl` | `CHANGES_REQUESTED`: "oversized numeric `TAIL_OVERLAP_MIN_CORES` errors in `[` → false branch → serial; must fail exit, add range validation + regression" (gate itself was `clear`) | ✅ resolved in sketch — Move 1 now specifies range-validation + `exit 1` + regression |
| 11 | Candidate edit surface is exactly the authorized implementation set | `git status --short` before curation | 11 dirty source paths, exact equality with frontmatter scope | ✅ |
| 12 | A real current-candidate gate emitted content-bearing green evidence | captured `env -u CLAUDE_ROLE make test` | exit 0; literal `ALL CLEAR ✅ make test`; 112.91s | ✅ pre-final-snapshot-fix evidence; not relabeled as post-fix |
| 13 | Generated stack helpers begin from a clean committed app rather than weakening the loop guard | focused scaffold/fixture regressions | `codegen-scaffold create` fences parent git discovery; normal + parity helpers commit deterministic integrate baseline; 6/0 and 1/0 focused results | ✅ |
| 14 | Timing-sensitive parity fixtures remain in the one full public pool | source/reviewer inspection + focused fixture runs | readiness-event waits, bounded polls, owned PID/PGID cleanup; unrelated `sleep 30` survival regression; 16/0 each; full parity green | ✅ |
| 15 | Empty hook/snapshot populations do not invoke BSD xargs once with a blank argument | latest reviewer finding + corrected `run-tests.sh` source | hook discovery guards an empty NUL temp file; gate-pending snapshot iterates only non-empty NUL paths | ✅ fixed; final gate/re-review still required |

All feasibility claims for the deliverable (Move 1+1a+1b halving; both-platform safety) are probed. The dropped sub-60 claims are recorded in Rabbit holes. The 112.91s `ALL CLEAR` is preserved as pre-final-snapshot-fix evidence; the final snapshot correction still needs the normal build gate/re-review and must not inherit that earlier green by implication.

## References

- `PROJECT_CONTEXT.md` § Required Platforms (`required_platforms: [darwin, linux]`)
- `context/development.md` § `make test` core-gated tail overlap; § `rule-render-freshness` gate
- `context/test-harness.md` § ExUnit concurrency
- `codegen/pitches/shipped/every-harness-shapes-and-spikes.md`
- `templates/generator/run-all-tests.sh`; `Makefile` (`test-hermetic`, `harness-parity` targets)
- Experiment worktree edits: `run-all-tests.sh` (core-gated overlap), `Makefile` (`--max-cases ${EXUNIT_MAX_CASES:-24}`; parallel `harness-parity`)
- Studio failed-prior-plan transcripts: `codegen/logging/20260722_083029_adhoc/`, `codegen/logging/20260723_071352_make-test-under-sixty-is-real/`
- First queue-build failure evidence (fail-open threshold): `codegen/logging/20260723_201438_halve-make-test-with-tail-overlap/03-reviewer-phoenix.jsonl` — `REVIEW_VERDICT: CHANGES_REQUESTED`, gate itself `clear`, blocking finding = oversized `TAIL_OVERLAP_MIN_CORES` silently selects serial

### Experiment measurements (Darwin 10 logical cores / 32 GB, probe HEAD `3253c180`, `env -u CLAUDE_ROLE`)

```text
BASELINE (max_cases=24 + harness-parity parallel, serial tail):   201s  ALL CLEAR ✅
MOVE 1  (+ core-gated tail overlap):  109 / 107 / 105 / 113s (×4)  ALL CLEAR ✅  (avg 108.5s, ±4%)
MOVE 1 low-core branch (TAIL_OVERLAP_MIN_CORES=99 → serial path):  223s  ALL CLEAR ✅  (Linux path intact, no regression)

Isolated leaves:
  hooks (run-tests.sh)      85s   floor = call-dispatch_test.sh 68s
  test-hermetic (ExUnit)    63s   FLAT at max_cases 24/48/96 = 65 / 67 / 63s
  harness-parity            98s → 32s (serial for-loop → xargs -P)
```

$ `printf 'current_head='; git rev-parse --short HEAD; printf 'commits_since_probe='; git rev-list --count 3253c180..HEAD; git diff --name-only 3253c180..HEAD | grep -c run-all-tests`

```text
current_head=f21c970a
commits_since_probe=3
0        # run-all-tests.sh untouched since probe HEAD → overlap mechanism applies cleanly
```

$ `grep -nE 'TAIL_OVERLAP_MIN_CORES|HOOK_DEDUP_EXCLUDE|harness-parity' templates/generator/run-all-tests.sh | head`

```text
23:#   TAIL_OVERLAP_MIN_CORES (default 6) ...
91:TAIL_OVERLAP_MIN_CORES="${TAIL_OVERLAP_MIN_CORES:-6}"
167:HOOK_DEDUP_EXCLUDE="harnesses/claude/hooks/codegen-build_test.sh   (+ codegen-call, codegen-propose, prompt-content-parity, tools-header-no-dup)
188:{ make --no-print-directory harness-parity; } ...
307:{ HOOK_TEST_EXCLUDE="$HOOK_DEDUP_EXCLUDE" ./harnesses/claude/hooks/run-tests.sh; } ...
```

$ `grep -nE 'TAIL_OVERLAP_MIN_CORES|logicalcpu' templates/generator/run-all-tests.sh; grep -nE 'max-cases' Makefile; grep -n 'for st in' Makefile`

```text
# (overlap) ABSENT on develop  — Move 1 unbuilt
# (--max-cases) ABSENT on develop — Move 1a unbuilt
165:	for st in "$(SCRIPT_DIR)/harnesses/shared/"*_test.sh; do   # serial — Move 1b unbuilt
```

## Build failure history

| run | when | cost | terminal reason |
|---|---|---|---|
| queue drain | 2026-07-23T20:32:06Z | 3.2140839999999997 | cause=gate_failed; owner=drain/gate; detail=gate verdict="failed" — terminal: loop_failed (error); recovery=queue-fail/halve-make-test-with-tail-overlap/1784838712; raw=codegen/logging/20260723_201437_halve-make-test-with-tail-overlap_build.log |
| interrupted recovery | 20260723_223520 | unaccountable | checkpoint=parked; recovery=recovery/interrupted/halve-make-test-with-tail-overlap/20260723_223519; next=planner-inspection-required |
| interrupted recovery | 20260724_001338 | unaccountable | checkpoint=parked; recovery=recovery/interrupted/halve-make-test-with-tail-overlap/20260724_001337; next=planner-inspection-required |
| interrupted recovery | 20260724_160519 | unaccountable | checkpoint=parked; recovery=recovery/interrupted/halve-make-test-with-tail-overlap/20260724_160519; next=planner-inspection-required |
| interrupted recovery | 20260724_160725 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_160724-1410; recovery=a21be9b2f6f2cff6b75494ebf2ac9152b727f9bd; ownership=ok |
| interrupted recovery | 20260724_164137 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_164137-258; recovery=b580003adbe517a9c0ea480f836a9688fa8ee640; ownership=mismatch |
| interrupted recovery | 20260724_164534 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_164534-5414; recovery=647f9cbea6fded133bb7aba6d7e36b518cdf50d5; ownership=ok |
| interrupted recovery | 20260724_170210 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_170209-1733; recovery=91cd64710adc354e1bd166084620d005f67a7bd7; ownership=ok |
| interrupted recovery | 20260724_171449 | unaccountable | checkpoint=parked; recovery=recovery/interrupted/halve-make-test-with-tail-overlap/20260724_171449; next=planner-inspection-required |
| interrupted recovery | 20260724_172742 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_172741-1730; recovery=ed088d590bc72216dd21a78d654bae85a2b0a313; ownership=ok |
| interrupted recovery | 20260724_175000 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_175000-1730; recovery=a8ea14b03d9743cc002c0f5c32669c0cd7a9b832; ownership=ok |
| interrupted recovery | 20260724_180822 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_180822-1732; recovery=0aabb9b16ac401b083650911235f27f682952135; ownership=ok |
| interrupted recovery | 20260724_204631 | unaccountable | txn=recovery/interrupted:halve-make-test-with-tail-overlap:20260724_204630-5; recovery=9f18b38c31b55da8490bc18afef64fd565b5f350; ownership=ok |
| formal deterministic gate | 20260724_205208 | no LLM gate spend | exact 11-file pre-review snapshot; `make test` exit 0; literal `ALL CLEAR ✅ make test`; 112.91s |
| final stack attempt | 20260724 | user-cancelled | `make test-stacks` terminated by SIGTERM during `test-harness-parity`; exit 143; no final ExUnit summary; NOT green and not rerun |
| latest reviewer correction | 20260724 | no LLM gate spend | reviewer found empty `gate-pending/` snapshot invoking xargs; final WIP uses NUL-safe non-xargs snapshot plus the existing empty hook-discovery guard; post-fix gate/re-review pending |
