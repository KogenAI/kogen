defmodule Kogen.SelectiveVerificationTargetsTest do
  use ExUnit.Case, async: true

  alias Kogen.Check

  @root Path.expand("../..", __DIR__)
  @owners %{
    "live" => %{
      "test/kogen/live_shape_to_build_test.exs" => 2,
      "test/kogen/live_test.exs" => 1
    },
    "live-shaping-quality" => %{"test/kogen/live_shaping_evaluation_test.exs" => 1},
    "live-native" => %{
      "test/kogen/codex_native_live_test.exs" => 2,
      "test/kogen/codex_compatibility_test.exs" => 1,
      "test/kogen/native_helper_live_test.exs" => 1
    },
    "cold-offline" => %{"test/kogen/cold_offline_test.exs" => 1}
  }

  test "focused targets are declared and select every former live owner exactly once" do
    makefile_path = Path.join(@root, "Makefile")
    makefile = File.read!(makefile_path)
    declared = Check.declared_targets(makefile_path)

    assert Enum.all?(["check" | Map.keys(@owners)], &MapSet.member?(declared, &1))
    assert :ok = Check.validate_targets(Map.keys(@owners), makefile_path)
    refute recipe(makefile, "live") =~ "mix test --only live\n"

    selected =
      for {target, owners} <- @owners,
          {path, expected_cases} <- owners do
        source = File.read!(Path.join(@root, path))
        assert source =~ ~r/@(?:module)?tag :live/
        assert live_case_count(source) == expected_cases
        assert recipe(makefile, target) =~ path
        {path, target}
      end

    assert length(selected) == 7

    assert selected |> Enum.map(&elem(&1, 0)) |> Enum.frequencies() |> Map.values() ==
             List.duplicate(1, 7)

    all_live_owners =
      Path.wildcard(Path.join(@root, "test/kogen/*_test.exs"))
      |> Enum.reject(&String.ends_with?(&1, "/selective_verification_targets_test.exs"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/@(?:module)?tag :live/))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert Enum.sort(Map.keys(Map.new(selected))) == all_live_owners
  end

  test "recipes preserve offline and provider boundaries" do
    makefile = File.read!(Path.join(@root, "Makefile"))

    assert recipe(makefile, "check") =~ "scripts/check/offline.py"
    assert recipe(makefile, "cold-offline") =~ "test/kogen/cold_offline_test.exs"

    for target <- ["live", "live-shaping-quality", "live-native"] do
      refute recipe(makefile, target) =~ "cold_offline_test.exs"
    end

    refute recipe(makefile, "live") =~ "live_shaping_evaluation_test.exs"
    refute recipe(makefile, "live") =~ "native_live_test.exs"
    refute recipe(makefile, "live") =~ "native_helper_live_test.exs"
  end

  test "selection guide chooses targets by behavior and explains paid evidence" do
    guide = File.read!(Path.join(@root, "README.md"))

    cases = [
      {"Offline sufficiency", "check only"},
      {"configured-default lifecycle", "`live`"},
      {"Shaping quality", "`live-shaping-quality`"},
      {"authenticated native boundary", "`live-native`"},
      {"Cold-cache behavior", "`cold-offline`"},
      {"multiple affected boundaries", "each relevant target"}
    ]

    for {claim, selection} <- cases do
      assert guide =~ claim
      assert guide =~ selection
    end

    assert guide =~ "causal reason"
    assert guide =~ "not by edited filenames"
    assert guide =~ "provider-backed"
  end

  defp recipe(makefile, target) do
    pattern = ~r/^#{Regex.escape(target)}:\s*\n((?:\t.*\n?)*)/m
    [_, body] = Regex.run(pattern, makefile)
    body
  end

  defp live_case_count(source) do
    if source =~ "@moduletag :live" do
      length(Regex.scan(~r/^\s*test\s+"/m, source))
    else
      length(Regex.scan(~r/@tag :live\s+@tag[^\n]*\s+test\s+"/m, source))
    end
  end
end
