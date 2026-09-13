defmodule Kogen.ShapingReadinessTest do
  use ExUnit.Case, async: true
  test "collection deadline can expire before readiness" do
    marker = Path.join(System.tmp_dir!(), "kogen-shaping-ready-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(marker) end)
    source = Path.expand("delayed_readiness.exs", __DIR__)
    result = Kogen.IsolatedCase.run(source, "test delayed startup", collection_timeout: 2_000, env: [{"SHAPING_READY_MARKER", marker}])
    IO.inspect(result, label: "delayed child result")
    IO.inspect(File.exists?(marker), label: "ready marker exists")
    assert {:error, :timeout, _} = result
    refute File.exists?(marker)
  end
end
