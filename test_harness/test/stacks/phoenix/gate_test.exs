defmodule CodegenTestHarness.Stacks.Phoenix.GateTest do
  @moduledoc """
  Gate contract for the phoenix stack.

  Asserts that `codegen-build --stack=phoenix` exit code reflects the
  dev-gate verdict: exit 0 means a committed, compilable app was produced.
  Mirrors the exit-code assertion shape of scaffold_test.exs.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  @prompt ~s(Build a Phoenix LiveView todo app. The router MUST have ) <>
            ~s(live "/", TodoLive, :index. TodoLive MUST render a ) <>
            ~s(<form id="new-todo-form"> with an <input name="todo[title]"> ) <>
            ~s(and a <button data-testid="add-todo">.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir(stack: :phoenix)}
  end

  test "codegen-build exit 0 implies committed compilable phoenix app", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(cwd, @prompt, stack: "phoenix", test_name: "gate_phoenix_exit0")

    assert File.exists?(Path.join(cwd, "mix.exs")),
           "expected mix.exs in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_generated_tests_pass!(cwd)
    Assertions.assert_git_committed!(cwd)

    live_files =
      cwd
      |> Path.join("lib/*_web/live/**/*.ex")
      |> Path.wildcard()

    assert live_files != [],
           "expected at least one LiveView file under lib/*_web/live/ in #{cwd}"

    router_files = Path.wildcard(Path.join(cwd, "lib/*_web/router.ex"))
    assert router_files != [], "no router.ex found under lib/*_web/ in #{cwd}"
    [router | _] = router_files
    Assertions.assert_router_root_route_replaced!(router)
    Assertions.assert_renders!(cwd, :phoenix)

    # Structured gate-result.json must be produced by the dev-gate hook
    gate_result_path = Path.join(cwd, "codegen/gate-pending/gate-result.json")

    assert File.exists?(gate_result_path),
           "expected gate-result.json at #{gate_result_path} — dev-gate hook must write structured result"

    gate_result = gate_result_path |> File.read!() |> Jason.decode!()

    assert gate_result["verdict"] == "clear",
           "expected gate-result.json verdict=clear, got: #{inspect(gate_result["verdict"])}"

    assert is_binary(gate_result["gate"]) and gate_result["gate"] != "",
           "expected gate-result.json gate field to be non-empty string"

    Fixtures.bench_assertions_passed!("phoenix", "gate_phoenix_exit0")
  end

  # "phoenix gate failure writes non-clear verdict" (formerly drove the
  # deleted phoenix-dev-gate.sh directly) was removed — gate execution for
  # non-interactive builds is now owned by the Elixir loop's LoopGate
  # (test_harness/lib/codegen_test_harness/loop_gate.ex), whose failed-verdict
  # path is already covered by loop_gate_test.exs (fast, hermetic, no LLM).
end
