Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.RefinementTest do
  use ExUnit.Case, async: true, group: :installed_release
  alias Kogen.{Config, Intent, Integration.FakeProvider, Integration.Helpers}
  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "large repository navigation does not become mandatory Refine authority", %{suite: suite} do
    context = approved_fixture!(suite)

    for n <- 1..1600 do
      file = Path.join(context.repo, "bulk/source_#{n}.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "def declaration_#{n}, do: :ok\n")
    end

    Helpers.git!(context, ["add", "bulk"])
    Helpers.git!(context, ["commit", "-qm", "Add navigation fixture"])
    {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)])
    before = package(context)
    feature = Intent.feature("fixture")

    corrected =
      String.replace(
        before[feature],
        "Feature: Integration fixture",
        "Feature: Clarified fixture"
      )

    script!(context, [submission([%{"path" => feature, "content" => corrected}])])

    {output, 0} = refine(context)
    assert output =~ "refined fixture"
    request = List.last(FakeProvider.provider_requests(context.server))
    input = FakeProvider.input_text(request)
    assert input =~ "Context navigation: "
    refute input =~ "Context index: "
    assert byte_size(JSON.encode!(request.json)) < 100_000

    for {path, content} <- before,
        path != ".kogen/project.yaml",
        do: assert(input =~ content)

    assert package(context) == Map.put(before, feature, corrected)

    assert File.read!(Path.join(context.repo, "bulk/source_1600.ex")) ==
             "def declaration_1600, do: :ok\n"
  end

  test "SHP-11 a narrow retry preserves all earlier well-formed proposals until merged readiness",
       %{suite: suite} do
    context = approved_fixture!(suite)
    intent = Intent.intent_md("fixture")
    feature = Intent.feature("fixture")
    step = "features/steps/integration_steps.js"
    model = ".kogen/intents/fixture/model.qnt"

    File.write!(
      Path.join(context.repo, model),
      "module fixture {\n var count: int\n action init = count' = 0\n action step = count' = count + 1\n val Safety = count >= 0\n}\n"
    )

    original_intent =
      File.read!(Path.join(context.repo, intent))
      |> String.replace(
        "Model: not applicable — no model for this fixture",
        "Model: #{model} invariants=Safety seed=7 samples=10 steps=5"
      )

    File.write!(Path.join(context.repo, intent), original_intent)
    {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)])
    before = package(context)
    approval = File.read!(Intent.approval_path(context.repo, "fixture"))
    original_index = index(context)

    pending_intent =
      before[intent]
      |> String.replace("# Preserve", "# Correct")
      |> String.replace("invariants=Safety", "invariants =Safety")
      |> Kernel.<>("\n## Decisions\n- Keep all corrected artifacts.\n")

    corrected_intent =
      pending_intent
      |> String.replace("invariants =Safety", "invariants=Safety")
      |> String.replace(
        "- Keep all corrected artifacts.\n",
        "- Keep all corrected artifacts. (source: request)\n"
      )

    proposals = %{
      intent => pending_intent,
      feature =>
        String.replace(
          before[feature],
          "the acceptance check passes",
          "the corrected acceptance check passes"
        ),
      step =>
        String.replace(
          before[step],
          "the acceptance check passes",
          "the corrected acceptance check passes"
        ),
      model => String.replace(before[model], "count + 1", "count + 2")
    }

    marker = Path.join(context.root, "lint-rejected")

    script!(context, [
      submission(
        Enum.map(proposals, fn {path, content} -> %{"path" => path, "content" => content} end)
      ),
      {:function, "probe", %{"command" => "touch '#{marker}' && sleep 1"}},
      submission([%{"path" => intent, "content" => corrected_intent}])
    ])

    port =
      Helpers.start_kogen(context, [
        "intent",
        "refine",
        "fixture",
        hash(context),
        request!(context)
      ])

    Helpers.wait_for_file!(marker)
    assert package(context) == before
    assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
    assert index(context) == original_index

    assert Enum.any?(
             FakeProvider.tool_outputs(context.server),
             &String.contains?(&1, "decision has no source")
           )

    assert Enum.any?(
             FakeProvider.tool_outputs(context.server),
             &String.contains?(&1, "model: the Model: line must be")
           )

    {output, 0} = Helpers.await_exit(port, "", 60_000)
    assert output =~ "refined fixture"
    assert package(context) == Map.merge(before, Map.put(proposals, intent, corrected_intent))
    assert index(context) == original_index
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))

    [archived] =
      Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/revoked-approval.json"))

    assert File.read!(archived) == approval
    {output, 5} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "intent/not_approved"

    evidence =
      Path.join(context.repo, ".kogen/local/readiness/fixture.json")
      |> File.read!()
      |> JSON.decode!()

    assert evidence["sha256"] == hash(context)
  end

  test "SHP-11 a mixed unsafe payload contributes no proposals to a later narrow retry", %{
    suite: suite
  } do
    context = approved_fixture!(suite)
    before = package(context)
    intent = Intent.intent_md("fixture")
    feature = Intent.feature("fixture")

    updated =
      String.replace(
        before[feature],
        "Feature: Integration fixture",
        "Feature: Corrected fixture"
      )

    script!(context, [
      submission([
        %{
          "path" => intent,
          "content" => String.replace(before[intent], "# Preserve", "# Must never publish")
        },
        %{"path" => "app.txt", "content" => "unsafe"}
      ]),
      submission([%{"path" => feature, "content" => updated}])
    ])

    {output, 0} = refine(context)
    assert output =~ "refined fixture"
    assert package(context) == Map.put(before, feature, updated)
    assert File.read!(Path.join(context.repo, "app.txt")) == "baseline\n"
  end

  test "SHP-11 later proposals replace a path and explicit original bytes revert it", %{
    suite: suite
  } do
    context = approved_fixture!(suite)
    before = package(context)
    intent = Intent.intent_md("fixture")
    feature = Intent.feature("fixture")
    step = "features/steps/integration_steps.js"
    pending = before[intent] <> "\n## Decisions\n- Retain the feature correction.\n"
    latest = String.replace(pending, "# Preserve", "# Latest correction")

    corrected =
      String.replace(
        latest,
        "- Retain the feature correction.\n",
        "- Retain the feature correction. (source: request)\n"
      )

    changed_feature =
      String.replace(
        before[feature],
        "Feature: Integration fixture",
        "Feature: Retained correction"
      )

    script!(context, [
      submission([
        %{"path" => intent, "content" => pending},
        %{"path" => feature, "content" => changed_feature},
        %{"path" => step, "content" => before[step] <> "\n// proposed helper\n"}
      ]),
      submission([
        %{"path" => intent, "content" => latest},
        %{"path" => step, "content" => before[step]}
      ]),
      submission([%{"path" => intent, "content" => corrected}])
    ])

    {output, 0} = refine(context)
    assert output =~ "refined fixture"

    assert package(context) ==
             Map.merge(before, %{intent => corrected, feature => changed_feature})
  end

  test "SHP-11 a delta changes one draft file, preserves other bytes and still needs approval", %{
    suite: suite
  } do
    context = fixture!(suite)
    path = Intent.intent_md("fixture")
    before = package(context)
    updated = String.replace(before[path], "# Preserve the fixture", "# Clarify the fixture")
    script!(context, [submission([%{"path" => path, "content" => updated}])])
    {output, status} = refine(context)
    assert status == 0, output

    [receipt_path] =
      Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/original-readiness.json"))

    receipt = receipt_path |> File.read!() |> JSON.decode!()
    assert receipt["status"] == "hit"
    assert receipt["source"] == "retained"
    assert receipt["setup_executions"] == 0
    assert receipt["acceptance_executions"] == 0
    assert receipt["model_executions"] == 0
    retained = Path.join(Path.dirname(receipt_path), receipt["reference"])
    retained_original = retained |> File.read!() |> JSON.decode!()
    assert retained_original["sha256"] == receipt["baseline"]
    assert retained_original["head"] == receipt["head"]
    refute retained_original["sha256"] == hash(context)
    assert output =~ "refined fixture"
    assert package(context) == Map.put(before, path, updated)
    evidence_path = Path.join(context.repo, ".kogen/local/readiness/fixture.json")
    evidence = evidence_path |> File.read!() |> JSON.decode!()
    assert evidence["outcome"] == "ready"
    assert evidence["sha256"] == hash(context)
    assert evidence["title"] == "Clarify the fixture"
    assert evidence["scenarios"] != []
    assert Enum.all?(evidence["scenarios"], &(&1["status"] in ["passed", "failed"]))
    original_evidence = File.read!(evidence_path)
    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    assert card =~ "Clarify the fixture"
    assert File.read!(evidence_path) == original_evidence
    # Incomplete/failed/model-corrupt/scenario-corrupt records must be replaced by
    # actual successful readiness, never rendered as though they were complete.
    for broken <- [
          Map.delete(evidence, "model_outcome"),
          Map.delete(evidence, "acceptance_exit"),
          Map.put(evidence, "acceptance_exit", 17),
          Map.put(evidence, "outcome", "failed"),
          Map.put(evidence, "model", %{}),
          Map.put(evidence, "scenarios", []),
          Map.update!(evidence, "scenarios", fn [first | rest] ->
            [Map.put(first, "status", "skipped") | rest]
          end)
        ] do
      File.write!(evidence_path, JSON.encode!(broken))
      {fresh_card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
      assert String.ends_with?(fresh_card, card)
      assert evidence_path |> File.read!() |> JSON.decode!() == evidence
    end

    refute File.exists?(Intent.approval_path(context.repo, "fixture"))
    {output, 5} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "intent/not_approved"
    [_, request] = FakeProvider.provider_requests(context.server)
    assert request.json["model"] == "gpt-6.1-sol"
    assert request.json["reasoning"]["effort"] == "high"
    assert FakeProvider.input_text(request) =~ before[path]
    assert [_] = Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))
  end

  test "SHP-11 invalid, unsupported, provider and not-ready results preserve the ready draft", %{
    suite: suite
  } do
    for kind <- [:invalid, :unsupported, :provider, :not_ready, :topology] do
      context = fixture!(suite)
      before = package(context)

      actions =
        case kind do
          :invalid ->
            List.duplicate(submission([%{"path" => "new.txt", "content" => "no"}]), 3)

          :unsupported ->
            [
              {:function, "submit_refinement",
               %{
                 "constraint" =>
                   "This needs a new step file; refinement changes existing files only."
               }}
            ]

          :provider ->
            [
              submission([
                %{
                  "path" => Intent.feature("fixture"),
                  "content" =>
                    "Feature: Fixture\n  Scenario: Undefined\n    Then a new undefined sentence\n"
                }
              ]),
              {:http, 400,
               %{"error" => %{"code" => "invalid_request_error", "message" => "fixture refusal"}}}
            ]

          :topology ->
            [
              submission([
                %{
                  "path" => Intent.intent_md("fixture"),
                  "content" =>
                    String.replace(
                      before[Intent.intent_md("fixture")],
                      "- features/steps/integration_steps.js\n",
                      ""
                    )
                }
              ])
            ]

          :not_ready ->
            List.duplicate(
              submission([
                %{
                  "path" => Intent.feature("fixture"),
                  "content" =>
                    "Feature: Fixture\n  Scenario: Undefined\n    Then a new undefined sentence\n"
                }
              ]),
              3
            )
        end

      script!(context, actions)
      {output, status} = refine(context)
      assert status != 0, output

      expected =
        case kind do
          kind when kind in [:unsupported, :topology] -> "shape/refinement_constraint"
          :provider -> "provider/"
          _ -> "shape/refinement_invalid"
        end

      assert output =~ expected

      assert package(context) == before
      refute File.exists?(Intent.approval_path(context.repo, "fixture"))

      [evidence] =
        Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))

      assert File.read!(evidence) =~ "outcome"
    end
  end

  test "SHP-11 rejects protected and shared step edits without changing the original package", %{
    suite: suite
  } do
    for target <- [Config.path(), "features/steps/integration_steps.js"] do
      context = fixture!(suite)

      if target != Config.path() do
        other = Path.join(context.repo, Intent.intent_md("other"))
        File.mkdir_p!(Path.dirname(other))

        File.write!(
          other,
          "# Other\nAcceptance:\n- .kogen/intents/other/acceptance.feature\n- #{target}\n"
        )
      end

      before = package(context)
      original = File.read!(Path.join(context.repo, target))

      script!(
        context,
        List.duplicate(submission([%{"path" => target, "content" => "changed"}]), 3)
      )

      {output, status} = refine(context)
      assert status == 1, output
      assert output =~ "not an exclusively owned editable draft file"
      assert package(context) == before
      assert File.read!(Path.join(context.repo, target)) == original
    end
  end

  test "SHP-11 an approved correction archives the exact approval and requires a fresh approval",
       %{
         suite: suite
       } do
    context = approved_fixture!(suite)
    before = package(context)
    approval = File.read!(Intent.approval_path(context.repo, "fixture"))
    index = index(context)
    path = Intent.intent_md("fixture")
    updated = String.replace(before[path], "# Preserve", "# Clarify")
    script!(context, [submission([%{"path" => path, "content" => updated}])])
    {output, 0} = refine(context)
    assert output =~ "refined fixture"
    assert package(context) == Map.put(before, path, updated)
    assert index(context) == index
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))

    [archived] =
      Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/revoked-approval.json"))

    assert File.read!(archived) == approval
    {output, 5} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "intent/not_approved"
    {output, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)])
    assert output =~ "approved fixture"
    assert Intent.approval(context.repo, "fixture")["sha256"] == hash(context)
  end

  test "SHP-11 stale hashes and approved-current dirty implementation refuse before model requests",
       %{
         suite: suite
       } do
    for kind <- [:hash, :dirty] do
      context = approved_fixture!(suite)

      if kind == :dirty,
        do: File.write!(Path.join(context.repo, "app.txt"), "unfinished candidate\n")

      before = package(context)
      approval = File.read!(Intent.approval_path(context.repo, "fixture"))
      index = index(context)
      requests = FakeProvider.provider_requests(context.server)

      {output, status} =
        refine(context, if(kind == :hash, do: String.duplicate("0", 64), else: hash(context)))

      assert status == if(kind == :dirty, do: 5, else: 1), output

      assert output =~
               if(kind == :dirty, do: "environment/dirty_tree", else: "intent/refinement_stale")

      assert package(context) == before
      assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
      assert index(context) == index
      assert FakeProvider.provider_requests(context.server) == requests
    end
  end

  test "SHP-11 unrelated stale legacy approval does not impose Build-clean restrictions", %{
    suite: suite
  } do
    context = approved_fixture!(suite)
    path = Intent.intent_md("fixture")
    File.write!(Path.join(context.repo, path), package(context)[path] <> "\nCurrent draft.\n")
    File.write!(Path.join(context.repo, "app.txt"), "unrelated unfinished implementation\n")
    before = package(context)
    marker = File.read!(Intent.approval_path(context.repo, "fixture"))
    original_index = index(context)
    head = Kogen.Git.head(context.repo)
    updated = before[path] <> "\nClarified only.\n"
    script!(context, [submission([%{"path" => path, "content" => updated}])])
    {output, status} = refine(context)
    assert status == 0, output
    assert package(context) == Map.put(before, path, updated)

    assert File.read!(Path.join(context.repo, "app.txt")) ==
             "unrelated unfinished implementation\n"

    refute File.exists?(Intent.approval_path(context.repo, "fixture"))

    [archive] =
      Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/revoked-approval.json"))

    assert File.read!(archive) == marker
    assert index(context) == original_index
    assert Kogen.Git.head(context.repo) == head
  end

  test "SHP-11 failed and cancelled approved corrections preserve package, raw approval and index",
       %{suite: suite} do
    for kind <- [:provider, :invalid, :not_ready, :cancel] do
      context = approved_fixture!(suite)
      source_path = Kogen.SourceProvenance.path(context.repo, "fixture")

      Kogen.SourceProvenance.publish(context.repo, "fixture", %{
        "version" => 1,
        "contract_sha256" => hash(context),
        "comparison" => "addressed: original",
        "request" => Kogen.SourceProvenance.request("exact original request\r\n", "-"),
        "rounds" => [],
        "corrections" => []
      })

      {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)])
      source = File.read!(source_path)
      before = package(context)
      approval = File.read!(Intent.approval_path(context.repo, "fixture"))
      index = index(context)
      marker = Path.join(context.root, "probe-started")

      actions =
        case kind do
          :provider ->
            [
              {:http, 400,
               %{"error" => %{"code" => "invalid_request_error", "message" => "fixture refusal"}}}
            ]

          :invalid ->
            List.duplicate(
              submission([%{"path" => "app.txt", "content" => "not an artifact"}]),
              3
            )

          :not_ready ->
            List.duplicate(
              submission([
                %{
                  "path" => Intent.feature("fixture"),
                  "content" =>
                    "Feature: Fixture\n  Scenario: Undefined\n    Then a new undefined sentence\n"
                }
              ]),
              3
            )

          :cancel ->
            [{:function, "probe", %{"command" => "touch '#{marker}' && sleep 10"}}]
        end

      script!(context, actions)

      if kind == :cancel do
        port =
          Helpers.start_kogen(context, [
            "intent",
            "refine",
            "fixture",
            hash(context),
            request!(context)
          ])

        Helpers.wait_for_file!(marker)
        {output, 3} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
        assert output =~ "environment/build_running"
        Helpers.signal!(context, port, "INT")
        {_output, 130} = Helpers.await_exit(port, "", 60_000)
      else
        {output, status} = refine(context)
        assert status != 0, output
      end

      assert package(context) == before
      assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
      assert File.read!(source_path) == source
      assert index(context) == index
    end
  end

  test "SHP-11 failed approval revocation restores a read-only artifact and retains approval", %{
    suite: suite
  } do
    context = approved_fixture!(suite)
    before = package(context)
    approval = File.read!(Intent.approval_path(context.repo, "fixture"))
    index = index(context)
    marker = Path.join(context.root, "probe-started")
    path = Intent.intent_md("fixture")

    script!(context, [
      {:function, "probe", %{"command" => "touch '#{marker}' && sleep 1"}},
      submission([
        %{"path" => path, "content" => String.replace(before[path], "# Preserve", "# Clarify")}
      ])
    ])

    port =
      Helpers.start_kogen(context, [
        "intent",
        "refine",
        "fixture",
        hash(context),
        request!(context)
      ])

    Helpers.wait_for_file!(marker)
    # The scratch candidate is already copied; the live destination becomes read-only
    # before publication, which can still replace it through its writable directory.
    File.chmod!(Path.join(context.repo, path), 0o444)
    mode = File.stat!(Path.join(context.repo, path)).mode
    [evidence] = Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*"))
    File.mkdir!(Path.join(evidence, "revoked-approval.json"))
    {output, status} = Helpers.await_exit(port, "", 60_000)
    assert status != 0, output
    assert package(context) == before
    assert File.stat!(Path.join(context.repo, path)).mode == mode
    assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
    assert index(context) == index
  end

  test "SHP-11 changes to HEAD, raw approval or index prevent approved publication", %{
    suite: suite
  } do
    for kind <- [:head, :approval, :index] do
      context = approved_fixture!(suite)
      before = package(context)
      marker = Path.join(context.root, "probe-started")
      path = Intent.intent_md("fixture")

      script!(context, [
        {:function, "probe", %{"command" => "touch '#{marker}' && sleep 1"}},
        submission([
          %{"path" => path, "content" => String.replace(before[path], "# Preserve", "# Clarify")}
        ])
      ])

      port =
        Helpers.start_kogen(context, [
          "intent",
          "refine",
          "fixture",
          hash(context),
          request!(context)
        ])

      Helpers.wait_for_file!(marker)

      case kind do
        :head ->
          Helpers.git!(context, ["commit", "--allow-empty", "-qm", "External HEAD"])

        :approval ->
          File.write!(
            Intent.approval_path(context.repo, "fixture"),
            File.read!(Intent.approval_path(context.repo, "fixture")) <> "\n"
          )

        :index ->
          Helpers.git!(context, ["add", Intent.feature("fixture")])
      end

      approval = File.read!(Intent.approval_path(context.repo, "fixture"))
      index = index(context)
      {output, 1} = Helpers.await_exit(port, "", 60_000)
      assert output =~ "intent/refinement_stale"
      assert package(context) == before
      assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
      assert index(context) == index
    end
  end

  test "SHP-11 an external edit while refining is preserved and prevents publication", %{
    suite: suite
  } do
    context = fixture!(suite)
    before = package(context)
    path = Intent.intent_md("fixture")
    marker = Path.join(context.root, "probe-started")
    updated = String.replace(before[path], "# Preserve", "# Clarify")

    script!(context, [
      {:function, "probe", %{"command" => "touch '#{marker}' && sleep 1"}},
      submission([%{"path" => path, "content" => updated}])
    ])

    hash = hash(context)
    port = Helpers.start_kogen(context, ["intent", "refine", "fixture", hash, request!(context)])
    Helpers.wait_for_file!(marker)
    {approval_output, 3} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    assert approval_output =~ "environment/build_running"
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))
    feature = Intent.feature("fixture")
    external = before[feature] <> "\n# external edit\n"
    File.write!(Path.join(context.repo, feature), external)
    {output, status} = Helpers.await_exit(port, "", 60_000)
    assert status == 1, output
    assert output =~ "intent/refinement_stale"
    assert package(context) == Map.put(before, feature, external)
  end

  test "SHP-11 interruption during a probe preserves the ready package and retained evidence", %{
    suite: suite
  } do
    for {signal, expected} <- [{"INT", 130}, {"TERM", 143}, {"HUP", 129}] do
      context = fixture!(suite)
      before = package(context)
      marker = Path.join(context.root, "probe-started")
      script!(context, [{:function, "probe", %{"command" => "touch '#{marker}' && sleep 10"}}])

      port =
        Helpers.start_kogen(context, [
          "intent",
          "refine",
          "fixture",
          hash(context),
          request!(context)
        ])

      Helpers.wait_for_file!(marker)
      Helpers.signal!(context, port, signal)
      {_output, status} = Helpers.await_exit(port, "", 60_000)
      assert status == expected
      assert package(context) == before

      [evidence] =
        Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))

      assert File.read!(evidence) =~ "interrupted"
    end
  end

  test "a runner failure after passing scenarios never supplies reusable readiness", %{
    suite: suite
  } do
    context = fixture!(suite)
    config_path = Path.join(context.repo, Config.path())
    config = Config.load!(context.repo)

    executions = Path.join(context.root, "runner-executions")

    command =
      "printf 'run\\n' >> #{executions}; " <>
        config.acceptance_run <>
        "; echo fresh runner failure; exit 17"

    File.write!(
      config_path,
      Config.render(%{
        setup: config.setup,
        fix: config.fix,
        checks: config.checks,
        protect: config.protect,
        acceptance: %{run: command, steps_dir: config.steps_dir}
      })
    )

    for n <- 1..2 do
      {output, 1} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
      assert output =~ "exit 17 with all scenarios passed"
      assert output =~ "fresh runner failure"
      refute output =~ "Approve with:"
      refute File.exists?(Path.join(context.repo, ".kogen/local/readiness/fixture.json"))
      refute File.exists?(Intent.approval_path(context.repo, "fixture"))

      assert File.read!(executions) ==
               String.duplicate("run\n", n)
    end
  end

  test "readiness mutations cannot certify the changed baseline, even on repeated cards", %{
    suite: suite
  } do
    context = fixture!(suite)
    steps = Path.join(context.repo, "features/steps/integration_steps.js")

    original_steps = File.read!(steps)
    original = package(context)
    original_index = index(context)

    for mutation <- [
          "fs.appendFileSync('.kogen/intents/fixture/intent.md', '\\n');",
          "fs.writeFileSync('staged-input.txt', 'new'); require('node:child_process').execFileSync('git', ['add', 'staged-input.txt']);",
          "fs.chmodSync('app.txt', 0o755);",
          "fs.unlinkSync('app.txt');"
        ] do
      File.write!(steps, original_steps <> "\nconst fs = require('node:fs');\n" <> mutation)
      before = package(context)

      for _ <- 1..2 do
        {output, 1} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
        assert output =~ "readiness changed candidate files"
        assert package(context) == before
        assert index(context) == original_index
        assert File.read!(Path.join(context.repo, "app.txt")) == "baseline\n"
        refute File.exists?(Path.join(context.repo, "staged-input.txt"))
        refute output =~ "Approve with:"
        refute File.exists?(Path.join(context.repo, ".kogen/local/readiness/fixture.json"))
        refute File.exists?(Intent.approval_path(context.repo, "fixture"))
      end
    end

    File.write!(steps, original_steps)
    assert package(context) == original
  end

  test "approval publication drift restores exact prior approval without certifying changed inputs",
       %{
         suite: suite
       } do
    context = approved_fixture!(suite)
    source_path = Kogen.SourceProvenance.path(context.repo, "fixture")

    Kogen.SourceProvenance.publish(context.repo, "fixture", %{
      "version" => 1,
      "contract_sha256" => hash(context),
      "comparison" => "addressed: original",
      "request" => Kogen.SourceProvenance.request("original request", "-"),
      "rounds" => [],
      "corrections" => []
    })

    {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)])
    original_source = File.read!(source_path)
    path = Intent.intent_md("fixture")
    File.write!(Path.join(context.repo, path), package(context)[path] <> "\nCurrent contract.\n")
    approval_path = Intent.approval_path(context.repo, "fixture")
    previous = File.read!(approval_path) |> JSON.decode!() |> Map.put("custody", "original")
    raw = JSON.encode!(previous) <> "\n"
    File.write!(approval_path, raw)
    original_index = index(context)
    tools = Path.join(context.root, "tools")
    File.mkdir_p!(tools)
    git = System.find_executable("git")

    # Trigger drift only once the new approval is visible. This deterministically
    # exercises the post-publication identity check, not the pre-check guard.
    File.write!(Path.join(tools, "git"), """
    #!/bin/sh
    if [ -f app.txt ] && [ -f '#{approval_path}' ] && ! grep -q custody '#{approval_path}'; then
      printf 'external publication drift\\n' > '#{context.repo}/app.txt'
    fi
    exec '#{git}' "$@"
    """)

    File.chmod!(Path.join(tools, "git"), 0o755)

    {output, status} =
      Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)],
        env: [{"PATH", tools <> ":" <> context.env["PATH"]}]
      )

    assert status == 1, output
    assert output =~ "readiness inputs changed during approval publication"
    refute output =~ "approved fixture"
    assert File.read!(approval_path) == raw
    assert File.read!(Path.join(context.repo, "app.txt")) == "external publication drift\n"
    assert File.read!(source_path) == original_source

    receipt_archive =
      Path.join(Path.dirname(source_path), Kogen.WorkingContext.hash(original_source) <> ".json")

    assert File.read!(receipt_archive) == original_source
    assert index(context) == original_index
  end

  test "approval rollback preserves external receipt and marker edits during publication", %{
    suite: suite
  } do
    for changed <- [:receipt, :marker] do
      context = approved_fixture!(suite)
      source = Kogen.SourceProvenance.path(context.repo, "fixture")

      Kogen.SourceProvenance.publish(context.repo, "fixture", %{
        "version" => 1,
        "contract_sha256" => hash(context),
        "comparison" => "addressed: request",
        "request" => Kogen.SourceProvenance.request("original", "-"),
        "rounds" => [],
        "corrections" => []
      })

      {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)])
      original_source = File.read!(source)
      marker = Intent.approval_path(context.repo, "fixture")
      approval = JSON.decode!(File.read!(marker)) |> Map.put("custody", "prior marker")
      original_marker = JSON.encode!(approval) <> "\n"
      File.write!(marker, original_marker)
      path = Intent.intent_md("fixture")
      File.write!(Path.join(context.repo, path), package(context)[path] <> "\nCurrent draft.\n")
      before = package(context)
      original_index = index(context)
      head = Kogen.Git.head(context.repo)
      destination = if changed == :receipt, do: source, else: marker
      tools = Path.join(context.root, "tools")
      File.mkdir_p!(tools)
      git = System.find_executable("git")

      File.write!(Path.join(tools, "git"), """
      #!/bin/sh
      if [ -f app.txt ] && [ -f '#{marker}' ] && ! grep -q custody '#{marker}' && [ ! -f '#{tools}/triggered' ]; then
        touch '#{tools}/triggered'
        printf 'external edit\n' > '#{destination}'
      fi
      exec '#{git}' "$@"
      """)

      File.chmod!(Path.join(tools, "git"), 0o755)

      {output, status} =
        Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)],
          env: [{"PATH", tools <> ":" <> context.env["PATH"]}]
        )

      assert status == 1, output
      assert File.read!(destination) == "external edit\n"
      if changed == :receipt, do: assert(File.read!(marker) == original_marker)
      if changed == :marker, do: assert(File.read!(source) == original_source)
      assert package(context) == before
      assert index(context) == original_index
      assert Kogen.Git.head(context.repo) == head
    end
  end

  test "SHP-11 local ignored warmth stays available to probes but out of final proof", %{
    suite: suite
  } do
    for ignore <- [:info_exclude, :local_excludes_file] do
      context = approved_fixture!(suite)

      case ignore do
        :info_exclude ->
          File.write!(Path.join(context.repo, ".git/info/exclude"), "local-cache/\n")

        :local_excludes_file ->
          exclude = Path.join(context.root, "local-excludes")
          File.write!(exclude, "local-cache/\n")
          Helpers.git!(context, ["config", "core.excludesFile", exclude])
      end

      File.mkdir_p!(Path.join(context.repo, "local-cache"))
      File.write!(Path.join(context.repo, "local-cache/warm.txt"), "workspace only\n")
      steps = Path.join(context.repo, "features/steps/integration_steps.js")

      File.write!(
        steps,
        File.read!(steps) <>
          "\nrequire('node:assert/strict').equal(require('node:fs').existsSync('local-cache/warm.txt'), false);\n"
      )

      # Establish an exact original record with the cold-input assertion too.
      {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context)])
      before = package(context)
      original_index = index(context)
      path = Intent.intent_md("fixture")
      updated = String.replace(before[path], "# Preserve", "# Clarify")

      script!(context, [
        {:function, "probe", %{"command" => "cat local-cache/warm.txt"}},
        submission([%{"path" => path, "content" => updated}])
      ])

      {output, status} = refine(context)
      assert status == 0, output
      assert package(context) == Map.put(before, path, updated)
      assert index(context) == original_index
      assert File.read!(Path.join(context.repo, "local-cache/warm.txt")) == "workspace only\n"
      assert Enum.any?(FakeProvider.tool_outputs(context.server), &(&1 =~ "workspace only"))

      record_path = Path.join(context.repo, ".kogen/local/readiness/fixture.json")
      record = File.read!(record_path)
      assert Enum.all?(JSON.decode!(record)["scenarios"], &(&1["status"] == "passed"))
      {_, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
      assert File.read!(record_path) == record
    end
  end

  test "Refine refuses changed or deleted bound source during inference without publishing or revoking approval",
       %{suite: suite} do
    for drift <- [:changed, :deleted] do
      context = approved_fixture!(suite)
      path = Intent.intent_md("fixture")
      before = package(context)
      sha = hash(context)
      source = Kogen.SourceProvenance.path(context.repo, "fixture")

      Kogen.SourceProvenance.publish(context.repo, "fixture", %{
        "version" => 1,
        "request" => Kogen.SourceProvenance.request("original Δ🙂\n", "-"),
        "rounds" => [],
        "corrections" => [],
        "contract_sha256" => sha,
        "comparison" => Kogen.SourceProvenance.comparison(context.repo, "fixture")
      })

      {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", sha])
      approval = File.read!(Intent.approval_path(context.repo, "fixture"))
      original_index = index(context)
      original_head = Kogen.Git.head(context.repo)
      updated = before[path] <> "\nClarified only.\n"
      script!(context, [{:pause, self(), submission([%{"path" => path, "content" => updated}])}])
      port = Helpers.start_kogen(context, ["intent", "refine", "fixture", sha, request!(context)])
      assert_receive {:provider_paused, provider}, 60_000

      if drift == :changed,
        do: File.write!(source, File.read!(source) <> " "),
        else: File.rm!(source)

      drifted = File.read(source)
      send(provider, :continue)
      {output, 1} = Helpers.await_exit(port, "", 60_000)
      assert output =~ "source_provenance_changed"
      assert package(context) == before
      assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
      assert index(context) == original_index
      assert Kogen.Git.head(context.repo) == original_head
      assert File.read(source) == drifted
    end
  end

  test "exact approval refuses source drift during readiness instead of silently rebinding it", %{
    suite: suite
  } do
    context = approved_fixture!(suite)
    source = Kogen.SourceProvenance.path(context.repo, "fixture")
    step = Path.join(context.repo, "features/steps/integration_steps.js")

    File.write!(
      step,
      File.read!(step) <> "\nrequire('node:fs').appendFileSync(#{JSON.encode!(source)}, ' ');\n"
    )

    sha = hash(context)

    Kogen.SourceProvenance.publish(context.repo, "fixture", %{
      "version" => 1,
      "request" => Kogen.SourceProvenance.request("frozen original", "-"),
      "rounds" => [],
      "corrections" => [],
      "contract_sha256" => sha,
      "comparison" => Kogen.SourceProvenance.comparison(context.repo, "fixture")
    })

    original_source = File.read!(source)
    File.rm!(Intent.approval_path(context.repo, "fixture"))
    before = package(context)
    original_index = index(context)
    requests = FakeProvider.provider_requests(context.server)
    {output, 1} = Helpers.run_kogen(context, ["intent", "approve", "fixture", sha])
    assert output =~ "source_provenance_changed"
    assert File.read!(source) == original_source <> " "
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))
    assert package(context) == before
    assert index(context) == original_index
    assert FakeProvider.provider_requests(context.server) == requests
  end

  defp fixture!(suite) do
    context = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    File.rm!(Intent.approval_path(context.repo, "fixture"))
    context
  end

  defp approved_fixture!(suite) do
    context = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    context
  end

  defp index(context) do
    {path, 0} =
      Helpers.git!(context, ["rev-parse", "--path-format=absolute", "--git-path", "index"])

    File.read!(String.trim(path))
  end

  defp package(context),
    do:
      Map.new(Intent.baseline(context.repo, "fixture", Config.load!(context.repo)), fn path ->
        {path, File.read!(Path.join(context.repo, path))}
      end)

  defp hash(context),
    do:
      Intent.hash(
        context.repo,
        Intent.baseline(context.repo, "fixture", Config.load!(context.repo))
      )

  defp submission(files), do: {:function, "submit_refinement", %{"files" => files}}

  defp script!(context, actions),
    do: FakeProvider.append(context.server, actions)

  defp request!(context) do
    path = Path.join(context.root, "correction.txt")
    File.write!(path, "Clarify only the existing draft; preserve its executable contract.")
    path
  end

  defp refine(context, hash \\ nil),
    do:
      Helpers.run_kogen(context, [
        "intent",
        "refine",
        "fixture",
        hash || hash(context),
        request!(context)
      ])
end
