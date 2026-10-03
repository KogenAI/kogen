defmodule Kogen.Kernel.WorkspacesTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.Workspaces

  test "workspace key is readable, stable, and distinguishes checkout paths", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "careful-rebuild")
    home = Path.join(tmp_dir, "home")
    root = Workspaces.root(project, home)
    digest = :sha256 |> :crypto.hash(Path.expand(project)) |> Base.encode16(case: :lower)

    assert root ==
             Path.join([
               home,
               ".kogen",
               "workspaces",
               "careful-rebuild-#{binary_part(digest, 0, 10)}"
             ])

    assert Workspaces.root(project, home) == root
    refute Workspaces.root(Path.join(tmp_dir, "other"), home) == root
  end
end
