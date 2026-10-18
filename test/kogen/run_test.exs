defmodule Kogen.RunTest do
  use ExUnit.Case, async: true
  alias Kogen.Run

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
