defmodule Kogen.ShapeEvidenceTest do
  use ExUnit.Case, async: true

  test "adapter three tuple failures retain exactly one unknown physical attempt" do
    dir = Kogen.tmp_path("shape-evidence")
    on_exit(fn -> File.rm_rf!(dir) end)
    Kogen.ShapeEvidence.start(dir)
    result = {:go_error, "refused", %{status: 400}}

    error =
      assert_raise Kogen.Error, fn ->
        Kogen.ShapeEvidence.provider(
          "shape",
          nil,
          "revision",
          [],
          %{model: "fixture", effort: "medium"},
          fn ->
            assert Kogen.ShapeEvidence.transport(fn -> result end) == result
            raise Kogen.Error, class: "provider", reason: "refused", detail: "refused", exit: 4
          end
        )
      end

    assert error.reason == "refused"

    [row] =
      File.read!(Path.join(dir, "events.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert row["status"] == "failed"
    assert Enum.all?(row["usage"], fn {_, value} -> value == nil end)
  end
end
