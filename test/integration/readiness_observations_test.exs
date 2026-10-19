Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ReadinessObservationsTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Intent, Integration.FakeProvider, Integration.Helpers}
  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "SHP-4 narrow shaping corrections retain the model and step files already submitted",
       %{suite: suite} do
    context = fixture!(suite)
    model_path = Intent.model_path("observed")

    model =
      "module observed {\n var count: int\n action init = count' = 0\n action step = count' = count + 1\n val Safety = count >= 0\n}\n"

    proposed =
      files("legitimate missing feature")
      |> List.update_at(0, fn file ->
        %{
          file
          | "content" =>
              String.replace(
                file["content"],
                "Model: not applicable — a fixture without state",
                "Model: #{model_path} invariants=Safety seed=7 samples=2 steps=2"
              )
        }
      end)
      |> Kernel.++([%{"path" => model_path, "content" => model}])

    narrow = Enum.take(proposed, 2)
    script!(context, [submit(proposed), submit(narrow), submit(narrow), submit(narrow)])
    {output, 0} = shape(context)
    assert output =~ "1 fail now"
    assert File.read!(Path.join(context.repo, model_path)) == model

    assert File.read!(Path.join(context.repo, "features/steps/observed_steps.js")) ==
             Enum.at(proposed, 2)["content"]

    assert executions(context) == 1
    refute File.exists?(Intent.approval_path(context.repo, "observed"))
  end

  test "SHP-4 lint corrections keep earlier artifacts and malformed mixed payloads contribute nothing",
       %{suite: suite} do
    for invalid_kind <- [:unsafe, :duplicate] do
      context = fixture!(suite)
      proposed = files(nil)
      intent = hd(proposed)

      invalid = %{
        intent
        | "content" => intent["content"] <> "\n## Decisions\n- Keep the fixture.\n"
      }

      fixed = %{
        invalid
        | "content" =>
            String.replace(
              invalid["content"],
              "- Keep the fixture.",
              "- Keep the fixture. (source: request)"
            )
      }

      step = Enum.at(proposed, 2)

      poisoned = %{
        step
        | "content" => step["content"] <> "\nthrow new Error('unsafe payload leaked');\n"
      }

      script!(context, [
        submit([invalid | tl(proposed)]),
        submit(
          if invalid_kind == :unsafe,
            do: [poisoned, %{"path" => "../outside", "content" => "unsafe"}],
            else: [poisoned, step]
        ),
        submit([fixed])
      ])

      {output, 0} = shape(context)
      assert output =~ "1 pass now"
      assert File.read!(Path.join(context.repo, step["path"])) == step["content"]
      assert File.read!(Path.join(context.repo, intent["path"])) == fixed["content"]
      refute File.exists?(Path.join(context.root, "outside"))
      assert executions(context) == 1

      assert Enum.any?(
               FakeProvider.tool_outputs(context.server),
               &String.contains?(&1, "decision has no source")
             )
    end
  end

  test "SHP-4 an earlier step cannot be silently abandoned outside the approval baseline", %{
    suite: suite
  } do
    context = fixture!(suite)
    proposed = files("legitimate missing feature")
    old = Enum.at(proposed, 2)
    replacement = %{old | "path" => "features/steps/replacement.js"}

    changed_intent = %{
      hd(proposed)
      | "content" => String.replace(hd(proposed)["content"], old["path"], replacement["path"])
    }

    script!(context, [
      submit(proposed),
      submit([changed_intent, replacement]),
      submit([changed_intent]),
      submit([changed_intent])
    ])

    {output, 1} = shape(context)
    assert output =~ "proposed artifacts must remain declared"
    assert output =~ "same slug or a new one"
    assert File.read!(Path.join(context.repo, old["path"])) == old["content"]
    refute File.exists?(Path.join(context.repo, replacement["path"]))
    refute File.exists?(Intent.approval_path(context.repo, "observed"))
    assert executions(context) == 1
  end

  test "SHP-4 formatting cannot abandon a retained executable step outside the baseline", %{
    suite: suite
  } do
    context = fixture!(suite)
    config = Config.load!(context.repo)
    proposed = files(nil)
    step = Enum.at(proposed, 2)

    formatter =
      "const fs = require(\"node:fs\"); const path = #{JSON.encode!(Intent.intent_md("observed"))}; " <>
        "fs.writeFileSync(path, fs.readFileSync(path, \"utf8\").replace(#{JSON.encode!("- #{step["path"]}\n")}, \"\"));"

    File.write!(
      Path.join(context.repo, Config.path()),
      Config.render(%{
        setup: [],
        fix: ["node -e '#{formatter}'"],
        checks: [],
        protect: config.protect,
        acceptance: %{run: config.acceptance_run, steps_dir: config.steps_dir}
      })
    )

    script!(context, List.duplicate(submit(proposed), 3))
    {output, status} = shape(context)
    assert status == 1, output
    assert output =~ "proposed artifacts must remain declared"
    assert File.read!(Path.join(context.repo, step["path"])) == step["content"]
    refute File.exists?(Path.join(context.repo, ".kogen/local/readiness/observed.json"))
    refute File.exists?(Intent.approval_path(context.repo, "observed"))
    assert executions(context) == 0
  end

  test "SHP-8 the final shaper sees a fixture failure and repairs it before ready", %{
    suite: suite
  } do
    context = fixture!(suite)
    bad = files("unique fixture input failure")
    fixed = files(nil)
    script!(context, [submit(bad), submit(fixed)])
    {output, 0} = shape(context)
    assert output =~ "1 pass now"

    assert File.read!(Path.join(context.repo, "features/steps/observed_steps.js")) ==
             List.last(fixed)["content"]

    feedback = FakeProvider.tool_outputs(context.server) |> Enum.join("\n")
    assert feedback =~ "unique fixture input failure"
    assert feedback =~ "Then the observation check runs"
    assert feedback =~ "line 3"
    assert executions(context) == 2
    refute File.exists?(Intent.approval_path(context.repo, "observed"))
  end

  test "SHP-8 legitimate red is acknowledged unchanged without another check and cards retain observations",
       %{suite: suite} do
    context = fixture!(suite)
    proposed = files("product behavior is not implemented")
    script!(context, [submit(proposed), submit(proposed)])
    {output, 0} = shape(context)
    assert output =~ "1 fail now"
    assert executions(context) == 1
    feedback = FakeProvider.tool_outputs(context.server) |> Enum.join("\n")
    assert feedback =~ "product behavior is not implemented"
    assert feedback =~ "resubmit"
    {first, 5} = Helpers.run_kogen(context, ["intent", "approve", "observed"])
    {second, 5} = Helpers.run_kogen(context, ["intent", "approve", "observed"])
    assert first == second
    assert first =~ "product behavior is not implemented"
    assert first =~ "Then the observation check runs"
    assert first =~ "Acceptance exit: 1"
    assert first =~ hash(context, "observed")
    assert first =~ head(context)
    assert executions(context) == 1
  end

  test "SHP-8 hook locations and explicit UTF-8 truncation reach the same conversation and card",
       %{suite: suite} do
    context = fixture!(suite)
    proposed = files(nil)
    message = String.duplicate("é", 11_000)

    proposed =
      List.update_at(proposed, 2, fn file ->
        %{
          file
          | "content" =>
              file["content"] <>
                "\nconst { Before } = require('@cucumber/cucumber');\nBefore(function () { throw new Error(#{JSON.encode!(message)}); });\n"
        }
      end)

    script!(context, [submit(proposed), submit(proposed)])
    {_output, 0} = shape(context)
    feedback = FakeProvider.tool_outputs(context.server) |> Enum.join("\n")
    assert String.valid?(feedback)
    assert feedback =~ "a hook at"
    assert feedback =~ "observed_steps.js"
    assert feedback =~ "bytes omitted"
    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "observed"])
    assert String.valid?(card)
    assert card =~ "a hook at"
    assert card =~ "bytes omitted"
    assert executions(context) == 1
  end

  test "SHP-8 changed HEAD cannot acknowledge observations from an earlier check", %{suite: suite} do
    context = fixture!(suite)
    proposed = files("legitimate red under observed HEAD")
    marker = Path.join(context.root, "observed-before-head-change")

    script!(context, [
      submit(proposed),
      {:function, "probe", %{"command" => "touch '#{marker}' && sleep 1"}},
      submit(proposed),
      submit(proposed)
    ])

    old_head = head(context)
    port = Helpers.start_kogen(context, ["intent", "shape", "observed", request!(context)])
    Helpers.wait_for_file!(marker)
    {_, 0} = Helpers.git!(context, ["commit", "--allow-empty", "-qm", "External HEAD change"])
    {output, 0} = Helpers.await_exit(port, "", 20_000)
    assert output =~ "1 fail now"
    assert executions(context) == 2
    feedback = FakeProvider.tool_outputs(context.server) |> Enum.join("\n")
    assert feedback =~ old_head
    assert feedback =~ head(context)
  end

  test "SHP-11 cumulative red proposals stay unpublished until their exact observations are acknowledged",
       %{suite: suite} do
    context = fixture!(suite)
    intent = Intent.intent_md("fixture")
    feature = Intent.feature("fixture")
    step = "features/steps/integration_steps.js"

    original =
      Map.new(
        Intent.baseline(context.repo, "fixture", Config.load!(context.repo)),
        &{&1, File.read!(Path.join(context.repo, &1))}
      )

    {_, 0} =
      Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context, "fixture")])

    approval = File.read!(Intent.approval_path(context.repo, "fixture"))

    {index_path, 0} =
      Helpers.git!(context, ["rev-parse", "--path-format=absolute", "--git-path", "index"])

    index = File.read!(String.trim(index_path))
    updated_intent = String.replace(original[intent], "# Preserve", "# Observe")
    corrected_intent = String.replace(updated_intent, "# Observe", "# Acknowledge")

    changed_feature =
      String.replace(
        original[feature],
        "the acceptance check passes",
        "the observed product remains red"
      )

    changed_step =
      original[step] <>
        "\nThen('the observed product remains red', function () { throw new Error('unique refinement red observation'); });\n"

    marker = Path.join(context.root, "red-refinement-observed")

    script!(context, [
      {:function, "submit_refinement",
       %{
         "files" => [
           %{"path" => intent, "content" => updated_intent},
           %{"path" => feature, "content" => changed_feature},
           %{"path" => step, "content" => changed_step}
         ]
       }},
      {:function, "probe", %{"command" => "touch '#{marker}' && sleep 1"}},
      {:function, "submit_refinement",
       %{"files" => [%{"path" => intent, "content" => corrected_intent}]}},
      {:function, "submit_refinement",
       %{"files" => [%{"path" => intent, "content" => corrected_intent}]}}
    ])

    count = executions(context)

    port =
      Helpers.start_kogen(context, [
        "intent",
        "refine",
        "fixture",
        hash(context, "fixture"),
        request!(context)
      ])

    Helpers.wait_for_file!(marker)
    for {path, bytes} <- original, do: assert(File.read!(Path.join(context.repo, path)) == bytes)
    assert File.read!(Intent.approval_path(context.repo, "fixture")) == approval
    assert File.read!(String.trim(index_path)) == index
    {output, 0} = Helpers.await_exit(port, "", 20_000)
    assert output =~ "refined fixture"
    assert File.read!(Path.join(context.repo, intent)) == corrected_intent
    assert File.read!(Path.join(context.repo, feature)) == changed_feature
    assert File.read!(Path.join(context.repo, step)) == changed_step
    assert executions(context) - count == 2
    assert File.read!(String.trim(index_path)) == index
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))
    feedback = FakeProvider.tool_outputs(context.server) |> Enum.join("\n")
    assert feedback =~ "unique refinement red observation"
    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    assert card =~ "unique refinement red observation"
    assert executions(context) - count == 2
  end

  test "SHP-11 unchanged red from initial context acknowledges its existing check", %{
    suite: suite
  } do
    context = fixture!(suite)
    step = Path.join(context.repo, "features/steps/integration_steps.js")

    File.write!(
      step,
      String.replace(
        File.read!(step),
        "if (!this.fixtureAvailable)",
        "throw new Error('pre-existing legitimate product red'); if (!this.fixtureAvailable)"
      )
    )

    {_, 0} =
      Helpers.run_kogen(context, ["intent", "approve", "fixture", hash(context, "fixture")])

    File.rm!(Path.join(context.repo, ".kogen/local/readiness/fixture.json"))
    path = Intent.intent_md("fixture")
    content = File.read!(Path.join(context.repo, path))

    script!(context, [
      {:function, "submit_refinement", %{"files" => [%{"path" => path, "content" => content}]}}
    ])

    before = executions(context)

    {output, 0} =
      Helpers.run_kogen(context, [
        "intent",
        "refine",
        "fixture",
        hash(context, "fixture"),
        request!(context)
      ])

    assert output =~ "refined fixture"
    assert executions(context) - before == 1
    requests = FakeProvider.provider_requests(context.server)
    prompt = List.last(requests).json["input"] |> hd() |> Map.fetch!("content")

    assert prompt =~ "pre-existing legitimate product red"
    [_, reference] = Regex.run(~r/^Evidence: (.+)$/m, prompt)
    assert File.read!(reference) =~ "pre-existing legitimate product red"

    [retained] =
      Path.wildcard(
        Path.join(context.repo, ".kogen/local/refinements/*/original-observations.txt")
      )

    assert File.read!(reference) == File.read!(retained)

    assert File.read!(Path.join(context.repo, path)) == content
    refute File.exists?(Intent.approval_path(context.repo, "fixture"))
  end

  defp fixture!(suite) do
    context = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    config = Config.load!(context.repo)
    trace = Path.join(context.root, "readiness-runs")

    command =
      "if grep -q 'Scenario:' \"$KOGEN_ACCEPTANCE_FEATURES\"; then printf 'run\\n' >> '#{trace}'; fi; " <>
        config.acceptance_run

    File.write!(
      Path.join(context.repo, Config.path()),
      Config.render(%{
        setup: [],
        fix: [],
        checks: [],
        protect: config.protect,
        acceptance: %{run: command, steps_dir: config.steps_dir}
      })
    )

    {_, 0} = Helpers.git!(context, ["add", Config.path()])
    {_, 0} = Helpers.git!(context, ["commit", "-qm", "Count actual readiness executions"])
    context
  end

  defp files(failure) do
    body = if failure, do: "throw new Error(#{JSON.encode!(failure)});", else: "return;"

    [
      %{
        "path" => Intent.intent_md("observed"),
        "content" =>
          "# Observe actual readiness\n\nSlug: observed\nModel: not applicable — a fixture without state\nAcceptance:\n- .kogen/intents/observed/acceptance.feature\n- features/steps/observed_steps.js\n\n## Tests\n- observe actual readiness: the observation scenario (regression)\n\n## Feasibility\n- none\n"
      },
      %{
        "path" => Intent.feature("observed"),
        "content" =>
          "Feature: Actual readiness\n  Scenario: Observed behavior\n    Then the observation check runs\n"
      },
      %{
        "path" => "features/steps/observed_steps.js",
        "content" =>
          "const { Then } = require('@cucumber/cucumber');\nThen('the observation check runs', function () { #{body} });\n"
      }
    ]
  end

  defp executions(context) do
    case File.read(Path.join(context.root, "readiness-runs")) do
      {:ok, text} -> length(String.split(text, "\n", trim: true))
      _ -> 0
    end
  end

  defp hash(context, slug),
    do: Intent.hash(context.repo, Intent.baseline(context.repo, slug, Config.load!(context.repo)))

  defp head(context), do: Kogen.Git.head(context.repo)
  defp submit(files), do: {:function, "submit", %{"files" => files}}

  defp script!(context, actions),
    do:
      Agent.update(
        context.server.state,
        &%{&1 | script: Enum.take(&1.script, &1.next) ++ actions}
      )

  defp request!(context) do
    path = Path.join(context.root, "request.txt")

    File.write!(
      path,
      "Inspect actual readiness observations; correct demonstrated fixture defects or acknowledge valid missing-feature red."
    )

    path
  end

  defp shape(context),
    do: Helpers.run_kogen(context, ["intent", "shape", "observed", request!(context)])
end
