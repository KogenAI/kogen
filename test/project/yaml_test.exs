defmodule Kogen.Project.YamlTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Yaml

  test "parses nested block and flow collections with string-only scalars" do
    source = """
    name: demo # inline comment
    number: 010
    flags: [true, 1.10, "# remains text"]
    checks:
      - name: unit
        argv: [mix, test]
        timeout_ms: 1200
    limits: {soft: low, hard: high}
    """

    assert {:ok, document} = Yaml.parse(source)
    assert document["number"] == "010"
    assert document["flags"] == ["true", "1.10", "# remains text"]

    assert document["checks"] == [
             %{"name" => "unit", "argv" => ["mix", "test"], "timeout_ms" => "1200"}
           ]

    assert document["limits"] == %{"soft" => "low", "hard" => "high"}
  end

  test "parses root scalars, lists, comments, and multiline flow values" do
    assert {:ok, "true"} = Yaml.parse("true # scalar text\n")
    assert {:ok, ["first", "second"]} = Yaml.parse("- first\n- second\n")
    assert {:ok, %{"value" => ["one", "two"]}} = Yaml.parse("value: [one,\n  two]\n")
  end

  test "parses quoted block and flow keys containing colons" do
    assert {:ok, %{"a:b" => "block", "nested:key" => %{"flow:key" => "value"}}} =
             Yaml.parse(~s("a:b": block\n"nested:key":\n  'flow:key': value\n))

    assert {:ok, %{"a:b" => "flow"}} = Yaml.parse("{\"a:b\": flow}\n")
  end

  test "rejects a leading BOM, Unicode escapes, merge keys, excess depth, and oversized documents" do
    assert {:error, [%{line: 1, message: message}]} =
             Yaml.parse(<<0xEF, 0xBB, 0xBF>> <> "value: one\n")

    assert message =~ "BOM"

    assert {:error, [%{line: 1, message: message}]} = Yaml.parse(~S(value: "\u0041"))
    assert message =~ "Unicode escape \\u"

    for source <- ["<<: {base: shared}\n", "{<<: {base: shared}}\n"] do
      assert {:error, [%{line: 1, message: message}]} = Yaml.parse(source)
      assert message =~ "merge key"
    end

    too_deep = String.duplicate("[", 65) <> "value" <> String.duplicate("]", 65)
    assert {:error, [%{line: 1, message: message}]} = Yaml.parse(too_deep)
    assert message =~ "maximum nesting depth"

    too_deep_block =
      Enum.map_join(0..64, "\n", fn depth ->
        String.duplicate(" ", depth * 2) <> "key#{depth}:"
      end) <>
        "\n" <> String.duplicate(" ", 130) <> "value"

    assert {:error, [%{line: 65, message: message}]} = Yaml.parse(too_deep_block)
    assert message =~ "maximum nesting depth"

    too_large = String.duplicate("x", 1_048_577)
    assert {:error, [%{line: 1, message: message}]} = Yaml.parse(too_large)
    assert message =~ "maximum size"
  end

  @bad_documents [
    {"tabs", "value: ok\n\tbad: value\n", 2, "tab"},
    {"duplicate block keys", "value: first\nvalue: second\n", 2, "duplicate"},
    {"anchors", "value: ok\ncopy: &base thing\n", 2, "anchors"},
    {"aliases", "value: ok\ncopy: *base\n", 2, "aliases"},
    {"tags", "value: ok\ncopy: !custom thing\n", 2, "tags"},
    {"duplicate flow keys", "value: {key: one, key: two}\n", 1, "duplicate"},
    {"bad indentation", "value: ok\n  extra: no\n", 2, "indentation"},
    {"unquoted colon space", "value: not: quoted\n", 1, "unquoted"},
    {"document markers", "---\nvalue: one\n", 1, "markers"}
  ]

  for {name, source, expected_line, message_part} <- @bad_documents do
    test "reports the correct line for #{name}" do
      assert {:error, [%{line: line, message: message}]} = Yaml.parse(unquote(source))
      assert line == unquote(expected_line)
      assert message =~ unquote(message_part)
    end
  end
end
