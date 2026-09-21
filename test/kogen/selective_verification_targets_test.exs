defmodule Kogen.SelectiveVerificationTargetsTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Contract
  alias Kogen.Build.VerificationPlan
  alias Kogen.Check

  @root Path.expand("../..", __DIR__)
  @owners %{
    "live-shape-to-build" => %{"test/kogen/live_shape_to_build_test.exs" => 1},
    "live-reviewer-rework" => %{"test/kogen/live_reviewer_rework_test.exs" => 1},
    "live-general" => %{"test/kogen/live_test.exs" => 1},
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
    refute MapSet.member?(declared, "live")
    assert :ok = Check.validate_targets(Map.keys(@owners), makefile_path)
    refute makefile =~ ~r/^live:\s*$/m

    selected =
      for {target, owners} <- @owners,
          {path, expected_cases} <- owners do
        source = File.read!(Path.join(@root, path))
        assert source =~ ~r/@(?:module)?tag :live/
        assert live_case_count(source) == expected_cases
        assert recipe(makefile, target) =~ path
        {path, target}
      end

    assert length(selected) == 8

    assert selected |> Enum.map(&elem(&1, 0)) |> Enum.frequencies() |> Map.values() ==
             List.duplicate(1, 8)

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

    for target <- [
          "live-shape-to-build",
          "live-reviewer-rework",
          "live-general",
          "live-shaping-quality",
          "live-native"
        ] do
      refute recipe(makefile, target) =~ "cold_offline_test.exs"
    end

    refute recipe(makefile, "live-shape-to-build") =~ "live_test.exs"
    refute recipe(makefile, "live-general") =~ "live_shape_to_build_test.exs"
    refute recipe(makefile, "live-native") =~ "live_shape_to_build_test.exs"
  end

  test "tracked catalog is exhaustive, ordered, and has executable rehearsals" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    assert catalog.ordered_targets == [
             "check",
             "cold-offline",
             "live-general",
             "live-shaping-quality",
             "live-native",
             "live-reviewer-rework",
             "live-shape-to-build"
           ]

    declared =
      Check.declared_targets(Path.join(@root, "Makefile"))
      |> MapSet.delete(".PHONY")

    assert MapSet.equal?(declared, MapSet.new(catalog.ordered_targets))

    for entry <- catalog.entries do
      assert entry["owner"]

      if entry["provider_backed"] do
        rehearsal = entry["rehearsal"]
        assert rehearsal["id"]
        assert rehearsal["command"] =~ "mix test"
        assert rehearsal["shared_entrypoints"] != []
        assert rehearsal["trace_assertions"] != []
      end
    end
  end

  test "catalog admission rejects a declared Make target without metadata" do
    root =
      Path.join(System.tmp_dir!(), "kogen-target-catalog-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "priv/kogen"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(
      Path.join(@root, "priv/kogen/verification_targets.yaml"),
      Path.join(root, "priv/kogen/verification_targets.yaml")
    )

    makefile = File.read!(Path.join(@root, "Makefile")) <> "\nmissing-metadata:\n\t@true\n"
    File.write!(Path.join(root, "Makefile"), makefile)

    assert {:error, reason} = VerificationPlan.load(root)
    assert reason =~ "does not match declared Make targets"
  end

  test "proof admission accepts the cataloged cold-offline boundary" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    scenario = %{
      "verified_by" => ["check", "cold-offline"],
      "proof" => %{
        "offline" => ["test/kogen/selective_verification_targets_test.exs"],
        "paid_target" => "cold-offline",
        "paid_reason" =>
          "provider-required: cold-offline; observation: isolated empty-cache execution; offline-limit: focused warm-cache tests cannot establish cold dependency setup",
        "affected_paths" => ["test/kogen/selective_verification_targets_test.exs"]
      }
    }

    assert {:ok, plan} =
             VerificationPlan.build([scenario], ["test/kogen/**"], catalog, @root)

    assert plan.targets == ["check", "cold-offline"]
    assert plan.rehearsals == []
  end

  test "proof admission rejects arbitrary existing repository files and source globs" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    for selector <- ["Makefile", "lib/kogen/check.ex", "lib/**"] do
      scenario = %{
        "verified_by" => ["check"],
        "proof" => %{
          "offline" => [selector],
          "paid_target" => "none",
          "paid_reason" =>
            "offline-sufficient: arbitrary repository files are not executable proof",
          "affected_paths" => [selector]
        }
      }

      assert {:error, "scenario proof map is missing, unsafe, or inconsistent"} =
               VerificationPlan.build([scenario], ["Makefile", "lib/**"], catalog, @root)
    end
  end

  test "rehearsal evidence consumer accepts exact authority and rejects a one-field foreign target" do
    assert {:ok, catalog} = VerificationPlan.load(@root)
    target = Enum.find(catalog.entries, &(&1["name"] == "live-general"))
    rehearsal = target["rehearsal"]
    observed = rehearsal["shared_entrypoints"] ++ rehearsal["trace_assertions"]

    trace_sha256 =
      observed
      |> MapSet.new()
      |> Enum.sort()
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    evidence = %{
      "schema_version" => 1,
      "target" => target["name"],
      "rehearsal_id" => rehearsal["id"],
      "command" => rehearsal["command"],
      "status" => 0,
      "observed" => observed,
      "trace_sha256" => trace_sha256
    }

    assert :ok = Contract.rehearsal_evidence(target, rehearsal, evidence)

    assert {:error, reason} =
             Contract.rehearsal_evidence(
               target,
               rehearsal,
               Map.put(evidence, "target", "live-native")
             )

    assert reason =~ "foreign authority"

    assert {:error, reason} =
             Contract.rehearsal_evidence(
               target,
               rehearsal,
               Map.put(evidence, "trace_sha256", String.duplicate("a", 64))
             )

    assert reason =~ "incomplete trace"
  end

  test "selection guide chooses targets by behavior and explains paid evidence" do
    guide = File.read!(Path.join(@root, "README.md"))

    cases = [
      {"Offline sufficiency", "check only"},
      {"configured-default lifecycle", "`live-shape-to-build`"},
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
