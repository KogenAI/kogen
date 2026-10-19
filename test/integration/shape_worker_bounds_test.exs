Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ShapeWorkerBoundsTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Integration.FakeProvider, Integration.Helpers, ShapeContext}
  @moduletag :integration

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

      Agent.update(
        context.server.state,
        &%{&1 | script: Enum.take(&1.script, &1.next) ++ actions}
      )

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

  defp call(name, args, id),
    do: %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => JSON.encode!(args)
    }
end
