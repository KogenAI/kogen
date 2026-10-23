# Native test-gate harness qualification

Installed-release modules using `Helpers.setup_suite!` share ExUnit's
`:installed_release` group when async; synchronous modules remain synchronous.
Each module installs its own prefix from the once-per-invocation source archive.
`KOGEN_ARCHIVE` remains an explicit alternative archive input.

Case Ports belong to an unlinked custodian rather than the ExUnit test process.
It forwards the original Port messages to the caller, retaining custody for cleanup
when that caller shuts down or is killed. Cleanup first uses CLI cancellation,
then bounded escalation only within the invocation's retained OS session, and
waits before removing files. A test-only Python relay keeps that session in custody
even if the CLI exits before a project-command child. Exit status is preserved;
a separate completion marker establishes descendant termination. Cleanup failures are raised, not converted into successful removal.
Preparation invocations use the same custody path. The postcommit interruption
fixture uses a test-only installed-core wrapper and a receive-trace acknowledgment
of cancellation delivery to the core mailbox before releasing the Git query.
Production signal handling and deadlines are unchanged.

## Reviewer regression evidence

The custody regression `sleep 600 & ...; exit 196` exposed an early-parent-exit
leak: a reaped CLI does not prove its children have exited. The retained session
now terminates those children before forwarding completion. Preparation-time
Git, packaging and installation use the same custody path; an owner monitor
cleans incomplete preparation before removing its workspace.

Focused reviewer run: `mix test test/integration/integration_helpers_test.exs
test/integration/build_boundaries_test.exs
test/integration/shape_context_publication_test.exs --seed 0 --max-failures 1`,
exit 0, **36 passed**, **201.5 seconds**. This includes eight helper regressions,
the 28 reported integration cases and fresh archive preparation. It is not a
rerun of the unfiltered gate or a supported-platform release qualification.

## Observed local evidence

Platform: Darwin arm64, Elixir 1.20.4 / Erlang OTP 29.

- Unfiltered `mix test`, seed 807887: exit 0, **270 passed** (3 properties,
  267 tests), **726.0 seconds** (694.4 async, 31.5 sync). Complete combined output
  is retained in `mix-test.txt`. This run includes the changed installed-release
  modules, lifecycle/marker regressions and postcommit acknowledgment. Two further
  preparation/startup harness regressions were added afterward.
- Focused final helper regressions: `mix test
  test/integration/integration_helpers_test.exs --max-failures 1`, seed 172506:
  exit 0, **6 passed**, **12.0 seconds**.
- Independent real installed-Build lifecycle driver: `mix run
  features/steps/deterministic_check_gate_driver.exs measure`, exit 0. Both normal
  shutdown and abrupt owner death reported the CLI and command child stopped,
  workspace removed, cleanup returned, and unrelated process alive. The delayed
  11000 ms marker and explicit missing-marker bound both passed.

These are local development observations, not a macOS-and-Linux release
qualification or an explanation of every historical host failure. Failed probe
runs during development were repaired rather than retried for a successful result;
in particular the postcommit wrapper loads its test instrumentation from a file,
not a multiline release `eval` argument (which produced a startup bus error here).
The configured checks, acceptance measurement and independent review still apply
to the final candidate.
