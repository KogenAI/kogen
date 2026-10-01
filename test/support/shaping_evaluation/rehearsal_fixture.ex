Code.require_file("../shaping_audit/fixture.ex", __DIR__)

defmodule Kogen.ShapingEvaluation.RehearsalFixture do
  @moduledoc """
  The offline engine fixture for the Python driver rehearsals.

  It builds a compiled Shaping-audit fixture repository (a git checkout that
  loads this test build's BEAM files, so `mix kogen.shape` runs the real
  engine, the real Stop hook and the real deterministic audit) and writes one
  JSON handoff file describing how the Python rehearsal drives it:

    * `fixture`: the fixture root (a template the rehearsal copies per test),
    * `mix_command`: the argv prefix that runs `mix` against the compiled code,
    * `eval_command`: the bare `elixir -pa ...` prefix that evaluates route lookups,
    * `env`: the offline fakes (`fake_shaping_controller` as the harness, the
      fake Jev transport and a no-op notifier),
    * `templates`: package directories the fake controller copies as its Draft,
      `complete` (audits clean) and `flawed` (a blocking deterministic finding).

  Only the provider, the Auditor and the Jev transport are fake.
  """

  alias Kogen.Build.VerificationPlan
  alias Kogen.ShapingAudit.{Deterministic, Fixture, Materialization, Package, Questions}

  @project_root Path.expand("../../..", __DIR__)
  @handoff_env "KOGEN_REHEARSAL_ENGINE"

  @doc "The environment variable naming the handoff file."
  def handoff_env, do: @handoff_env

  @doc "Creates the fixture and returns the environment for the Python rehearsal."
  def create! do
    root =
      Fixture.repo!(
        compiled: true,
        second_commit: false,
        working_tree: false,
        prior_failures: false
      )

    # Fixture.repo!/1 writes a placeholder environment consumer. The real
    # Stop hook execs this file when KOGEN_ENV_RESTORE_PENDING is set, so the
    # rehearsal must carry the production restore consumer and preserve that
    # marker/dispatch path.
    File.cp!(
      Path.join(@project_root, ".codex/hooks/environment.py"),
      Path.join(root, ".codex/hooks/environment.py")
    )

    # The offline engine's materialized candidate must contain the actual
    # focused audit prerequisites named by the repaired proof selectors.
    for selector <- ["test/kogen/shape_task_test.exs"] do
      File.mkdir_p!(Path.dirname(Path.join(root, selector)))
      File.cp!(Path.join(@project_root, selector), Path.join(root, selector))
    end

    greeting_fixture =
      Path.join(@project_root, "test/support/shaping_evaluation/cases/headless-flow")

    for {source, destination} <- [
          {"greeting-writer.exs.txt", "app/greeting_writer.ex"},
          {"greeting-proof.exs.txt", "test/fixture_greeting_contract_test.exs"},
          {"evidence/greeting.md", "evidence/greeting.md"},
          {"evidence/facts.json", "evidence/facts.json"},
          {"evidence/fixture-contract.md", "evidence/fixture-contract.md"}
        ] do
      target = Path.join(root, destination)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(greeting_fixture, source), target)
    end

    File.cp!(
      Path.join(greeting_fixture, "brief.md"),
      Path.join(root, "evidence/brief.md")
    )

    File.mkdir_p!(Path.join(root, "evidence"))

    File.write!(Path.join(root, "evidence/greeting.md"), """
    Product scope: app/greeting_writer.ex writes the future greeting.txt artifact as Hello followed
    by the Shaper's chosen punctuation and a newline. test/fixture_greeting_contract_test.exs calls
    the producer and checks the actual file bytes. The wrong-punctuation control changes the producer
    result and requires that same test to fail.
    """)

    File.write!(Path.join(root, ".kogen/config.yaml"), config_yaml())
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", "Rehearsal configuration"])
    fixture_audit = audit_expected_fixtures!(root)
    # Templates carry the final HEAD, so they are written after the last commit
    # (under the ignored runtime tree, they never dirty the checkout).
    templates = write_templates!(root)
    notifier = write_notifier!(root)

    handoff = %{
      "fixture" => root,
      "eval_command" => elixir_prefix(),
      "mix_command" => elixir_prefix() ++ ["-S", "mix"],
      "env" => %{
        "KOGEN_HARNESS" => Path.join(root, "test/support/fake_shaping_controller"),
        "ERL_LIBS" => erl_libs(),
        "MIX_BUILD_PATH" => Path.join(root, "_build"),
        "KOGEN_TEST_ROOT" => @project_root,
        "KOGEN_SHAPING_NOTIFIER" => notifier,
        "KOGEN_JEV_TRANSPORT" =>
          Path.join(@project_root, "test/support/shaping_audit/fake_jev_audit"),
        "KOGEN_JEV_SECURITY" =>
          Path.join(@project_root, "test/support/shaping_audit/fake_security_audit"),
        "FAKE_JEV_LOG_DIR" => Path.join(root, ".kogen/runtime/fake-jev-audit"),
        # A private shared Claude Code scope, so the claude route's readiness
        # never depends on the machine's real login.
        "KOGEN_CLAUDE_ROOT" => claude_root!(root),
        # The blind Auditor launch reaches the audit fixture's fake auditor.
        "FAKE_AUDITOR_LOG_DIR" => Path.join(root, ".kogen/runtime/fake-auditor"),
        "FAKE_AUDITOR_MESSAGE" => "empty",
        "FAKE_SECURITY_LOG" => Path.join(root, ".kogen/runtime/fake-security.log")
      },
      "templates" => templates,
      "fixture_audit" => fixture_audit
    }

    path = Path.join(Path.dirname(root), Path.basename(root) <> "-rehearsal-engine.json")
    File.write!(path, Jason.encode!(handoff))
    {root, path}
  end

  # Exercise the same deterministic and proof-plan consumers against the
  # expected repaired smoke and Shape-to-Build Drafts before any fake engine
  # session is allowed to claim readiness. Negative controls restore each
  # reported defect and must be rejected by VerificationPlan itself.
  defp audit_expected_fixtures!(root) do
    smoke_selector = "test/fixture_greeting_contract_test.exs"
    shape_selector = "test/kogen/shape_task_test.exs"

    smoke_affected = [
      "app/greeting_writer.ex",
      "greeting.txt",
      smoke_selector
    ]

    smoke_paths =
      smoke_affected ++
        [
          "evidence/brief.md",
          "evidence/facts.json",
          "evidence/greeting.md",
          "evidence/fixture-contract.md"
        ]

    smoke = expected_draft!(root, "smoke", smoke_selector, smoke_affected, smoke_paths)
    shape = expected_draft!(root, "shape-to-build", shape_selector, ["dummy.txt"], ["dummy.txt"])

    unsupported =
      proof_errors!(root, "evidence/prerequisite_control.py", ["lib/a.ex"], ["lib/a.ex"])

    unguarded = proof_errors!(root, shape_selector, ["Makefile"], ["dummy.txt"])

    unless Enum.any?(unsupported, &(elem(&1, 0) == "proof-selector-missing")) do
      raise "offline fixture audit did not reject evidence/prerequisite_control.py"
    end

    unless {"unguarded-affected-path", "Makefile"} in unguarded do
      raise "offline fixture audit did not reject unguarded Makefile"
    end

    %{
      "consumer" => "Kogen.ShapingAudit.Deterministic + Kogen.Build.VerificationPlan",
      "smoke" => smoke,
      "shape_to_build" => shape,
      "unsupported_selector_control" =>
        Enum.map(unsupported, fn {kind, detail} -> [kind, detail] end),
      "unguarded_makefile_control" => Enum.map(unguarded, fn {kind, detail} -> [kind, detail] end)
    }
  end

  defp expected_draft!(root, name, selector, affected, guards) do
    package_rel = Fixture.add_draft!(root, "complete")
    package = Path.join(root, package_rel)
    intent_path = Path.join(package, "intent.yaml")

    intent =
      File.read!(intent_path)
      |> String.replace(
        "  - lib/a.ex\n  - test/a_test.exs",
        Enum.map_join(guards, "\n", &"  - #{&1}")
      )

    File.write!(intent_path, intent)

    if name == "smoke" do
      brief =
        Path.join(
          @project_root,
          "test/support/shaping_evaluation/cases/headless-flow/brief.md"
        )
        |> File.read!()
        |> String.trim()

      File.write!(
        Path.join(package, "intent.yaml"),
        String.replace(
          intent,
          "title: Add a fixture feature",
          "title: Shape the greeting artifact"
        )
      )

      File.write!(Path.join(package, "INTENT.md"), """
      # Shape the greeting artifact

      ## Shaper request

      #{brief}

      ## Settled facts

      The product producer is app/greeting_writer.ex and the focused proof is
      test/fixture_greeting_contract_test.exs. The test calls the producer and
      checks greeting.txt for the selected period followed by one newline.
      The outer driver records engine progress separately from this product
      scenario.
      """)

      File.mkdir_p!(Path.join(package, "evidence"))

      for relative <- ["brief.md", "greeting.md", "facts.json", "fixture-contract.md"] do
        File.cp!(
          Path.join(root, "evidence/#{relative}"),
          Path.join(package, "evidence/#{relative}")
        )
      end

      File.write!(Path.join(package, "questions.md"), """
      ## Settled

      The Shaper selected a period. The product request and evidence are copied
      into this package.
      """)
    end

    scenarios_path = Path.join(package, "scenarios.yaml")

    scenarios =
      File.read!(scenarios_path)
      |> String.replace("offline: [test/a_test.exs]", "offline: [#{selector}]")
      |> String.replace(
        "affected_paths: [lib/a.ex]",
        "affected_paths: [#{Enum.join(affected, ", ")}]"
      )

    scenarios =
      case name do
        "smoke" -> smoke_scenario_text(scenarios)
        "shape-to-build" -> shape_to_build_scenario_text(scenarios)
        _ -> scenarios
      end

    File.write!(scenarios_path, scenarios)

    {:ok, loaded} = Package.load(root, package_rel)
    {:ok, materialization} = Materialization.create(root, package_rel, loaded.files)

    try do
      intent = loaded.files["intent.yaml"] |> YamlElixir.read_from_string!()
      {:ok, scenarios} = loaded.files["scenarios.yaml"] |> YamlElixir.read_from_string()

      ctx = %{
        root: root,
        slug: name,
        package_rel: package_rel,
        files: loaded.files,
        materialization: materialization.dir,
        intent: intent,
        scenarios: scenarios,
        questions: Questions.parse(loaded.files["questions.md"]),
        opts: []
      }

      deterministic = Deterministic.run(ctx)
      {:ok, catalog} = VerificationPlan.load(materialization.dir)
      errors = VerificationPlan.proof_errors(scenarios, guards, catalog, materialization.dir)
      blocking = Enum.filter(deterministic["findings"], &(&1["severity"] == "blocking"))

      smoke_contract =
        if name == "smoke" do
          contract_errors = smoke_contract_errors(materialization.dir, package, intent, scenarios)

          unless contract_errors == [] do
            raise "smoke fixture contract is inconsistent: #{inspect(contract_errors)}"
          end

          %{
            "errors" => contract_errors,
            "negative_controls" =>
              smoke_contract_negative_controls!(materialization.dir, package, intent, scenarios)
          }
        end

      unless errors == [] and blocking == [] do
        raise "#{name} expected Draft is not audit-ready: proof_errors=#{inspect(errors)} blocking=#{inspect(blocking)}"
      end

      %{
        "readiness" => deterministic["status"],
        "proof_errors" => errors,
        "blocking_findings" => blocking,
        "selector" => selector,
        "affected_paths" => affected,
        "contract" => smoke_contract
      }
    after
      Materialization.remove(materialization)
      File.rm_rf!(package)
    end
  end

  defp smoke_contract_errors(root, package, intent, scenarios) do
    producer_path = "app/greeting_writer.ex"
    test_path = "test/fixture_greeting_contract_test.exs"
    expected_affected = [producer_path, "greeting.txt", test_path]

    expected_evidence = [
      "evidence/brief.md",
      "evidence/facts.json",
      "evidence/greeting.md",
      "evidence/fixture-contract.md"
    ]

    read = fn path ->
      case File.read(path) do
        {:ok, value} -> value
        {:error, _reason} -> ""
      end
    end

    producer = read.(Path.join(root, producer_path))
    test_source = read.(Path.join(root, test_path))
    intent_md = read.(Path.join(package, "INTENT.md"))
    brief = read.(Path.join(package, "evidence/brief.md")) |> String.trim()
    greeting = read.(Path.join(package, "evidence/greeting.md"))
    fixture_contract = read.(Path.join(package, "evidence/fixture-contract.md"))

    facts =
      case Jason.decode(read.(Path.join(package, "evidence/facts.json"))) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    scenario = List.first(scenarios) || %{}
    proof = scenario["proof"] || %{}
    scenario_evidence = scenario["evidence"] || ""
    guarded = intent["may_change_guarded_paths"] || []
    affected = proof["affected_paths"] || []
    selector = proof["offline"] || []

    checks = %{
      "producer-present" => File.regular?(Path.join(root, producer_path)),
      "producer-writes-selected-punctuation" =>
        String.contains?(producer, "def write!(path, punctuation)") and
          String.contains?(producer, "File.write!(path, [\"Hello\", punctuation, \"\\n\"])"),
      "proof-calls-producer-and-reads-artifact" =>
        String.contains?(test_source, "Kogen.GreetingWriter.write!(greeting_path, \".\")") and
          String.contains?(test_source, "File.read!(greeting_path) == \"Hello.\\n\""),
      "intent-carries-original-brief-and-product-facts" =>
        brief != "" and String.contains?(intent_md, brief) and
          String.contains?(intent_md, producer_path) and String.contains?(intent_md, test_path) and
          String.contains?(intent_md, "greeting.txt") and
          not Regex.match?(
            ~r/engine mechanics only|does not implement or grade the future artifact/i,
            intent_md
          ),
      "cited-evidence-is-in-package" =>
        Enum.all?(expected_evidence, &File.regular?(Path.join(package, &1))) and
          String.contains?(greeting, producer_path) and String.contains?(greeting, test_path) and
          String.contains?(fixture_contract, producer_path) and
          String.contains?(fixture_contract, test_path),
      "facts-bind-producer-test-and-exact-output" =>
        facts["scope"] == "product greeting artifact" and
          facts["producer"] == "app/greeting_writer.ex (Kogen.GreetingWriter.write!/2)" and
          facts["proof_selector"] == test_path and facts["artifact"] == "greeting.txt" and
          facts["selected_punctuation"] == "period" and facts["expected_output"] == "Hello.\n" and
          is_binary(facts["engine_observation"]) and facts["engine_observation"] =~ "separately",
      "scenario-selects-focused-proof-and-cites-facts" =>
        selector == [test_path] and
          Enum.all?(expected_evidence, &String.contains?(scenario_evidence, &1)) and
          String.contains?(scenario_evidence, producer_path) and
          String.contains?(scenario_evidence, test_path) and
          String.contains?(scenario["then"] || "", "Hello.") and
          String.contains?(scenario["then"] || "", "newline") and
          not Regex.match?(
            ~r/engine mechanics only|does not implement or grade the future artifact/i,
            scenario_evidence
          ),
      "producer-test-output-are-guarded-and-affected" =>
        Enum.all?(expected_affected, &(&1 in affected and &1 in guarded))
    }

    checks
    |> Enum.reject(fn {_name, passed} -> passed end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp smoke_contract_negative_controls!(root, package, intent, scenarios) do
    producer = Path.join(root, "app/greeting_writer.ex")
    test_source = Path.join(root, "test/fixture_greeting_contract_test.exs")
    facts = Path.join(package, "evidence/facts.json")
    intent_md = Path.join(package, "INTENT.md")

    cases = [
      {"absent-producer", producer, fn path -> File.rm!(path) end, "producer-present"},
      {"literal-only-test", test_source,
       fn path ->
         File.write!(path, """
         defmodule Kogen.FixtureGreetingContractTest do
           use ExUnit.Case
           test \"a self-defined literal\" do
             assert \"Hello.\\n\" == \"Hello.\\n\"
           end
         end
         """)
       end, "proof-calls-producer-and-reads-artifact"},
      {"missing-cited-facts", facts, fn path -> File.rm!(path) end,
       "facts-bind-producer-test-and-exact-output"},
      {"contradictory-scope", intent_md,
       fn path -> File.write!(path, "# Greeting\n\nScope: engine mechanics only.\n") end,
       "intent-carries-original-brief-and-product-facts"}
    ]

    results =
      Enum.map(cases, fn {name, path, corrupt, expected_error} ->
        original = File.read!(path)

        errors =
          try do
            corrupt.(path)
            smoke_contract_errors(root, package, intent, scenarios)
          after
            File.write!(path, original)
          end

        unless expected_error in errors do
          raise "smoke fixture negative control #{name} did not expose #{expected_error}: #{inspect(errors)}"
        end

        %{"name" => name, "rejected" => true, "errors" => errors}
      end)

    unless smoke_contract_errors(root, package, intent, scenarios) == [] do
      raise "smoke fixture negative controls did not restore the valid fixture"
    end

    results
  end

  defp smoke_scenario_text(text) do
    text
    |> String.replace(
      "given: A fixture module with one helper function.",
      "given: The maintained fixture producer app/greeting_writer.ex writes greeting.txt using the Shaper-approved period decision."
    )
    |> String.replace(
      "when: The helper is called.",
      "when: Kogen.GreetingWriter.write!/2 creates greeting.txt and the focused proof reads that file."
    )
    |> String.replace(
      "then: It returns the expected value.",
      "then: It contains Hello. followed by one newline."
    )
    |> String.replace(
      "wrong_result: The helper returns the wrong value or raises.",
      "wrong_result: greeting.txt is missing or contains another greeting or punctuation."
    )
    |> String.replace(
      "evidence: test/a_test.exs asserts the helper's return value directly.",
      "evidence: evidence/brief.md preserves the original request; evidence/facts.json binds app/greeting_writer.ex, test/fixture_greeting_contract_test.exs, greeting.txt, the selected period and exact bytes; evidence/greeting.md describes the product contract and wrong-punctuation control; evidence/fixture-contract.md documents its producer, proof and affected paths. app/greeting_writer.ex names Kogen.GreetingWriter.write!/2; test/fixture_greeting_contract_test.exs calls it and checks greeting.txt for Hello. followed by one newline. The separate wrong-punctuation control requires that same test to fail. The outer driver observes engine progress separately."
    )
  end

  defp shape_to_build_scenario_text(text) do
    text
    |> String.replace(
      "given: A fixture module with one helper function.",
      "given: The fixture owns dummy.txt initially, while its Check requires an undisclosed exact value."
    )
    |> String.replace(
      "when: The helper is called.",
      "when: The first controller Check reports the required value to the Developer, who repairs dummy.txt and runs Check again."
    )
    |> String.replace(
      "then: It returns the expected value.",
      "then: dummy.txt contains the required value and the controller's final Check receipt passes for the same shaped-and-approved Intent."
    )
    |> String.replace(
      "wrong_result: The helper returns the wrong value or raises.",
      "wrong_result: The requested file state is missing, its exact value is wrong, or the dummy.txt-only Developer cannot repair it from Check output."
    )
    |> String.replace(
      "evidence: test/a_test.exs asserts the helper's return value directly.",
      "evidence: test/kogen/shape_task_test.exs is the supported headless engine selector; the outer test driver separately observes controller discovery and Check history."
    )
  end

  defp proof_errors!(root, selector, affected, guards) do
    package_rel = Fixture.add_draft!(root, "complete")
    package = Path.join(root, package_rel)
    scenarios_path = Path.join(package, "scenarios.yaml")

    scenarios =
      File.read!(scenarios_path)
      |> String.replace("offline: [test/a_test.exs]", "offline: [#{selector}]")
      |> String.replace(
        "affected_paths: [lib/a.ex]",
        "affected_paths: [#{Enum.join(affected, ", ")}]"
      )

    File.write!(scenarios_path, scenarios)
    {:ok, loaded} = Package.load(root, package_rel)
    {:ok, materialization} = Materialization.create(root, package_rel, loaded.files)

    try do
      {:ok, scenarios} = loaded.files["scenarios.yaml"] |> YamlElixir.read_from_string()
      {:ok, catalog} = VerificationPlan.load(materialization.dir)
      VerificationPlan.proof_errors(scenarios, guards, catalog, materialization.dir)
    after
      Materialization.remove(materialization)
      File.rm_rf!(package)
    end
  end

  @doc "Removes the fixture and its handoff file."
  def cleanup!({root, handoff}) do
    File.rm_rf!(root)
    File.rm(handoff)
  end

  defp write_templates!(root) do
    directory = Path.join(root, ".kogen/runtime/rehearsal-templates")
    File.mkdir_p!(directory)

    complete = Path.join(directory, "complete")
    package = Fixture.add_draft!(root, "complete")
    File.rename!(Path.join(root, package), complete)
    complete_scenarios = Path.join(complete, "scenarios.yaml")

    File.write!(
      complete_scenarios,
      File.read!(complete_scenarios)
      |> String.replace(
        "offline: [test/a_test.exs]",
        "offline: [test/fixture_greeting_contract_test.exs]"
      )
    )

    flawed = Path.join(directory, "flawed")
    File.cp_r!(complete, flawed)

    flawed_scenarios = Path.join(flawed, "scenarios.yaml")

    File.write!(
      flawed_scenarios,
      File.read!(flawed_scenarios)
      |> String.replace(
        "offline: [test/fixture_greeting_contract_test.exs]",
        "offline: [test/greeting_test.exs]"
      )
    )

    %{"complete" => complete, "flawed" => flawed}
  end

  defp write_notifier!(root) do
    path = Path.join(root, ".kogen/runtime/rehearsal-notifier")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp config_yaml do
    """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping: {model: gpt-5.6-sol, effort: low}
        developer: {model: gpt-5.6-sol, effort: low}
        reviewer: {model: gpt-5.6-terra, effort: medium}
        auditor: {model: gpt-6.1-sol, effort: high}
        helpers:
          scout: {model: gpt-5.6-luna, effort: low}
          worker: {model: gpt-5.6-luna, effort: medium}
          expert: {model: gpt-5.6-sol, effort: medium}
      claude:
        harness: claude
        shaping: {model: claude-sonnet-5, effort: low}
        developer: {model: claude-sonnet-5, effort: low}
        reviewer: {model: claude-sonnet-5, effort: medium}
        auditor: {model: claude-sonnet-5, effort: high}
        helpers:
          scout: {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
          expert: {model: claude-sonnet-5, effort: medium}
    outer_resumptions: 2
    verification_retries: 2
    offline_retries: 4
    """
  end

  defp claude_root!(root) do
    claude = Path.join(root, ".kogen/runtime/claude-root")
    File.mkdir_p!(Path.join(claude, "accounts/shared"))
    claude
  end

  defp git!(root, args) do
    {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end

  # The detached runner is launched with a plain `mix` in the fixture, so it
  # needs this build's compiled dependency directories.
  defp erl_libs do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&(Path.basename(&1) == "ebin" and String.contains?(&1, "_build")))
    |> Enum.map(&(&1 |> Path.dirname() |> Path.dirname()))
    |> Enum.uniq()
    |> Enum.join(":")
  end

  defp elixir_prefix do
    ["elixir", "--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++
      Enum.flat_map(compiled_ebins(), &["-pa", &1])
  end

  defp compiled_ebins do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(
      &(Path.type(&1) == :absolute and Path.basename(&1) == "ebin" and File.dir?(&1))
    )
    |> Enum.sort()
  end
end
