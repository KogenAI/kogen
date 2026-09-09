# Convert every test module to async

The human requires **zero synchronous test modules**, including the opt-in live
tests. This replaces the earlier allowance for documented synchronous exceptions.
Inventory at shaped head: 22 ExUnit modules, 20 with `async: false`, two already
with `async: true`. This is an implementation plan, not completed conversion.

## Common conversion mechanism

Keep the parent test VM's cwd and environment stable. Every module must explicitly
use `async: true`. Do not hide serialization behind one global lock, an ExUnit
group, a single child queue, or tests omitted from the gate.

For tests of APIs that currently depend on cwd/environment, the recommended small
change is a test-support helper that runs the affected operation and its closely
related assertions in an isolated Elixir OS process. Pass the fixture as child
`cd:` and overrides as child `env:`. Load the current build's compiled application
and dependency code using absolute code paths, rather than recompiling a project
per assertion. Existing production APIs and CLI arguments remain unchanged.

The helper must execute trusted test code only, return original error/return-value
evidence where the parent asserts it, distinguish exceptions from expected error
tuples, preserve child stdout/stderr, impose a finite deadline, and reap children
before fixture cleanup. Do not attempt to send arbitrary parent closures to a
fresh VM. A small named-operation or trusted-script helper is sufficient; do not
build a general RPC framework. Group causally sequential operations in one child
per case rather than paying a launch for each assertion.

Use unique per-test fixtures, raw logs, scratch directories, Git repositories,
index paths, and hook input files. Names must remain unique across OS processes:
`System.unique_integer/1` alone is VM-local. Give each child a private temp root,
or use atomically created PID-qualified directories. Share only immutable inputs
and already-compiled code; never share a writable Mix build path between children.
Capture the repository source root once before tests start, rather than relying
on mutable runtime cwd in fixture helpers.

Explicit internal path/options APIs are an alternative where a small change
eliminates an entire child launch, but are not a prerequisite for making every
test module async. Avoid a broad production-context refactor just for test flags.

## Complete inventory and per-file conversion

All paths below are under `test/kogen/`. Each row requires `async: true` after its
isolation changes, with every existing behavioral assertion retained.

