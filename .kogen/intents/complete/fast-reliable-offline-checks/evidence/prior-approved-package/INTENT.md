# Make the complete offline check fast and reliable

## Problem and outcome

The human reports complete `make check` runs of 133–152 seconds, a 60-second
fake-Shaper timeout, and an intermittent lifecycle assertion reporting two outer
resumptions instead of one. This is one coherent change to the reliability and
latency of the existing offline verification entry point.

The human explicitly requires fixing all of these problems, including the
ordinary suite's overhead. A partial fix or moving existing coverage to a
separate slower target does not satisfy this Intent. Keep `make check` as the
complete offline gate and retain its behavioral coverage.

Proposed performance acceptance: the entire successful `make check` takes less
than 10 seconds wall time on the shaping macOS machine, with dependencies
already installed and ordinary local build caches warm. Measure the command
including formatting, compilation, Credo, and tests, not just ExUnit's total.
Also verify an empty local build cache succeeds offline; its initial dependency
compilation is not included in the proposed ten-second warm-run limit.

## Appetite and approach

One Build, one Developer conversation, with the configured two outer resumptions.
Work within this scope; do not call the change complete after only the easy fixes.
The ten-second budget is a required outcome of this Draft, not an observed result
or a claim of demonstrated feasibility. If it cannot be met within the appetite,
report the measured remaining bottleneck rather than weaken acceptance silently.

1. Correct the role-test fake's transport behavior: Shaping receives its initial
   prompt as an argument and must not consume terminal input until EOF. Preserve
   the real interactive Shaper's terminal access. Keep all role-override checks.
2. Replace the fake lifecycle clone's recursive aggregate checks with a small,
   deterministic real fixture check. Keep the tracked Stop-hook invocation,
   deliberately failing Check, correction within the same Developer thread,
   fresh passing Check, independent Reviewer rework, exact resume, fresh accepting
   Reviewer, commit, and evidence assertions. A canned Verification Record or
   unconditional successful check is not a substitute.
3. Eliminate synchronous test modules as explicitly required by the human.
   Convert all 20 currently synchronous modules, including both live modules,
   and keep all existing and new test modules explicitly `async: true`. Follow
   the complete [per-file conversion plan](async-conversion-plan.md). Isolate mutable
   working directories and environment in separate OS processes, or use explicit
   per-operation context where a small internal change suffices; do not merely
   turn VM-global mutation tests async. No synchronous module exceptions or hidden global serialization are allowed.
   Preserve ordered steps within each individual scenario.
   Also reuse safe fixture preparation and eliminate redundant subprocess/build
   setup based on profiling. Any
   process runner must execute each intended test exactly once, propagate every
   failure, finish all children, and avoid shared writable fixture/cache races.
   Prefer the smallest approach that meets the budget; avoid a general runner
   framework or a broad production API refactor.
4. Investigate and eliminate the unexpected extra lifecycle resumption. Preserve
   the assertion of exactly one outer resume for Reviewer rework. Record the
   failing settlement reason and causal regression evidence; do not change the
   expected count, accept either value, retry until green, or raise timeouts.
5. Keep the complete gate offline: no real Codex/provider/API requests or
   dependency downloads after prerequisites are installed. Keep `make live`
   separate and explicitly opt-in. Preserve format, warnings-as-errors, Credo,
   Boundary negative control, and existing failure/integrity coverage.

Guarded production paths are available only for changes causally necessary to
these outcomes. They do not authorize unrelated product changes. New reusable
check scripts belong in `scripts/check/`, with concise refresh/run instructions
linked from README, rather than temporary directories.

## Verification and evidence

Offline scenarios use the existing `check` Make target. The all-async scenario
also declares the existing `live` target because both provider-backed test modules
are being converted; its runtime is outside the ten-second offline budget. During Build, the Developer's
Stop hook retains gate ownership; the Developer and helpers use focused non-gate
probes only. Capture elapsed time for the actual owned complete gate, or have the
normal verification mechanism report it. Do not sneak an extra full gate through
a benchmark wrapper or a child test. A PTY regression should invoke the focused
role behavior in a bounded child and must not recursively invoke the whole suite.

Record platform/toolchain, timing conditions, whole-command elapsed time, test
selection/coverage accounting, and focused stability results. Exercise the
reported seeds 273705 and 631822 plus additional fixed seeds for the relevant
focused regression cases. Timing success must accompany a passing gate, not
mask failures. A cold-build success check must not download dependencies.

Update README to explain the resulting check implementation and prerequisites;
remove stale recursive-suite guidance if that mechanism is removed.

## Non-goals

- Splitting existing offline coverage out of `make check`, skipping slow tests,
  weakening assertions, increasing test timeouts, or hiding flaky failures.
- Optimizing provider latency or running real providers as part of the offline
  gate. Async conversion of both live modules is explicitly included.
- Changing public Shape/Build interfaces, approval rules, verification ownership,
  resumption policy, model configuration, or unrelated production behavior.
- A portable performance guarantee for all hardware or a ten-second cold
  dependency compilation guarantee (the proposed measurement boundary is called
  out in questions.md).

## Provenance and state

The human directed “FIX ALL, NOT JUST ONE THING” and then explicitly included
removing all synchronous test modules. This resolves the scope against a
partial fix. The human subsequently explicitly approved the complete package in
this same conversation with “approve”.
See the [per-file async plan](async-conversion-plan.md), [questions](questions.md),
and [shaping evidence](evidence/shaping-probes.md).
