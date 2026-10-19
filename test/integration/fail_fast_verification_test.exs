Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.FailFastVerificationTest do
  use ExUnit.Case, async: true

  alias Kogen.{Checks, Config, Gherkin, Run}
  alias Kogen.Integration.{FakeProvider, Helpers}

  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "failed setup retains evidence and names later setup and gates without an absent model", %{
    suite: suite
  } do
    context =
      Helpers.project!(suite, [
        {:function, "write_file", %{"path" => "app.txt", "content" => "red\n"}},
        {:function, "finish", %{"summary" => "Verify"}},
        {:http, 400,
         %{"error" => %{"code" => "invalid_request_error", "message" => "fixture stop"}}}
      ])

    on_exit(fn -> Helpers.cleanup_case(context) end)
    trace = Path.join(context.root, "setup-trace")
    quote = &Kogen.Init.shell_quote/1

    first =
      "printf 'setup-1\\n' >> #{quote.(trace)}; if grep -qx red app.txt; then echo actual-setup-red; exit 23; fi"

    later = "printf 'setup-2\\n' >> #{quote.(trace)}"
    config = Config.load!(context.repo)

    File.write!(
      Path.join(context.repo, Config.path()),
      Config.render(%{
        setup: [first, later],
        fix: [],
        checks: [%{name: "z-first", run: "true"}, %{name: "a-later", run: "true"}],
        protect: [],
        acceptance: %{run: config.acceptance_run, steps_dir: config.steps_dir}
      })
    )

    {_, 0} =
      Helpers.git!(context, [
        "commit",
        "-q",
        "--only",
        "-m",
        "Configure ordered setup",
        "--",
        Config.path()
      ])

    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)
    {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash])

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status != 0, output
    # Readiness and startup run both setup commands; only the clean red pass stops.
    assert File.read!(trace) |> String.split("\n", trim: true) |> Enum.take(-3) == [
             "setup-1",
             "setup-2",
             "setup-1"
           ]

    names = ["setup-2", "acceptance", "z-first", "a-later"]
    assert output =~ "not run because an earlier item failed: " <> Enum.join(names, ", ")
    log = Helpers.run_log(context)
    events = File.read!(log) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [%{"green" => false, "failing" => ["setup-1"], "not_run" => ^names}] =
             Enum.filter(events, &(&1["event"] == "pass"))

    dir = Path.dirname(log)
    assert {:ok, _, saved} = Run.decode_checkpoint(File.read!(Path.join(dir, "checkpoint.json")))
    assert saved.last_pass.acceptance == :not_run
    assert saved.last_pass.model == :none
    assert saved.last_pass.checks == []

    assert [%{command: ^first, status: 23, output: "actual-setup-red\n"}] =
             Enum.map(saved.last_pass.setup, &Map.take(&1, [:command, :status, :output]))

    assert saved.last_pass.not_run == names
    assert JSON.decode!(File.read!(Path.join(dir, "result.json")))["not_run"] == names

    assert Enum.any?(FakeProvider.tool_outputs(context.server), fn feedback ->
             feedback =~ "actual-setup-red" and feedback =~ "exit status 23" and
               feedback =~ "not run because an earlier item failed: " <> Enum.join(names, ", ")
           end)
  end

  test "real declared Cucumber fail-fast keeps failed and skipped cases red, while complete exit-zero is green",
       %{suite: suite} do
    context = Helpers.project!(suite, [])
    on_exit(fn -> Helpers.cleanup_case(context) end)
    feature = ".kogen/intents/fixture/acceptance.feature"

    text =
      "Feature: Runner stopping\n  Scenario: First\n    Then the candidate succeeds\n  Scenario: Later\n    Then the candidate succeeds\n"

    File.write!(Path.join(context.repo, feature), text)
    trace = Path.join(context.root, "cases")

    File.write!(Path.join(context.repo, "features/steps/integration_steps.js"), """
    const {Then} = require('@cucumber/cucumber');
    const fs = require('node:fs');
    Then('the candidate succeeds', () => {
      fs.appendFileSync(process.env.CASE_TRACE, 'executed\\n');
      if (fs.readFileSync('app.txt', 'utf8').trim() === 'red') throw new Error('actual-case-red');
    });
    """)

    runtime = Path.join(suite.prefix, "lib/kogen")
    {:ok, expected} = Gherkin.parse(text)
    runner = Config.load!(context.repo).acceptance_run

    for {candidate, flags, count} <- [
          {"red", " --fail-fast", 1},
          {"red", "", 2},
          {"green", " --fail-fast", 2}
        ] do
      File.write!(Path.join(context.repo, "app.txt"), candidate)
      File.write!(trace, "")
      report = Path.join(context.root, "messages.ndjson")

      {output, status} =
        System.cmd("/bin/sh", ["-c", runner <> flags],
          cd: context.repo,
          env:
            Helpers.env_for(context, %{
              "KOGEN_NODE" => runtime |> Path.join("node-path") |> File.read!() |> String.trim(),
              "KOGEN_CUCUMBER" => Path.join(runtime, "lib/cucumber/node_modules"),
              "KOGEN_ACCEPTANCE_FEATURES" => feature,
              "KOGEN_ACCEPTANCE_REPORT" => report,
              "CASE_TRACE" => trace
            }),
          stderr_to_stdout: true
        )

      assert length(String.split(File.read!(trace), "\n", trim: true)) == count

      actual =
        Checks.account(context.repo, feature, expected, report, %{status: status, output: output})

      if candidate == "green" do
        assert status == 0, output
        assert actual.problems == []
        assert actual.passed == 2
      else
        assert status != 0
        assert hd(actual.scenarios).status == "failed"
        assert hd(actual.problems) =~ "actual-case-red"
        assert actual.passed == 0

        assert List.last(actual.scenarios).status ==
                 if(flags == "", do: "failed", else: "skipped")

        assert File.read!(report) =~ "actual-case-red"
      end
    end
  end
end
