defmodule Kogen.RunTest do
  use ExUnit.Case, async: true
  alias Kogen.Run

  test "checkpoint decoder refuses damaged, incomplete and incompatible state" do
    for bytes <- [
          "{broken",
          "{}",
          ~s({"version":999}),
          ~s({"version":1,"state":"bad"}),
          JSON.encode!(%{"version" => 1, "state" => Base.encode64(:erlang.term_to_binary(%{}))})
        ] do
      assert {:error, _} = Run.decode_checkpoint(bytes)
    end
  end

  test "atomic checkpoint publication leaves prior valid document through interrupted publication" do
    root = Kogen.tmp_path("checkpoint-publication")
    on_exit(fn -> File.rm_rf!(root) end)
    run = Run.start(root)
    Run.checkpoint(run, %{"version" => 1, "marker" => "complete"})
    path = Path.join(run.dir, "checkpoint.json")
    File.write!(path <> ".tmp", "{interrupted")
    assert JSON.decode!(File.read!(path)) == %{"version" => 1, "marker" => "complete"}
    Run.checkpoint(run, %{"version" => 1, "marker" => "next"})
    assert JSON.decode!(File.read!(path))["marker"] == "next"
    refute File.exists?(path <> ".tmp")
  end

  test "the run log cap preserves UTF-8 and fits in 1 MiB including its marker" do
    for size <- [1_048_575, 1_048_576] do
      text = String.duplicate("x", size)
      assert Run.cap(text) == text
    end

    for text <- [
          String.duplicate("x", 1_048_577),
          String.duplicate("€", 400_000),
          String.duplicate("🌍", 300_000)
        ] do
      capped = Run.cap(text)
      assert byte_size(capped) <= 1_048_576
      assert String.valid?(capped)
      assert %{"output" => ^capped} = JSON.decode!(JSON.encode!(%{"output" => capped}))
      [head, tail] = String.split(capped, "\n[... cut in the run log ...]\n")
      assert String.starts_with?(text, head)
      assert String.ends_with?(text, tail)
    end
  end
end
