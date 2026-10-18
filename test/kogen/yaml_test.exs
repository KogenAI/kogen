defmodule Kogen.YamlTest do
  use ExUnit.Case, async: true

  alias Kogen.Yaml

  test "SET-4 / SET-8: block command scalars preserve commas and YAML source lines" do
    assert {:ok, {:map, 1, pairs}} =
             Yaml.parse("""
             version: 1
             commands:
               checks:
                 - name: test
                   run: python3 -c "print(1, 2)"
             """)

    assert {"commands", 2, {:map, 3, command_pairs}} = Enum.at(pairs, 1)
    assert {"checks", 3, {:seq, 4, [check]}} = hd(command_pairs)
    assert {:map, 4, check_pairs} = check

    assert {"run", 5, {:scalar, 5, "python3 -c \"print(1, 2)\"", :plain}} =
             List.keyfind(check_pairs, "run", 0)
  end

  test "SET-4: a duplicate YAML key reports the line where it is repeated" do
    assert {:error, [{5, "duplicate key run"}]} =
             Yaml.parse("""
             version: 1
             commands:
               acceptance:
                 run: first
                 run: second
             """)
  end
end
