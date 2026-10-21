defmodule Kogen.FeasibilityTest do
  use ExUnit.Case, async: true
  alias Kogen.{Feasibility, Intent}

  defp intent(ds) do
    %Intent{
      slug: "controls",
      acceptance: ["observer.cjs"],
      feasibility: Enum.map(ds, &("- evidence: " <> JSON.encode!(&1)))
    }
  end

  defp capability do
    %{
      "id" => "route",
      "kind" => "capability",
      "inputs" => ["route.cjs"],
      "observers" => [],
      "checks" => [
        %{
          "name" => "support",
          "command" => "node route.cjs",
          "exit" => 23,
          "output" => "explicit rejection\n"
        }
      ]
    }
  end

  test "ordinary version-3 records need no feasibility proof" do
    assert Feasibility.valid?("unused", intent([]), nil)
    assert Feasibility.valid?("unused", intent([]), [])
  end

  test "declarations require unique ids and ordered actual observer controls" do
    assert Feasibility.declarations(intent([capability()])) == [capability()]

    assert_raise Kogen.Error, fn ->
      Feasibility.declarations(intent([capability(), capability()]))
    end

    observer = %{capability() | "kind" => "observer", "observers" => ["observer.cjs"]}
    assert_raise Kogen.Error, fn -> Feasibility.declarations(intent([observer])) end
  end

  test "rejection evidence binds command, bytes and complete actual outcome" do
    root = Kogen.tmp_path("feasibility-unit")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "route.cjs"), "original")
    d = capability()
    check = Map.put(hd(d["checks"]), "timed_out", false)

    proof = [
      %{
        "id" => "route",
        "kind" => "capability",
        "observers" => %{},
        "inputs" => %{"route.cjs" => Kogen.ShapeContext.hash("original")},
        "checks" => [check]
      }
    ]

    assert Feasibility.valid?(root, intent([d]), proof)
    refute Feasibility.valid?(root, intent([d]), nil)
    refute Feasibility.valid?(root, intent([d]), [])

    for {key, value} <- [
          {"exit", 0},
          {"timed_out", true},
          {"output", "supported\n"},
          {"command", "old driver"}
        ] do
      refute Feasibility.valid?(root, intent([d]), [
               Map.put(hd(proof), "checks", [Map.put(check, key, value)])
             ])
    end

    File.write!(Path.join(root, "route.cjs"), "changed")
    refute Feasibility.valid?(root, intent([d]), proof)
  end
end
