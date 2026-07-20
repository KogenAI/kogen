defmodule Mix.Tasks.Codegen.Bench.RoleModelSweepTest do
  @moduledoc """
  Hermetic tests for `mix codegen.bench.role_model_sweep`'s CLI argument
  parsing. No LLM calls, no spend. Deep campaign-mechanics coverage (matrix
  validation, baseline resolution, scheduling, classification, aggregation)
  lives in `CodegenTestHarness.RoleModelSweepTest` — this file exercises only
  the thin task's own `--matrix`/`--reason`/`--validate-only` contract.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Codegen.Bench.RoleModelSweep

  test "raises when --matrix is missing" do
    assert_raise Mix.Error, ~r/--matrix is required/, fn ->
      RoleModelSweep.run(["--reason", "smoke"])
    end
  end

  test "raises when --reason is missing" do
    assert_raise Mix.Error, ~r/--reason is required/, fn ->
      RoleModelSweep.run(["--matrix", "some/path.yaml"])
    end
  end

  test "raises on an invalid switch" do
    assert_raise Mix.Error, ~r/Invalid options/, fn ->
      RoleModelSweep.run(["--bogus", "x"])
    end
  end

  test "raises naming the matrix file when it does not exist" do
    assert_raise RuntimeError, ~r/matrix file not found/, fn ->
      RoleModelSweep.run([
        "--matrix",
        "/tmp/nonexistent_role_model_sweep_matrix_#{:erlang.unique_integer([:positive])}.yaml",
        "--reason",
        "smoke",
        "--validate-only"
      ])
    end
  end
end
