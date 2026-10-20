defmodule Kogen.BuildContextTest do
  use ExUnit.Case, async: true
  alias Kogen.BuildContext

  defp data(text),
    do: %{
      "text" => text,
      "source_path" => "/inaccessible/label",
      "sha256" => Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    }

  test "bounded original UTF-8 bytes and exact text" do
    for size <- [1, 262_143, 262_144] do
      value = data(String.duplicate("x", size))
      assert BuildContext.validate!(value) == value
    end

    value = data("  Δ🙂\r\ntrailing\n ")
    assert BuildContext.validate!(value) == value
    assert BuildContext.validate!(data(String.duplicate("é", 131_072)))

    for text <- [
          "",
          " \t\r\n\u00a0",
          <<255>>,
          String.duplicate("x", 262_145),
          String.duplicate("é", 131_073)
        ] do
      assert_raise Kogen.Error, ~r/intent\/context_unavailable/, fn ->
        BuildContext.validate!(data(text))
      end
    end
  end

  test "exact shape and digest independently of the source filesystem" do
    value = data("valid")

    for invalid <- [
          nil,
          [],
          "text",
          Map.delete(value, "text"),
          Map.put(value, "extra", "x"),
          Map.put(value, "text", 1),
          Map.put(value, "sha256", String.duplicate("0", 64)),
          Map.put(value, "source_path", ""),
          Map.put(value, "source_path", "relative"),
          Map.put(value, "source_path", "/" <> <<255>>),
          Map.put(value, "sha256", <<255>>)
        ] do
      assert_raise Kogen.Error, fn -> BuildContext.validate!(invalid) end
    end

    assert BuildContext.validate!(value) == value
  end
end
