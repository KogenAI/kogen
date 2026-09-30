defmodule Kogen.SelectiveVerificationTargetsTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Contract
  alias Kogen.Build.VerificationPlan
  alias Kogen.Check
  alias Kogen.Intent

  @root Path.expand("../..", __DIR__)
  @owners %{
    "live-shape-to-build" => %{"test/kogen/live_shape_to_build_test.exs" => 1},
    "live-reviewer-rework" => %{"test/kogen/live_reviewer_rework_test.exs" => 1},
    "live-general" => %{"test/kogen/live_test.exs" => 1},
    "live-shaping-quality" => %{"test/kogen/live_shaping_evaluation_test.exs" => 1},
    "live-shaping-smoke" => %{"test/kogen/live_shaping_smoke_test.exs" => 1},
    "live-native" => %{
      "test/kogen/codex_native_live_test.exs" => 2,
      "test/kogen/codex_compatibility_test.exs" => 1,
      "test/kogen/native_helper_live_test.exs" => 2
    },
    "cold-offline" => %{"test/kogen/cold_offline_test.exs" => 1}
  }

  test "stale test names and changed live owners are advisory disclosures" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    scenario = %{
      "id" => "coverage-disclosure",
      "tests" => ["test a nonexistent exact readiness name"]
    }

    disclosures =
      VerificationPlan.review_disclosures(
        [scenario],
        %{targets: ["check"]},
        catalog,
        ["test/kogen/native_helper_live_test.exs"],
        @root
      )

    assert disclosures["test_name_mappings"]["enumeration_error"] == nil

    assert disclosures["test_name_mappings"]["scenarios"] == [
             %{
               "scenario_id" => "coverage-disclosure",
               "declared_names" => ["test a nonexistent exact readiness name"],
               "absent_names" => ["test a nonexistent exact readiness name"]
             }
           ]

    assert disclosures["changed_provider_coverage_gaps"] == [
             %{
               "target" => "live-native",
               "paths" => ["test/kogen/native_helper_live_test.exs"]
             }
           ]

    assert disclosures["disposition"] =~ "advisory only"
  end

  test "unavailable changed-path evidence is disclosed without blocking plan review" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    disclosures =
      VerificationPlan.review_disclosures(
        [],
        %{targets: ["check"]},
        catalog,
        {:error, "git status unavailable"},
        @root
      )

    assert disclosures["changed_paths_error"] == "git status unavailable"
    assert disclosures["changed_provider_coverage_gaps"] == []
  end

  test "multiple paid targets and duplicate or unsorted mappings canonicalize to the plan" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    scenario = %{
      "id" => "multiple-provider-targets",
      "verified_by" => ["live-native", "check", "live-general", "check"],
      "proof" => %{
        "offline" => ["test/kogen/selective_verification_targets_test.exs"],
        "paid_target" => "live-native",
        "paid_reason" =>
          "provider-required: live-native; observation: local checks cannot establish provider compatibility; offline-limit: the affected integration must run against the provider",
        "affected_paths" => ["test/kogen/selective_verification_targets_test.exs"]
      }
    }

    assert [] = VerificationPlan.verified_by_errors(scenario, catalog.targets)

    assert {:ok, plan} =
             VerificationPlan.build(
               [scenario],
               ["test/kogen/**"],
               catalog,
               @root
             )

    assert plan.targets == ["check", "live-general", "live-native"]

    scenario = put_in(scenario, ["proof", "offline"], ["test/kogen/missing_required_test.exs"])

    assert Enum.any?(
             VerificationPlan.proof_errors([scenario], ["test/kogen/**"], catalog, @root),
             fn
               {"proof-selector-missing", "test/kogen/missing_required_test.exs"} -> true
               _ -> false
             end
           )
  end

  test "changed paths report any provider owners missing from the selected targets" do
    assert {:ok, catalog} = VerificationPlan.load(@root)
    changed = ["test/kogen/native_helper_live_test.exs", "test/support/unpredicted_fixture.ex"]

    assert VerificationPlan.missing_changed_coverage(%{targets: ["check"]}, catalog, changed) ==
             ["live-native"]

    assert VerificationPlan.missing_changed_coverage(
             %{targets: ["check", "live-native"]},
             catalog,
             changed
           ) == []

    assert VerificationPlan.missing_changed_coverage(
             %{targets: ["check"]},
             catalog,
             ["test/support/unpredicted_fixture.ex"]
           ) == []
  end

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

    assert length(selected) == 9

    assert selected |> Enum.map(&elem(&1, 0)) |> Enum.frequencies() |> Map.values() ==
             List.duplicate(1, 9)

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
             "live-shaping-smoke",
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

  test "selected Build provider targets bind coverage and route-derived login roles" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    assert {:ok, route} =
             Intent.read_config(
               Path.join(@root, ".kogen/config.yaml"),
               "codex-dominant-adversarial-claude"
             )

    selected =
      catalog.entries
      |> Enum.filter(& &1["provider_backed"])
      |> Enum.map(& &1["name"])

    for target <- selected do
      entry = catalog.targets[target]
      assert entry["requires_login"] == "route"
      assert entry["covers"] != []
      assert entry["launched_roles"] != []
    end

    plan = %{login_roles: [:shaping, :developer, :reviewer]}
    assert VerificationPlan.required_logins(plan, route) == ["codex", "claude"]

    native = catalog.targets["live-native"]
    assert native["covers"] |> Enum.member?("test/kogen/codex_native_live_test.exs")
    refute native["covers"] |> Enum.member?("test/kogen/live_shaping_evaluation_test.exs")
  end

  test "a strict-coverage plan rejects a selected provider target whose coverage misses changed paths" do
    assert {:ok, catalog} = VerificationPlan.load(@root)

    {slug, approved_root, package} = coverage_fixture!()
    assert {:ok, intent} = Intent.read(slug, approved_root)

    assert {:ok, contract} = Contract.load(package, @root)

    assert {:ok, plan} =
             VerificationPlan.build(
               contract.scenarios,
               intent.may_change_guarded_paths,
               catalog,
               @root,
               strict_coverage: true
             )

    assert plan.targets == ["check", "live-native"]

    entries =
      Enum.map(catalog.entries, fn entry ->
        if entry["name"] == "live-native",
          do: Map.put(entry, "covers", ["test/kogen/unrelated_test.exs"]),
          else: entry
      end)

    altered = %{catalog | entries: entries, targets: Map.new(entries, &{&1["name"], &1})}

    assert {:error, "selected provider target live-native covers no affected path"} =
             VerificationPlan.build(
               contract.scenarios,
               intent.may_change_guarded_paths,
               altered,
               @root,
               strict_coverage: true
             )

    # Legacy packages stay readable: without the explicit request the
    # declared-path check is not applied.
    assert {:ok, _plan} =
             VerificationPlan.build(
               contract.scenarios,
               intent.may_change_guarded_paths,
               altered,
               @root
             )
  end

  defp coverage_fixture! do
    slug = "selective-coverage-fixture"

    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-selective-coverage-#{System.unique_integer([:positive])}"
      )

    approved_root = Path.join(root, "approved")
    package = Path.join(approved_root, slug)
    File.mkdir_p!(package)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(
      Path.join(package, "intent.yaml"),
      Jason.encode!(%{
        "id" => "01960000-0000-7000-8000-000000000102",
        "slug" => slug,
        "title" => "Selective coverage fixture",
        "may_change_guarded_paths" => ["test/kogen/**"]
      })
    )

    File.write!(
      Path.join(package, "scenarios.yaml"),
      Jason.encode!([
        %{
          "id" => "native-coverage",
          "given" => "a change touches the native live test boundary",
          "when" => "the verification plan is built",
          "then" => "the selected live-native target covers that path",
          "wrong_result" => "a selected provider target covers no affected path",
          "verified_by" => ["check", "live-native"],
          "evidence" => "the focused catalog coverage check",
          "proof" => %{
            "offline" => ["test/kogen/selective_verification_targets_test.exs"],
            "paid_target" => "live-native",
            "paid_reason" =>
              "provider-required: live-native; observation: the native live test boundary is selected; offline-limit: offline planning cannot establish managed native runtime behavior",
            "affected_paths" => ["test/kogen/codex_native_live_test.exs"]
          }
        }
      ])
    )

    {slug, approved_root, package}
  end

  test "a helper Make target with no catalog metadata is allowed to load" do
    root = target_catalog_fixture!()

    makefile = File.read!(Path.join(@root, "Makefile")) <> "\nfmt:\n\t@true\n"
    File.write!(Path.join(root, "Makefile"), makefile)

    assert {:ok, _catalog} = VerificationPlan.load(root)
  end

  test "an unrelated pattern rule with no catalog name overlap is allowed to load" do
    root = target_catalog_fixture!()

    makefile = File.read!(Path.join(@root, "Makefile")) <> "\n%.txt:\n\t@true\n"
    File.write!(Path.join(root, "Makefile"), makefile)

    assert {:ok, _catalog} = VerificationPlan.load(root)
  end

  test "a missing catalog target refuses, naming it" do
    root = target_catalog_fixture!()

    makefile =
      File.read!(Path.join(@root, "Makefile"))
      |> String.replace(~r/^cold-offline:\s*\n(?:\t.*\n?)*/m, "")

    File.write!(Path.join(root, "Makefile"), makefile)

    assert {:error, reason} = VerificationPlan.load(root)
    assert reason =~ "cold-offline"
  end

  test "a pattern or double-colon rule that could shadow a catalog target refuses, naming the rule and the target" do
    pattern_root = target_catalog_fixture!()

    File.write!(
      Path.join(pattern_root, "Makefile"),
      File.read!(Path.join(@root, "Makefile")) <> "\n%: ;\n"
    )

    assert {:error, pattern_reason} = VerificationPlan.load(pattern_root)
    assert pattern_reason =~ "pattern"
    assert pattern_reason =~ "check"

    double_colon_root = target_catalog_fixture!()

    File.write!(
      Path.join(double_colon_root, "Makefile"),
      File.read!(Path.join(@root, "Makefile")) <> "\ncheck::\n\t@true\n"
    )

    assert {:error, double_colon_reason} = VerificationPlan.load(double_colon_root)
    assert double_colon_reason =~ "double-colon"
    assert double_colon_reason =~ "check"
  end

  describe "an optional prepare argv on a catalog entry" do
    test "a valid argv loads and is preserved on the entry" do
      root =
        one_target_catalog_fixture!(
          no_check_entry("test", 0, [])
          |> Map.put("prepare", ["python3", "-B", "prepare.py"])
        )

      assert {:ok, catalog} = VerificationPlan.load(root)
      assert catalog.targets["test"]["prepare"] == ["python3", "-B", "prepare.py"]
    end

    test "an entry without prepare loads" do
      root = one_target_catalog_fixture!(no_check_entry("test", 0, []))

      assert {:ok, catalog} = VerificationPlan.load(root)
      refute Map.has_key?(catalog.targets["test"], "prepare")
    end

    for {label, bad_prepare} <- [
          {"a string instead of an argv", "make x"},
          {"an empty list", []},
          {"a list with a blank string", [""]},
          {"a list with a non-string element", [1]}
        ] do
      test "prepare as #{label} is refused, naming the target and prepare" do
        root =
          one_target_catalog_fixture!(
            no_check_entry("test", 0, [])
            |> Map.put("prepare", unquote(Macro.escape(bad_prepare)))
          )

        assert {:error, reason} = VerificationPlan.load(root)
        assert reason =~ "test"
        assert reason =~ "prepare"
      end
    end
  end

  defp one_target_catalog_fixture!(entry) do
    root =
      Path.join(System.tmp_dir!(), "kogen-prepare-catalog-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "priv/kogen"))

    File.write!(Path.join(root, "Makefile"), """
    .PHONY: test
    test:
    \t@true
    """)

    File.write!(
      Path.join(root, "priv/kogen/verification_targets.yaml"),
      Jason.encode!(%{"targets" => [entry]})
    )

    on_exit(fn -> File.rm_rf(root) end)
    root
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

  # -- a catalog with no `check` at all ------------------------------------

  describe "VerificationPlan.build/5 against a catalog with an offline test target and no check" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "kogen-no-check-catalog-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(root, "priv/kogen"))

      File.write!(Path.join(root, "Makefile"), """
      .PHONY: test helper paid extra
      test:
      \t@true
      helper:
      \t@true
      paid:
      \t@true
      extra:
      \t@true
      """)

      File.write!(
        Path.join(root, "priv/kogen/verification_targets.yaml"),
        Jason.encode!(%{
          "targets" => [
            no_check_entry("test", 0, []),
            no_check_entry("helper", 10, ["test"]),
            paid_entry("paid", 15, ["test"]),
            no_check_entry("extra", 20, ["helper"])
          ]
        })
      )

      File.write!(Path.join(root, "selector.txt"), "selector\n")
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, catalog} = VerificationPlan.load(root)
      refute Map.has_key?(catalog.targets, "check")
      {:ok, root: root, catalog: catalog}
    end

    test "a verified_by naming only the provider-backed target is rejected for lacking an offline target",
         %{root: root, catalog: catalog} do
      scenario = no_check_scenario(["paid"], "paid")

      assert {:error, "scenario proof map is missing, unsafe, or inconsistent"} =
               VerificationPlan.build([scenario], ["selector.txt"], catalog, root)
    end

    test "a verified_by omitting a listed target's dependency is rejected", %{
      root: root,
      catalog: catalog
    } do
      scenario = no_check_scenario(["test", "extra"], "none")

      assert {:error, "scenario proof map is missing, unsafe, or inconsistent"} =
               VerificationPlan.build([scenario], ["selector.txt"], catalog, root)
    end

    test "a verified_by out of catalog rank order is canonicalized", %{
      root: root,
      catalog: catalog
    } do
      scenario = no_check_scenario(["helper", "test"], "none")

      assert {:ok, plan} = VerificationPlan.build([scenario], ["selector.txt"], catalog, root)
      assert plan.targets == ["test", "helper"]
    end

    test "a single offline target is accepted with no implicit check added", %{
      root: root,
      catalog: catalog
    } do
      scenario = no_check_scenario(["test"], "none")

      assert {:ok, plan} = VerificationPlan.build([scenario], ["selector.txt"], catalog, root)
      assert plan.targets == ["test"]
      refute "check" in plan.targets
    end
  end

  # -- preservation: every proof-bearing Intent package still validates ----

  describe "preservation: every Approved and Complete proof-bearing package still validates" do
    test "Contract.load and VerificationPlan.build accept every package's scenarios against the current catalog" do
      {:ok, catalog} = VerificationPlan.load(@root)

      packages =
        (Path.wildcard(Path.join(@root, ".kogen/intents/approved/*/scenarios.yaml")) ++
           Path.wildcard(Path.join(@root, ".kogen/intents/complete/*/scenarios.yaml")))
        |> Enum.map(&Path.dirname/1)

      failures =
        packages
        |> Enum.map(&package_result(&1, catalog))
        |> Enum.reject(&(elem(&1, 1) in [:ok, :no_proof]))

      assert failures == [],
             "package(s) with a proof declaration no longer validate against the current catalog: " <>
               inspect(failures)
    end

    # A package's own Build is free to land the target its Intent declares
    # in `catalog_changes.add` (this repository's own `build-reliability`
    # lands `live-shaping-smoke`, for example). Once landed, the name is an
    # ordinary existing catalog target, so preservation validates the
    # package as if it had named an existing target, not a pending
    # addition — while `VerificationPlan.validate_added/2`'s live rule (a
    # *fresh* `catalog_changes.add` naming an already-existing target is
    # refused, `test/kogen/catalog_change_test.exs`) stays untouched, since
    # this filtering happens only here, at preservation time, never inside
    # `VerificationPlan.build/5` itself.
    test "an added name already landed in the current catalog validates as an ordinary target" do
      {:ok, catalog} = VerificationPlan.load(@root)
      landed = Enum.find(catalog.ordered_targets, &(&1 == "live-shaping-smoke"))
      assert landed, "fixture assumption: live-shaping-smoke is landed in the tracked catalog"

      contract = fake_contract(["check", landed], landed)

      assert :ok = plan_build_status(contract, ["selector.txt"], catalog, [landed])
    end

    test "an added name absent from the catalog still validates as a pending addition" do
      {:ok, catalog} = VerificationPlan.load(@root)
      pending = "not-yet-landed-target"
      refute Map.has_key?(catalog.targets, pending)

      assert :ok =
               plan_build_status(fake_contract([pending]), ["selector.txt"], catalog, [pending])
    end

    test "a package whose non-added verified_by target is missing still fails" do
      {:ok, catalog} = VerificationPlan.load(@root)
      missing = "no-such-target-in-catalog"
      refute Map.has_key?(catalog.targets, missing)

      assert {:plan_error, _reason} =
               plan_build_status(fake_contract([missing]), ["selector.txt"], catalog, [])
    end
  end

  defp fake_contract(verified_by, paid_target \\ "none") do
    %{
      scenarios: [
        no_check_scenario(verified_by, paid_target)
      ]
    }
  end

  defp package_result(path, catalog) do
    slug = Path.basename(path)
    scenarios = YamlElixir.read_from_file!(Path.join(path, "scenarios.yaml"))

    if Enum.all?(scenarios, &Map.has_key?(&1, "proof")) do
      {slug, plan_status(path, catalog)}
    else
      {slug, :no_proof}
    end
  end

  defp plan_status(path, catalog) do
    intent_data =
      case File.read(Path.join(path, "intent.yaml")) do
        {:ok, text} -> YamlElixir.read_from_string!(text)
        _ -> %{}
      end

    guards = intent_data["may_change_guarded_paths"] || []
    {:ok, %{add: added}} = Intent.catalog_changes(intent_data)

    case Contract.load(path, @root) do
      {:ok, contract} -> plan_build_status(contract, guards, catalog, added)
      {:error, reason} -> {:contract_error, reason}
    end
  end

  defp plan_build_status(contract, guards, catalog, added) do
    # A declared addition already present in the current catalog has
    # landed: validate it as an ordinary existing target here (drop it from
    # `added`), not as a pending addition. Every other name, and every
    # other rule `VerificationPlan.build/5` applies, is unchanged.
    pending = Enum.reject(added, &Map.has_key?(catalog.targets, &1))

    case VerificationPlan.build(contract.scenarios, guards, catalog, @root, added: pending) do
      {:ok, _plan} -> :ok
      {:error, reason} -> {:plan_error, reason}
    end
  end

  defp no_check_entry(name, rank, deps) do
    %{
      "name" => name,
      "cost_class" => "offline",
      "rank" => rank,
      "dependencies" => deps,
      "provider_backed" => false,
      "owner" => "fixture"
    }
  end

  defp paid_entry(name, rank, deps) do
    no_check_entry(name, rank, deps)
    |> Map.put("provider_backed", true)
    |> Map.put("rehearsal", %{
      "id" => "rehearse-#{name}",
      "command" => "true",
      "shared_entrypoints" => ["#{name}.entrypoint"],
      "correct_fixture" => "#{name}-correct",
      "wrong_fixture" => "#{name}-wrong",
      "trace_assertions" => ["#{name}-trace"]
    })
  end

  defp no_check_scenario(verified_by, paid_target) do
    reason =
      if paid_target == "none",
        do: "offline-sufficient: a fixture without check exercises plan rules directly",
        else:
          "provider-required: #{paid_target}; observation: fixture; offline-limit: fixture cannot substitute"

    %{
      "verified_by" => verified_by,
      "proof" => %{
        "offline" => ["selector.txt"],
        "paid_target" => paid_target,
        "paid_reason" => reason,
        "affected_paths" => ["selector.txt"]
      }
    }
  end

  defp target_catalog_fixture! do
    root =
      Path.join(System.tmp_dir!(), "kogen-target-catalog-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "priv/kogen"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(
      Path.join(@root, "priv/kogen/verification_targets.yaml"),
      Path.join(root, "priv/kogen/verification_targets.yaml")
    )

    File.cp!(Path.join(@root, "Makefile"), Path.join(root, "Makefile"))
    root
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
