defmodule Kogen.Mix.Tasks.Kogen.GuardTest do
  use Kogen.Testkit.Case

  alias Mix.Tasks.Kogen.Guard

  test "lists source violations by file and line", %{tmp_dir: tmp_dir} do
    root = fixture_root(tmp_dir)

    markers = [
      ["credo:", "disable"],
      ["@", "dialyzer"],
      ["@compile ", "{:nowarn"],
      ["exports:", " :all"],
      ["dirty_", "xrefs"],
      ["check:", " [in: false"],
      ["check:", " [out: false"]
    ]

    content = Enum.map_join(markers, "\n", &Enum.join/1)
    File.write!(Path.join(root, "lib/violations.ex"), content)

    issues = Guard.violations(root)

    assert length(issues) == length(markers)

    for line <- 1..length(markers) do
      assert Enum.any?(issues, &String.starts_with?(&1, "lib/violations.ex:#{line}:"))
    end
  end

  test "finds prohibited names, shell files, and Makefile suppression", %{tmp_dir: tmp_dir} do
    root = fixture_root(tmp_dir)
    File.write!(Path.join(root, "AGENTS" <> ".md"), "text")
    File.write!(Path.join(root, "CLAUDE" <> ".md"), "text")
    File.write!(Path.join(root, "guard" <> ".sh"), "text")
    File.write!(Path.join(root, "Makefile"), String.duplicate("|", 2) <> " true\n")

    issues = Guard.violations(root)

    assert Enum.any?(issues, &String.starts_with?(&1, "AGENTS.md:1:"))
    assert Enum.any?(issues, &String.starts_with?(&1, "CLAUDE.md:1:"))
    assert Enum.any?(issues, &String.starts_with?(&1, "guard.sh:1:"))
    assert Enum.any?(issues, &String.starts_with?(&1, "Makefile:1:"))
  end

  defp fixture_root(tmp_dir) do
    root = Path.join(tmp_dir, "guard-project")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "Makefile"), "check:\n\ttrue\n")
    root
  end
end
