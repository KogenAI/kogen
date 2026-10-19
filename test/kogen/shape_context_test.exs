defmodule Kogen.ShapeContextTest do
  use ExUnit.Case, async: true
  alias Kogen.ShapeContext

  test "explicit windows preserve adjacent line and UTF-8 byte bounds" do
    for count <- [79, 80, 81] do
      bytes = Enum.map_join(1..count, "\n", &"line #{&1}")
      {header, body} = render(bytes)
      assert header["start_line"] == 1
      assert header["end_line"] == min(count, 80)

      assert body ==
               bytes |> String.split("\n") |> Enum.take(80) |> Enum.map_join("", &(&1 <> "\n"))
    end

    for size <- [8191, 8192, 8193] do
      # Includes a multibyte codepoint; size includes the rendered newline.
      line = "é" <> String.duplicate("x", size - 3)
      {header, body} = render(line)
      assert byte_size(body) <= 8192
      assert String.valid?(body)
      assert body == if(size <= 8192, do: line <> "\n", else: "")
      assert header["end_line"] == if(size <= 8192, do: 1, else: 0)
    end
  end

  test "explicit windows do not invent a line after the source final newline" do
    for {bytes, expected, count} <- [
          {"", "", 0},
          {"one", "one\n", 1},
          {"one\n", "one\n", 1},
          {"\n", "\n", 1},
          {"one\n\n", "one\n\n", 2}
        ] do
      {header, body} = render(bytes)
      assert body == expected
      assert header["start_line"] == 1
      assert header["end_line"] == count
    end
  end

  defp render(bytes) do
    entry = %{
      path: "literal/é.txt",
      sha256: ShapeContext.hash(bytes),
      bytes: byte_size(bytes),
      signatures: [],
      ownership: "source"
    }

    [header, body] = ShapeContext.excerpt(entry, bytes, []) |> String.split("\n", parts: 2)
    header = header |> String.replace_prefix("Excerpt: ", "") |> JSON.decode!()
    assert Enum.sort(Map.keys(header)) == ~w(end_line path sha256 start_line)
    assert header["sha256"] == ShapeContext.hash(bytes)
    {header, body}
  end
end
