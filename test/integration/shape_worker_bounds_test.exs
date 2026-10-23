Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ShapeWorkerBoundsTest do
  use ExUnit.Case, async: true, group: :installed_release
  alias Kogen.{Config, Integration.FakeProvider, Integration.Helpers, ShapeContext}
  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    %{suite: suite}
  end

  test "twelve ordinary tools plus two probes are valid; either adjacent excess fails without replay",
       %{suite: suite} do
    for {reads, probes, expected} <- [{12, 2, "completed"}, {13, 2, "failed"}, {12, 3, "failed"}] do
      context = Helpers.project!(suite, [], staged_intent: false)
      on_exit(fn -> Helpers.cleanup_case(context) end)
      config_path = Path.join(context.repo, Config.path())

      File.write!(
        config_path,
        File.read!(config_path) <>
          "\nshape_workers:\n  enabled: true\n  read: {model: luna, effort: medium}\n  probe: {model: luna, effort: medium}\n  draft: {model: luna, effort: max}\n"
      )

      config = Config.load!(context.repo)

      brief = %{
        revision: ShapeContext.revision(context.repo),
        outcomes: "Inspect the existing fixture only",
        interfaces: "No product API changes",
        transitions: "Stateless inspection",
        fixtures: "app.txt is baseline; /bin/sh available; acceptance is already accounted",
        exclusions: "No writes, approval, Build or publication",
        artifacts: [],
        protected_paths: Kogen.Intent.baseline(context.repo, "speed-bounds", config)
      }

      job = %{
        id: "inspect",
        role: "probe",
        scope: "Read the fixture and prove shell printf",
        paths: ["app.txt"],
        owns: []
      }

      tools = for i <- 1..reads, do: call("read_file", %{path: "app.txt"}, "read#{i}")
      probes = for i <- 1..probes, do: call("probe", %{command: "printf focused"}, "probe#{i}")
      question = {:function, "submit", %{questions: [%{question: "Inspect the fixture?"}]}}

      actions = [
        {:function, "shape_batch", %{brief: brief, jobs: [job]}},
        {:items,
         tools ++ probes ++ [call("worker_result", %{evidence: "inspected", files: []}, "result")]},
        question
      ]

      FakeProvider.append(context.server, actions)

      request = Path.join(context.root, "request.txt")

      File.write!(
        request,
        "Inspect only the fixture; stay sequential unless complete boundaries are known."
      )

      {output, 5} = Helpers.run_kogen(context, ["intent", "shape", "speed-bounds", request])
      assert output =~ "Questions for speed-bounds"

      batch =
        FakeProvider.provider_requests(context.server)
        |> Enum.flat_map(&(&1.json["input"] || []))
        |> Enum.find(&(&1["type"] == "function_call_output" and &1["call_id"] == "call-2"))

      assert batch
      result = JSON.decode!(batch["output"])
      assert result["status"] == expected
      [job_result] = result["jobs"]
      assert job_result["status"] == expected
      if expected == "failed", do: assert(job_result["error"] =~ "bound exhausted")

      calls =
        FakeProvider.provider_requests(context.server)
        |> Enum.filter(fn r ->
          Enum.any?(r.json["tools"] || [], &(&1["name"] == "worker_result"))
        end)

      assert length(calls) == 1
    end
  end

  test "workers receive bounded long-line reads and replay the delivered display exactly", %{
    suite: suite
  } do
    context = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    config_path = Path.join(context.repo, Config.path())

    File.write!(
      config_path,
      File.read!(config_path) <>
        "\nshape_workers:\n  enabled: true\n  read: {model: luna, effort: medium}\n  probe: {model: luna, effort: medium}\n  draft: {model: luna, effort: max}\n"
    )

    original = JSON.encode!(%{"input" => String.duplicate("x", 514_428)})
    path = Path.join(context.repo, "large.json")
    File.write!(path, original)
    config = Config.load!(context.repo)

    brief = %{
      revision: ShapeContext.revision(context.repo),
      outcomes: "Inspect the selected long line",
      interfaces: "Read-only tools",
      transitions: "Stateless inspection",
      fixtures: "large.json is a 514440-byte single line",
      exclusions: "No publication or approval",
      artifacts: [],
      protected_paths: Kogen.Intent.baseline(context.repo, "bounded-worker", config)
    }

    job = %{
      id: "inspect",
      role: "read",
      scope: "Read the long line then the ordinary fixture",
      paths: ["large.json", "app.txt"],
      owns: []
    }

    FakeProvider.append(context.server, [
      {:function, "shape_batch", %{brief: brief, jobs: [job]}},
      {:items, [call("read_file", %{path: "large.json", start_line: 1, end_line: 35}, "large")]},
      {:items, [call("read_file", %{path: "app.txt"}, "ordinary")]},
      {:function, "worker_result", %{evidence: "inspected bounded display", files: []}},
      {:function, "submit", %{questions: [%{question: "Continue bounded worker inspection?"}]}}
    ])

    request = Path.join(context.root, "request.txt")
    File.write!(request, "Inspect the selected long line with one read worker.")
    {output, 5} = Helpers.run_kogen(context, ["intent", "shape", "bounded-worker", request])
    assert output =~ "Continue bounded worker inspection?"

    workers =
      FakeProvider.provider_requests(context.server)
      |> Enum.filter(fn r ->
        Enum.any?(r.json["tools"] || [], &(&1["name"] == "worker_result"))
      end)

    assert length(workers) == 3
    [_, continued, replayed] = workers

    delivered =
      Enum.find(
        continued.json["input"],
        &(&1["call_id"] == "large" and &1["type"] == "function_call_output")
      )

    assert delivered["output"] == Kogen.Tools.cut("1\t" <> original)
    assert byte_size(delivered["output"]) <= 16_384
    assert delivered["output"] =~ "bytes omitted"
    assert delivered in replayed.json["input"]
    assert File.read!(path) == original

    assert Enum.any?(FakeProvider.tool_outputs(context.server), fn text ->
             String.starts_with?(text, "{") and
               match?(
                 %{"status" => "completed", "jobs" => [%{"status" => "completed"}]},
                 JSON.decode!(text)
               )
           end)
  end

  defp call(name, args, id),
    do: %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => JSON.encode!(args)
    }
end
