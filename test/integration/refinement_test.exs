Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.RefinementTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Intent, Integration.FakeProvider, Integration.Helpers}
  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
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
    assert request.json["input"] |> hd() |> Map.fetch!("content") =~ before[path]
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

  test "SHP-11 stale hashes, approval mismatches and dirty implementation refuse before model requests",
       %{
         suite: suite
       } do
    for kind <- [:hash, :approval, :dirty] do
      context = approved_fixture!(suite)

      if kind == :approval,
        do:
          File.write!(
            Path.join(context.repo, Intent.intent_md("fixture")),
            package(context)[Intent.intent_md("fixture")] <> "\nChanged after approval.\n"
          )

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

  test "SHP-11 failed and cancelled approved corrections preserve package, raw approval and index",
       %{suite: suite} do
    for kind <- [:provider, :invalid, :not_ready, :cancel] do
      context = approved_fixture!(suite)
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
        {_output, 130} = Helpers.await_exit(port, "", 20_000)
      else
        {output, status} = refine(context)
        assert status != 0, output
      end

      assert package(context) == before
      assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
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
    {output, status} = Helpers.await_exit(port, "", 20_000)
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
      {output, 1} = Helpers.await_exit(port, "", 20_000)
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
    {output, status} = Helpers.await_exit(port, "", 20_000)
    assert status == 1, output
    assert output =~ "intent/refinement_stale"
    assert package(context) == Map.put(before, feature, external)
  end

  test "SHP-11 interruption during a probe preserves the ready package and retained evidence", %{
    suite: suite
  } do
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
    Helpers.signal!(context, port, "INT")
    {_output, status} = Helpers.await_exit(port, "", 20_000)
    assert status == 130
    assert package(context) == before
    [evidence] = Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))
    assert File.read!(evidence) =~ "interrupted"
  end

  test "a runner failure after passing scenarios never supplies reusable readiness", %{
    suite: suite
  } do
    context = fixture!(suite)
    config_path = Path.join(context.repo, Config.path())
    config = Config.load!(context.repo)

    command =
      "printf 'run\\n' >> .kogen/local/runner-executions; " <>
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

      assert File.read!(Path.join(context.repo, ".kogen/local/runner-executions")) ==
               String.duplicate("run\n", n)
    end
  end

  test "readiness mutations cannot certify the changed baseline, even on repeated cards", %{
    suite: suite
  } do
    context = fixture!(suite)
    steps = Path.join(context.repo, "features/steps/integration_steps.js")

    File.write!(
      steps,
      File.read!(steps) <>
        """
        const fs = require('node:fs');
        fs.appendFileSync('.kogen/intents/fixture/intent.md', '\\n');
        """
    )

    for _ <- 1..2 do
      {output, 1} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
      assert output =~ "readiness inputs changed"
      refute output =~ "Approve with:"
      refute File.exists?(Path.join(context.repo, ".kogen/local/readiness/fixture.json"))
      refute File.exists?(Intent.approval_path(context.repo, "fixture"))
    end
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
    do:
      Agent.update(context.server.state, fn state ->
        %{state | script: Enum.take(state.script, state.next) ++ actions}
      end)

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
