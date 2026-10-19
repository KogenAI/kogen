Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.BuilderBlockerTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Intent, Integration.FakeProvider, Integration.Helpers}
  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "LOOP-7 a builder-reported protected contradiction stops before later calls or gates", %{
    suite: suite
  } do
    context = fixture!(suite)
    step = "features/steps/integration_steps.js"
    original = File.read!(Path.join(context.repo, step))

    File.write!(
      Path.join(context.repo, step),
      String.replace(
        original,
        "if (!this.fixtureAvailable) throw new Error('fixture was not available');",
        "const value = require('node:fs').readFileSync('app.txt', 'utf8').trim();\nrequire('node:assert/strict').equal(value, 'A');\nrequire('node:assert/strict').equal(value, 'B', 'fixture requires mutually exclusive B');"
      )
    )

    configure!(context)
    before = authority(context)

    command =
      "export KOGEN_ACCEPTANCE_FEATURES=.kogen/intents/fixture/acceptance.feature KOGEN_ACCEPTANCE_REPORT=.kogen/local/probe.jsonl; " <>
        Config.load!(context.repo).acceptance_run

    report = report(step)

    script!(context, [
      call("write_file", %{"path" => "app.txt", "content" => "A\n"}),
      call("shell", %{"command" => command}),
      {:items,
       [
         item("finish", %{"summary" => "earlier finish must not start gates"}, "early-finish"),
         item("report_blocker", report, "blocker"),
         item("write_file", %{"path" => "late.txt", "content" => "must not run"}, "late"),
         item("shell", %{"command" => "touch .kogen/local/late-shell"}, "late-shell"),
         item("finish", %{"summary" => "must not verify"}, "late-finish")
       ]}
    ])

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert Enum.any?(FakeProvider.tool_outputs(context.server), fn feedback ->
             String.starts_with?(feedback, "exit status: 1") and
               String.contains?(feedback, "fixture requires mutually exclusive B")
           end)

    assert status == 1, output
    assert output =~ "candidate/build_blocked"
    assert output =~ "BUILDER-REPORTED"
    assert output =~ report["evidence"]
    assert authority(context) == before
    assert File.read!(Path.join(context.repo, "app.txt")) == "A\n"
    refute File.exists?(Path.join(context.repo, "late.txt"))
    refute File.exists?(Path.join(context.repo, ".kogen/local/late-shell"))
    refute File.exists?(Path.join(context.repo, ".kogen/local/fixer-ran"))
    assert File.read!(Path.join(context.repo, ".kogen/local/check-runs")) == "check\n"
    assert result(context)["outcome"] == "build_blocked"
    assert result(context)["blocker"] == Map.put(report, "classification", "BUILDER-REPORTED")
    assert result(context)["passes"] == 0
    assert result(context)["reviews"] == 0
    assert FakeProvider.review_requests(context.server) == []

    assert Enum.any?(
             FakeProvider.tool_outputs(context.server),
             &String.contains?(&1, "fixture requires mutually exclusive B")
           )

    assert File.read!(Helpers.run_log(context)) =~ "builder_blocker"
    id = Path.basename(Path.dirname(Helpers.run_log(context)))
    requests = length(FakeProvider.provider_requests(context.server))
    candidate = File.read!(Path.join(context.repo, "app.txt"))
    {resumed, code} = Helpers.run_kogen(context, ["intent", "resume", id])
    assert code == 1, resumed
    assert resumed =~ "candidate/resume_refused"
    assert authority(context) == before
    assert File.read!(Path.join(context.repo, "app.txt")) == candidate
    assert length(FakeProvider.provider_requests(context.server)) == requests
  end

  test "LOOP-7 malformed, empty and unprotected blocker reports return feedback and grant no writes",
       %{suite: suite} do
    context = fixture!(suite)
    original = File.read!(Path.join(context.repo, "features/steps/integration_steps.js"))

    invalid = [
      report("app.txt"),
      report("features/steps/integration_steps.js") |> Map.put("paths", []),
      report("features/steps/integration_steps.js") |> Map.put("reason", " "),
      report("features/steps/integration_steps.js") |> Map.put("evidence", ""),
      report("features/steps/integration_steps.js") |> Map.put("paths", [123]),
      report("features/steps/integration_steps.js")
      |> Map.put("paths", [
        "features/steps/integration_steps.js",
        "features/steps/integration_steps.js"
      ]),
      report("features/steps/integration_steps.js") |> Map.put("unexpected", true)
    ]

    script!(
      context,
      Enum.map(invalid, &call("report_blocker", &1)) ++
        [
          call("write_file", %{
            "path" => "features/steps/integration_steps.js",
            "content" => "forbidden"
          }),
          call("write_file", %{"path" => "app.txt", "content" => "ordinary implementation\n"}),
          call("finish", %{"summary" => "ready"}),
          call("submit_review", %{"verdict" => "approve", "findings" => []})
        ]
    )

    {output, 0} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "landed fixture"
    assert File.read!(Path.join(context.repo, "features/steps/integration_steps.js")) == original
    feedback = FakeProvider.tool_outputs(context.server) |> Enum.join("\n")
    assert feedback =~ "invalid blocker"
    assert feedback =~ "refused: features/steps/integration_steps.js"
    refute Map.has_key?(result(context), "blocker")
  end

  test "LOOP-7 accepting a blocker still requires the original HEAD and protected bytes", %{
    suite: suite
  } do
    for {mutation, expected} <- [
          {"printf changed >> features/steps/integration_steps.js", "baseline_changed"},
          {"git -c commit.gpgsign=false commit --allow-empty -qm moved", "head_moved"},
          {"git update-ref -d HEAD", "head_moved"}
        ] do
      context = fixture!(suite)
      original_index = File.read!(Path.join(context.repo, ".git/index"))
      original_approval = File.read!(Intent.approval_path(context.repo, "fixture"))

      script!(context, [
        call("shell", %{"command" => mutation}),
        call("report_blocker", report("features/steps/integration_steps.js"))
      ])

      {output, 1} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
      assert output =~ expected
      refute result(context)["outcome"] == "build_blocked"
      assert File.read!(Path.join(context.repo, ".git/index")) == original_index
      assert File.read!(Intent.approval_path(context.repo, "fixture")) == original_approval
    end
  end

  defp fixture!(suite) do
    context = Helpers.project!(suite, [])
    on_exit(fn -> Helpers.cleanup_case(context) end)
    context
  end

  defp configure!(context) do
    config = Config.load!(context.repo)

    File.write!(
      Path.join(context.repo, Config.path()),
      Config.render(%{
        setup: [],
        fix: ["touch .kogen/local/fixer-ran"],
        checks: [%{name: "count", run: "printf 'check\\n' >> .kogen/local/check-runs"}],
        protect: config.protect,
        acceptance: %{run: config.acceptance_run, steps_dir: config.steps_dir}
      })
    )

    Helpers.git!(context, [
      "commit",
      "--only",
      "-qm",
      "Track configured gate",
      "--",
      Config.path()
    ])

    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)
    {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash])
  end

  defp report(path),
    do: %{
      "paths" => [path],
      "reason" => "The fixture requires the same value to equal A and B.",
      "evidence" =>
        "Real acceptance probe: exit status 1, fixture requires mutually exclusive B at integration_steps.js."
    }

  defp call(name, args), do: {:function, name, args}

  defp item(name, args, id),
    do: %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => JSON.encode!(args)
    }

  defp script!(context, actions),
    do:
      Agent.update(
        context.server.state,
        &%{&1 | script: Enum.take(&1.script, &1.next) ++ actions}
      )

  defp authority(context),
    do:
      {Kogen.Git.head(context.repo), File.read!(Path.join(context.repo, ".git/index")),
       File.read!(Intent.approval_path(context.repo, "fixture"))}

  defp result(context) do
    [path] = Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/result.json"))
    path |> File.read!() |> JSON.decode!()
  end
end
