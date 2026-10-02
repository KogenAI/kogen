defmodule KogenChecks.Check.StringKeyAccessTest do
  use Credo.Test.Case

  alias Kogen.State.Json
  alias KogenChecks.Check.StringKeyAccess

  test "flags string access, map functions, paths, and map literals" do
    """
    defmodule X do
      def read(map), do: {map["status"], Map.get(map, "tree"), get_in(map, ["a", "b"]), %{"kind" => :x}}
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(StringKeyAccess)
    |> assert_issues(fn issues -> assert length(issues) == 4 end)
  end

  test "allows string keys in a configured codec module" do
    "defmodule Kogen.State.Json do\n  def read(map), do: map[\"status\"]\nend\n"
    |> to_source_file("lib/kogen/state/json.ex")
    |> run_check(StringKeyAccess, codec_modules: [Json])
    |> refute_issues()
  end

  test "exempts only the listed module when a file defines multiple modules" do
    """
    defmodule Kogen.State.Json do
      def read(map), do: map["wire"]
    end

    defmodule Kogen.State.Consumer do
      def read(map), do: map["internal"]
    end
    """
    |> to_source_file("lib/kogen/state/mixed.ex")
    |> run_check(StringKeyAccess, codec_modules: [Json])
    |> assert_issue(fn issue -> assert issue.trigger == "map[\"internal\"]" end)
  end

  test "allows atom keys and requires exact codec names" do
    "defmodule Kogen.State.Json.Encoder do\n  def read(map), do: map[\"status\"]\nend\n"
    |> to_source_file("lib/kogen/state/json_encoder.ex")
    |> run_check(StringKeyAccess, codec_modules: [Json])
    |> assert_issue()

    "defmodule X do\n  def read(map), do: {map[:status], Map.get(map, :tree), %{kind: :x}}\nend\n"
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(StringKeyAccess)
    |> refute_issues()
  end

  test "does not scan files outside lib" do
    "defmodule XTest do\n  def read(map), do: map[\"status\"]\nend\n"
    |> to_source_file("test/build/x_test.exs")
    |> run_check(StringKeyAccess)
    |> refute_issues()
  end
end