| Module file | Present blocker / evidence | Concrete conversion |
| --- | --- | --- |
| [approved_mutation_test.exs](../../../../test/kogen/approved_mutation_test.exs) | Harness env mutation at 131; `File.cd!` around Build at 139; nine independently constructed fixtures. | Run each Build with child-local cwd and fake-harness env; inspect fixture bytes and commit state in parent using absolute paths. Convert the phase × mutation matrix to ExUnit `parameterize` so nine independent parameter instances can overlap. Reuse an immutable fixture template, not a mutable repository. |
| [boundary_negative_control_test.exs](../../../../test/kogen/boundary_negative_control_test.exs) | No parent cwd/env mutation; subprocess compilation already uses `cd: fixture_dir` at 40 and 47. | Enable async, keep private fixture `_build`, use absolute read-only Boundary source path, and retain both the warning and warnings-as-errors negative controls in their required order. |
| [build_preconditions_test.exs](../../../../test/kogen/build_preconditions_test.exs) | Global harness env at 281 and cwd at 294. | Prepare each bad-state repository independently; invoke Build in a child with the launch-denial fake supplied only to that child. Return the exact error tuple and retain lock-release/no-launch assertions. Use parameterization for genuinely uniform invalid-target/config cases; keep distinct behaviors as distinct tests. |
| [check_test.exs](../../../../test/kogen/check_test.exs) | `in_tmp_cwd` helper at 175–187; relative record paths and Make target execution. | Leave pure validation tests in the parent. Run cwd-dependent record/target operations in the isolated helper, or give those internal operations explicit fixture paths. Write records with absolute paths; ensure every Make command has the fixture cwd. No parent `File.cd!`. |
| [commit_failure_rollback_test.exs](../../../../test/kogen/commit_failure_rollback_test.exs) | Global harness at 71, Build cwd at 81 and 107. | Keep the failing commit and recovery/retry causally ordered against one private repo; execute them in a child with private harness env. Retain exact Approved/index/worktree checks between attempts and the final successful retry. |
| [commit_provenance_test.exs](../../../../test/kogen/commit_provenance_test.exs) | Global harness at 33 and cwd at 43, 64, 72. | Execute the first and subsequent Builds in the same isolated case/fixture, preserving their sequential history; inspect commit messages/trailers through `git` with explicit `cd:`. Scope fake harness and temporary trailer files to the case. |
| [core_integrity_test.exs](../../../../test/kogen/core_integrity_test.exs) | Global raw-log env at 51, harness at 203, cwd at 205 and 271. | Give each archive or Build case a child cwd and explicit raw-log/harness env; use absolute record paths in parent setup/assertions. Preserve all malformed verdict, identity, symlink, stale-record and late-Complete-path negative controls. |
| [git_integrity_test.exs](../../../../test/kogen/git_integrity_test.exs) | Shared cwd helper at 76; bare Git commands and relative candidate paths. | Run each Git API sequence inside a child rooted in its private repo, or use a small explicit root option through Git operations. Use explicit `cd:` for parent inspection commands. Preserve private-index, ignored/staged-file and quoted-path assertions. |
| [git_test.exs](../../../../test/kogen/git_test.exs) | Multiple `File.cd!` blocks and bare Git helpers at 177–187. | Isolate each repository's entire candidate/commit sequence in one child; resolve all parent file and Git paths explicitly. Keep commit/trailer and allowed-diff assertions. Do not share fixture history or indexes across cases. |
| [harness_role_test.exs](../../../../test/kogen/harness_role_test.exs) | Global role/harness/raw-log variables at 37–43; fake unconditionally reads stdin at 27. | Put hostile inherited role and other env overrides inside a child. Make the fake read stdin only for noninteractive Developer/Reviewer transports. Keep all four launch-role assertions. Add bounded pipe and PTY probes with no user EOF; preserve real interactive Shaping's terminal access. |
| [harness_verdict_test.exs](../../../../test/kogen/harness_verdict_test.exs) | Global harness/raw-log env at 35–36 and verdict env at 43. | Run verdict cases with child-local env and private output dirs; return the exact parse/validation result. Keep all malformed and empty-rework cases. Parameterize uniform verdict inputs if launch cost warrants it; never share one verdict file across concurrent cases. |
| [lifecycle_test.exs](../../../../test/kogen/lifecycle_test.exs) | Parent already uses explicit child cwd/env; the expensive problem is recursive aggregate checking and cloned-project compilation. | Enable async. Replace only the fixture's aggregate Makefile with a deterministic bounded check that genuinely fails then passes through the tracked hook. Reuse current compiled task code in a private fixture without writable build-cache sharing. Preserve public Mix task dispatch, Shape/approval/Build flow, all receipts, exactly one outer resume and commit assertions. |
| [live_shape_to_build_test.exs](../../../../test/kogen/live_shape_to_build_test.exs) | Already child-isolated at 93/150 and 253; unique fixture and evidence roots, private `_build`. | Enable async; harden timestamp-only fixture names with atomic/PID-qualified uniqueness. Keep separate provider transcripts, Codex sessions, log dirs and fixture builds. The two scenarios may remain sequential within their module because each scenario itself contains ordered interactions; split into separate async modules only if overlap of these two independent scenarios is needed. No live provider run during shaping. |
| [live_test.exs](../../../../test/kogen/live_test.exs) | Parent changes raw-log env at 26 and cwd at 33. | Move the Developer/resume/Reviewer sequence to one isolated child with fixture cwd and raw-log env; keep session continuity within that child and inspect evidence from its private directory. Enable async alongside the other live module. Do not introduce shared provider-session identifiers or raw paths. |
| [reviewer_mutation_test.exs](../../../../test/kogen/reviewer_mutation_test.exs) | Global harness at 106 and cwd at 114. | Invoke Build in its own fixture child, passing only that child's mutation fake; inspect repo/head/evidence using explicit paths. Keep the assertion that Reviewer mutation prevents publication. |
| [shape_task_test.exs](../../../../test/kogen/shape_task_test.exs) | Already child-isolated at 30; full clone recompiles application/dependencies. | Enable async and use the same private fixture/compiled-code strategy as lifecycle. Keep the public Mix task, minted identity, configured metadata, persisted Draft and explicit fixture rename checks; no shared mutable cache. |
| [stop_hook_test.exs](../../../../test/kogen/stop_hook_test.exs) | Already explicit child cwd/env at 99–102; unique hook/Git fixtures. | Enable async; retain private hook input files, Makefiles, records and repositories. Its four tests can overlap other modules; keep the failed-then-passed sequence within its single scenario ordered. |
| [two_outer_resumptions_test.exs](../../../../test/kogen/two_outer_resumptions_test.exs) | Global harness at 112 and cwd at 121. | Execute the bounded rework sequence in a private child; return its error result and inspect unchanged HEAD/Approved state afterward. Do not parallelize turns within this one Build. |
| [verification_ownership_lifecycle_test.exs](../../../../test/kogen/verification_ownership_lifecycle_test.exs) | Global harness/raw-log env at 12–13 and cwd at 27. | Run the fixture Build in a child with those two env settings. Keep its owner log, archive dir, gate flags and policy under the fixture. Retain exact ordering and fresh-Check assertions; concurrency is between independent cases, not between ordered gates. |
| [verification_policy_test.exs](../../../../test/kogen/verification_policy_test.exs) | `preflight` checks use `File.cd!` at 73, 79, 94; shell probes already use explicit cwd/env. | Isolate only preflight calls in the child helper or add a narrow internal root argument; leave the pure classifier and already-isolated shell probes in the parent. Preserve all blocked and allowed command forms and malformed-policy cases. |

