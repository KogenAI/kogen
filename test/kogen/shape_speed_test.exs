defmodule Kogen.ShapeSpeedTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Error, ShapeEvidence}

  test "worker configuration is opt-in, complete, exact and line-numbered" do
    assert Config.parse!("version: 1\n", "test").shape_workers == %{enabled: false}

    roles =
      "  read: {model: luna, effort: medium}\n  probe: {model: luna, effort: medium}\n  draft: {model: luna, effort: max}\n"

    for enabled <- ["true", "false"] do
      c = Config.parse!("version: 1\nshape_workers:\n  enabled: #{enabled}\n" <> roles, "test")
      assert c.shape_workers.enabled == (enabled == "true")
      assert c.shape_workers["draft"] == %{model: "luna", effort: "max"}
    end

    for body <- [
          "true",
          "[]",
          "{enabled: yes}",
          "{enabled: 'true'}",
          "{enabled: true}",
          "{enabled: false, read: {model: luna}}",
          "{enabled: false, read: {model: luna, effort: medium, extra: x}}",
          "{surprise: false}",
          "{enabled: false, draft: {model: 3, effort: high}}"
        ] do
      error =
        assert_raise Error, fn ->
          Config.parse!("version: 1\nshape_workers: #{body}\n", "test")
        end

      assert error.reason == "project_config_invalid"
      assert Enum.any?(error.lines, &String.contains?(&1, "line 2:"))
    end
  end

  test "cancellation and overlapping completed calls remain in final timing and usage" do
    dir = Kogen.tmp_path("kogen-evidence-test")
    on_exit(fn -> File.rm_rf!(dir) end)
    ShapeEvidence.start(dir)
    start = Process.get(:shape_evidence).start
    # A completed HTTP call can append while its owner is inside a probe, before
    # the owner consumes the task result. Final phase accounting must retain it.
    for {a, wall} <- [{0, 10}, {5, 10}] do
      ShapeEvidence.record(%{
        event: "provider_call",
        started_ms: a,
        wall_ms: wall,
        usage: %{input: 10, cached: nil, output: 2, reasoning: nil}
      })
    end

    assert catch_throw(
             ShapeEvidence.provider(
               "shape",
               nil,
               %{},
               "main",
               %{model: "sol", effort: "high"},
               fn -> throw({:cancel, "SIGTERM"}) end
             )
           ) == {:cancel, "SIGTERM"}

    ShapeEvidence.finish()

    events =
      File.read!(Path.join(dir, "events.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(events, &(&1["event"] == "provider_call" and &1["status"] == "cancelled"))
    calls = Enum.filter(events, &(&1["event"] == "provider_call"))

    expected =
      ShapeEvidence.union(Enum.map(calls, &{&1["started_ms"], &1["started_ms"] + &1["wall_ms"]}))

    assert Enum.find(events, &(&1["phase"] == "model"))["wall_ms"] == expected
    totals = Enum.find(events, &(&1["event"] == "usage_totals"))
    assert totals["known"]["input"] == 20
    assert totals["unknown_calls"] == 3
    assert System.monotonic_time(:millisecond) >= start
    # A later invocation must not recount earlier append-only events.
    ShapeEvidence.start(dir)
    ShapeEvidence.finish()

    last =
      File.read!(Path.join(dir, "events.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&(&1["phase"] == "model"))
      |> List.last()

    assert last["wall_ms"] == 0
  end

  test "main recovery records each completed transport without claiming retry delay as model time" do
    dir = Kogen.tmp_path("kogen-call-evidence")
    on_exit(fn -> File.rm_rf!(dir) end)
    ShapeEvidence.start(dir)
    role = %{model: "sol", effort: "high"}

    response = %{
      known_usage: %{input: 7, cached: nil, output: 2, reasoning: nil},
      usage: %{input: 7}
    }

    assert ShapeEvidence.provider("shape", nil, %{}, "main", role, fn ->
             assert {:transient, _} =
                      ShapeEvidence.transport(fn -> {:transient, "stream ended"} end)

             assert {:ok, ^response} = ShapeEvidence.transport(fn -> {:ok, response} end)
             response
           end) == response

    ShapeEvidence.finish()

    events =
      File.read!(Path.join(dir, "events.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    calls = Enum.filter(events, &(&1["event"] == "provider_call"))
    assert Enum.map(calls, & &1["status"]) == ["failed", "completed"]
    assert hd(calls)["error"]["detail"] == "stream ended"
    assert List.last(calls)["usage"]["input"] == 7
  end

  test "interval unions do not double count overlaps and handle adjacent boundaries" do
    assert ShapeEvidence.union([]) == 0
    assert ShapeEvidence.union([{0, 0}]) == 0
    assert ShapeEvidence.union([{0, 10}, {5, 15}, {15, 20}]) == 20
    assert ShapeEvidence.union([{10, 20}, {0, 5}, {12, 16}, {30, 35}]) == 20
  end
end
