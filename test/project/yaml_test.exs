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
