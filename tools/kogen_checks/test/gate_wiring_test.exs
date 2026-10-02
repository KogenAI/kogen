defmodule KogenChecks.GateWiringTest do
  use ExUnit.Case, async: true

  @credo_path Path.expand("../../../.credo.exs", __DIR__)
  @custom_checks [
    KogenChecks.Check.BroadRescue,
    KogenChecks.Check.DomainReach,
    KogenChecks.Check.DomainSize,
    KogenChecks.Check.ForbiddenCall,
    KogenChecks.Check.SizeLimits,
    KogenChecks.Check.TestModuleShape
  ]

  test "every custom check is enabled in the repository Credo config" do
    {config, _binding} = Code.eval_file(@credo_path)
    enabled = config.configs |> hd() |> Map.fetch!(:checks) |> Map.fetch!(:enabled)
    enabled_checks = Enum.map(enabled, &elem(&1, 0))

    assert Enum.all?(@custom_checks, &(&1 in enabled_checks))
  end
end
