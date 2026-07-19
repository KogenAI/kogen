# Snapshot the live codegen/logging/ dir's filenames BEFORE the suite runs,
# so the after_suite backstop below can detect any new file the suite wrote
# there. This is the mix-test-process analogue of run-tests.sh's gate-pending
# snapshot/diff backstop (harnesses/claude/hooks/run-tests.sh) — a different
# live operational dir, guarded from a different test runner. Root cause of
# the leak this guards against: OrchestrationLoop.default_log_init/3 shells
# the real codegen-log with CODEGEN_DIR pinned to the live repo root (correct
# for production — the loop runs from test_harness/ and needs it to locate
# codegen/), and codegen-log resolves CODEGEN_DIR before cwd, so any run/1
# caller that omits a :log_init_fn stub silently writes a real cycle log into
# the LIVE codegen/logging/ dir instead of a test sandbox. See
# context/test-harness-pitfalls.md.
_live_logging = Path.expand("../../codegen/logging", __DIR__)

_logging_before =
  if File.dir?(_live_logging) do
    MapSet.new(File.ls!(_live_logging))
  else
    MapSet.new()
  end

ExUnit.after_suite(fn _results ->
  after_set =
    if File.dir?(_live_logging) do
      MapSet.new(File.ls!(_live_logging))
    else
      MapSet.new()
    end

  leaked = MapSet.difference(after_set, _logging_before)

  unless MapSet.size(leaked) == 0 do
    IO.puts(
      :stderr,
      "FAIL — ExUnit wrote into live codegen/logging/: #{Enum.join(Enum.sort(leaked), ", ")}"
    )

    System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end
end)

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