Already async: `harness_args_test.exs` and `intent_test.exs`. Keep them async and
ensure new fixture/bootstrap helpers do not add global state to them.

## Bootstrap and within-module concurrency

`test/test_helper.exs` is not a test module. Its env mutations happen before tests
start, so they are not currently concurrent races. Prefer passing the Git signing
override and raw-log isolation through the common child fixture environment;
otherwise keep the bootstrap values immutable for the whole suite. Remove all
per-test parent env mutation/restoration. Never disable the user's signing
settings outside fixture processes/repositories.

The installed Elixir 1.20.2 `ExUnit.Case` documentation was read with
`Code.fetch_docs/1`: `async` overlaps modules, while tests in one module remain
sequential. Its supported `parameterize` option overlaps independent parameter
instances when `async: true`. Use it for the uniform mutation matrix. Do not
misrepresent a mere flag change as parallel execution of all individual cases.
Ordered steps within one scenario remain ordered; zero synchronous modules does
not mean running a commit before its prerequisite Build.

## Performance feasibility and verification

Measured on this shaping machine:

| Probe | Wall time | Scope |
| --- | ---: | --- |
| Original ordinary suite | 18.5 s ExUnit | 93 passing tests, excluding two lifecycle and three live tests |
| Same 93 tests in four isolated OS processes | 8.175 s | All 93 passed; precompiled code; separate temp roots; piped EOF |
| Format + forced compile + strict Credo | 1.298 s | 0.239 + 0.560 + 0.499 seconds; all passed |
| Bounded minimal lifecycle with compiled code | 2.441 s | Shape 0.987 + Build 1.454; both exit zero; one outer resumption; accepting Review |

The four-process probe was only an isolation/performance experiment. Its test
modules were still synchronous internally; it is not the final async design or
a complete passing `make check`. The longest shard was the nine-case mutation
module plus the two existing async modules, at 8.168 seconds. Parallelizing that
matrix removes an identifiable remaining serial bottleneck.

An approximate overlapped budget is 1.30 seconds of outer tools plus the maximum
of ordinary-test and bounded-lifecycle time, approximately 9.5 seconds before
unmeasured scheduling/fixture overhead. These independently measured times cannot
be added into a claim of success. Contention could push the combined run over ten
seconds. Native async tests, finer matrix concurrency and cheaper fixture setup
should provide margin, but require measurement.

Conclusion: **under ten seconds for the complete warm-cache offline gate is
plausible and worth targeting, not demonstrated yet**. Simply setting twenty
flags is insufficient. Keep the ten-second acceptance and measure the actual
whole gate after conversion. Cold dependency compilation and `make live` remain
outside that latency budget; neither is allowed to be confused with dropped
offline coverage.

Completion requires all 22 existing modules (and any added modules) explicitly
async, no hidden global serialization or parent cwd/env mutations during tests,
all retained cases accounted for, concurrent fixture-isolation regression probes,
the full offline gate below the limit, and real opt-in live verification for the
two converted provider-backed modules. Preserve the existing gate ownership.
