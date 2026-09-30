defmodule Kogen.VerificationRunnerProductRouteTest do
  @moduledoc """
  Live (provider-backed) targets run on the Build's selected route as frozen
  at admission, never the Candidate's `default_route`.
  """
  use ExUnit.Case, async: true

  alias Kogen.Build.VerificationRunner

  @config Path.expand("../../.kogen/config.yaml", __DIR__)

  defp candidate(config) do
    root =
      Path.join(System.tmp_dir!(), "kogen-product-route-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".kogen"))
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(
      Path.join(root, "Makefile"),
      "probe:\n\t@printf 'route=%s\\n' \"$$KOGEN_ROUTE\"\n"
    )

    if config, do: File.write!(Path.join(root, ".kogen/config.yaml"), config)
    {root, Path.join(root, "probe.log")}
  end

  test "a live target gets the selected route, not the Candidate's default_route, and records it" do
    {root, log} = candidate(File.read!(@config))
    {:ok, default} = Kogen.Intent.read_config(@config, nil)
    refute default.route == "selected-route"

    assert {:ok, %{"exit_code" => 0} = facts} =
             VerificationRunner.run_target(root, "probe", log,
               route: "selected-route",
               provider_backed: true
             )

    assert facts["route"] == "selected-route"
    assert File.read!(log) =~ "route=selected-route"
    refute File.read!(log) =~ "route=#{default.route}"
  end

  test "an offline target gets the selected route too and records no live route" do
    {root, log} = candidate(File.read!(@config))

    assert {:ok, %{"exit_code" => 0} = facts} =
             VerificationRunner.run_target(root, "probe", log, route: "selected-route")

    refute Map.has_key?(facts, "route")
    assert File.read!(log) =~ "route=selected-route"
  end

  test "a live target without a selected route fails, with no default_route fallback" do
    {root, log} = candidate(File.read!(@config))

    assert {:error, reason} =
             VerificationRunner.run_target(root, "probe", log, provider_backed: true)

    assert reason =~ "selected route"
    refute File.exists?(log)
  end
end
