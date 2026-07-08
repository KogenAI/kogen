defmodule CodegenTestHarness.Stacks.Static.GateTest do
  @moduledoc """
  Gate contract for the static stack.

  Asserts that `codegen-build --stack=static` exit 0 implies a committed,
  buildable, and renderable static site. Uses vite_react as the representative
  sub-stack (rich SPA; exercises npm build + headless render checks).
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  @prompt ~s(Create a React app with Vite that shows a counter ) <>
            ~s(with data-testid="increment" and data-testid="count" elements.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir()}
  end

  test "codegen-build exit 0 implies committed buildable static site", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(cwd, @prompt,
        stack: "static",
        test_name: "gate_static_exit0"
      )

    assert File.exists?(Path.join(cwd, "package.json")),
           "expected package.json in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_npm_builds!(cwd)
    Assertions.assert_built_html_non_blank!(cwd, "public/index.html")
    Assertions.assert_git_committed!(cwd)
    Assertions.assert_renders!(cwd, :static)

    # Structured gate-result.json must be produced by the static build-check hook
    gate_result_path = Path.join(cwd, "codegen/gate-pending/gate-result.json")

    assert File.exists?(gate_result_path),
           "expected gate-result.json at #{gate_result_path} — static build-check hook must write structured result"

    gate_result = gate_result_path |> File.read!() |> Jason.decode!()

    assert gate_result["verdict"] == "clear",
           "expected gate-result.json verdict=clear, got: #{inspect(gate_result["verdict"])}"

    assert is_binary(gate_result["gate"]) and gate_result["gate"] != "",
           "expected gate-result.json gate field to be non-empty string"

    Fixtures.bench_assertions_passed!("static", "gate_static_exit0")
  end

  # "static gate failure writes non-clear verdict" (formerly drove the
  # deleted phoenix-dev-gate.sh directly) was removed — gate execution for
  # non-interactive builds is now owned by the Elixir loop's LoopGate
  # (test_harness/lib/codegen_test_harness/loop_gate.ex), whose failed-verdict
  # path is already covered by loop_gate_test.exs (fast, hermetic, no LLM).
end
