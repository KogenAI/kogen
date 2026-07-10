ExUnit.start(exclude: [:slow, :harness_parity])

# `OrchestrationLoop.run/1` acquires a per-cwd single-flight lock by default
# (see CodegenTestHarness.BuildLock). Pre-existing async: true tests share a
# fixed cwd literal ("/tmp/irrelevant") across dozens of concurrent cases
# that exercise role-sequencing/gate logic — an orthogonal concern from
# locking. Setting the queue-child bypass env for the whole suite isolates
# those tests from lock contention; the lock/orphan-scan mechanism itself is
# exercised directly by dedicated BuildLock / orchestration_loop_test.exs
# lock-specific tests that unset this var for their own process.
System.put_env("CODEGEN_BUILD_LOCK_HELD", "1")
