defmodule Kogen.ToolOutputTest do
  use ExUnit.Case, async: true
  alias Kogen.{Shape, Tools}

  test "shared delivery preserves fitting text and bounds oversized text honestly" do
    for size <- [16_383, 16_384, 16_385],
        unit <- ["x", "Δ🙂\r\n\t\"\\\u0000"] do
      text =
        String.duplicate(unit, div(size, byte_size(unit))) <>
          String.duplicate("z", rem(size, byte_size(unit)))

      check(text)
    end

    # Both ends of a byte-selected region can bisect a multibyte character.
    check(String.duplicate("🙂Δ", 90_000))
    check("refused: " <> String.duplicate("large control feedback\n", 2_000))
  end

  test "a numbered single-line custody read is bounded only at delivery" do
    root = Kogen.tmp_path("bounded-read")
    File.mkdir_p!(Path.join(root, ".kogen/local"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, ".gitignore"), ".kogen/local/\n")
    original = JSON.encode!(%{"value" => String.duplicate("x", 514_428)})
    assert byte_size(original) == 514_440
    path = Path.join(root, ".kogen/local/archive.json")
    File.write!(path, original)
    ctx = %{root: root, tools: ["read_file"], protected: []}
    result = Tools.run("read_file", %{"path" => path, "start_line" => 1, "end_line" => 35}, ctx)
    assert result == "1\t" <> original
    check(result)
    assert File.read!(path) == original
  end

  defp check(text) do
    output = Shape.output(%{"call_id" => "exact-call"}, text)
    assert output["type"] == "function_call_output"
    assert output["call_id"] == "exact-call"
    display = output["output"]
    assert display == Tools.cut(text)
    assert String.valid?(display)
    assert byte_size(display) <= 16_384
    assert Shape.output(%{"call_id" => "exact-call"}, display) == output

    if byte_size(text) <= 16_384 do
      assert display == text
    else
      [head, omitted, tail] =
        Regex.run(~r/\A(.*)\n\[\.\.\. (\d+) bytes omitted \.\.\.\]\n(.*)\z/s, display,
          capture: :all_but_first
        )

      assert String.starts_with?(text, head)
      assert String.ends_with?(text, tail)
      assert byte_size(head) in 4093..4096
      assert String.to_integer(omitted) == byte_size(text) - byte_size(head) - byte_size(tail)
    end
  end
end
