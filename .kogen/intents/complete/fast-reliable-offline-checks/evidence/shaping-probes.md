# Shaping probes — 2026-09-09

Baseline branch/head: `main`, `6403ebd8139b8add5e071f52a43179c885aad9f7`.
These are concise observed receipts, not raw transcripts or completed-build proof.
No production or test implementation was changed during these probes.

## User-reported failures

- Full `make check`: 152.2 seconds ExUnit / 153.8 seconds command wall time,
  with the role test timing out at 60 seconds and lifecycle evidence reporting
  two outer resumptions instead of the expected one (seed 273705).
- Another run: 133.1 seconds ExUnit / 134.79 seconds command wall time,
  with the role timeout only (seed 631822).

## Ordinary suite

Root ran `mix test --exclude live --exclude lifecycle --trace` with an accidental
additional `--exclude test/kogen/harness_role_test.exs`. That extra argument is an
ExUnit tag, not a file exclusion: the role test DID run and passed in 197.3 ms.
Result: 93 passed, 5 excluded; 18.5 seconds (0.09 async / 18.4 sync), seed 112465.
Examples: ApprovedMutation's nine cases total roughly 4.2 seconds; Boundary
negative control 0.98 seconds; verification ownership lifecycle 1.29 seconds.
Many other cases create real Git repositories and launch local subprocesses.

## Standalone full fake lifecycle

`mix test test/kogen/lifecycle_test.exs --trace`: one passed, 52.2 seconds,
seed 291695. The extra-resumption failure did not reproduce.

`test/support/fake_codex` invokes the tracked Stop hook for the deliberate
failure, the in-conversation correction, and Reviewer-directed rework.
`.codex/hooks/check.sh` invokes `make check`. The fixture clones the root Makefile,
and `KOGEN_INNER_CHECK=1` excludes only lifecycle-tagged tests, so passing checks
repeat almost the whole ordinary suite, format, forced compile, and Credo.

## Terminal probe (configured scout)

The role test sets `KOGEN_HARNESS` to a temporary shell fake. Its unconditional
`cat >/dev/null` is at `test/kogen/harness_role_test.exs:27`.
`lib/kogen/harness.ex:125` intentionally launches interactive Shaping with
`:nouse_stdio`, inheriting terminal input.

Pipe execution passed in approximately 0.5 seconds. A focused PTY execution
remained waiting with no completion after five seconds. Sending Ctrl-D caused
the test to complete successfully (one passed; reported elapsed 11.4 seconds,
including the deliberate wait and tool interaction). The process exited zero;
the helper reported no remaining probe process. This demonstrates terminal EOF
dependence in the fake, not provider traffic.

## Advisory scope investigation (configured worker)

The heavy suites use `async: false` because they mutate VM-global cwd and
environment. Simply enabling async is unsafe. Repeated fixture preparation is
an optimization opportunity; isolated OS-process concurrency is a possible
further design, not a measured solution. Under-ten-second feasibility remains
unproven. The human subsequently required the full fix rather than a partial
delivery or a separate slow target.

## Follow-up async feasibility probes

The human subsequently required zero synchronous modules and a per-module plan.
Inventory: 20 `async: false` modules, two `async: true`, no other ExUnit modules.
See [conversion plan](../async-conversion-plan.md) for every file.

A four-process ordinary-suite probe ran the same 93 tests with seed 631822,
separate child TMPDIRs and stdin EOF, using `mix test --no-compile --no-deps-check`.
All four subprocesses exited zero: 29 + 23 + 28 + 13 tests passed in 8.175 seconds
wall time. Existing compiled code was used; no real provider was launched. This
is not evidence that the source modules are async, nor a full gate timing.
[Receipt](parallel-ordinary-probe.json).

Format, forced warnings-as-errors compilation, and strict Credo were measured
sequentially at 0.239, 0.560, and 0.499 seconds, all exiting zero.

A disposable minimal fixture copied config, hooks, prompts and fake executables.
Its Makefile check failed while `lib/kogen_fake_break.ex` existed. Real public
Mix task modules were dispatched via `elixir -pa <current compiled ebin paths>
-S mix kogen.shape` and `kogen.build`. Shape took 0.987 seconds; Build took 1.454
seconds. Both exited zero; Complete evidence reported one outer resumption and
an accepting Reviewer. Fixture approval was a scripted rename for this test only,
not approval of the real Draft. The fixture was removed.
[Receipt](bounded-lifecycle-probe.json).

This probe changes task code-loading and uses a minimal fixture; it does not
verify unmodified bare `mix` task discovery, all original lifecycle assertions,
or the final combined gate under contention. Production/test source files in the
checkout were not edited. The full latency target is still unproven.
