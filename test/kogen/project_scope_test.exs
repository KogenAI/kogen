defmodule Kogen.ProjectScopeTest do
  @moduledoc """
  Scenarios `symlinked-spellings-share-one-id` and `real-callers-unchanged`:
  every `project_id/1` (`Kogen.ClaudeCode`, `Kogen.Codex.State`,
  `Kogen.Build.Workspace`) and `Kogen.Build.Workspace.canonical/1` key a
  checkout by its canonical path. A real directory and a `File.ln_s` alias to
  it give one id, equal to the SHA-256 of an independently computed physical
  path (`File.cd!/2` + `File.cwd!/0`, the path login uses, and `/bin/realpath`);
  a not-yet-existing child spelled through either gets the id it keeps once
  created. A plain canonical path keeps today's `Path.expand/1` id.

  `File.cd!/2` changes the VM's cwd, so this runs in `Kogen.IsolatedCase`.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Workspace
  alias Kogen.WorkspaceFixture

  @id_functions [
    {"Kogen.ClaudeCode", &Kogen.ClaudeCode.project_id/1},
    {"Kogen.Codex.State", &Kogen.Codex.State.project_id/1},
    {"Kogen.Build.Workspace", &Workspace.project_id/1}
  ]

  defp sha(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)

  defp realpath(path) do
    {out, 0} = System.cmd("/bin/realpath", [path])
    String.trim_trailing(out, "\n")
  end

  defp assert_ids(spelling, expected_path) do
    for {name, id} <- @id_functions do
      assert id.(spelling) == sha(expected_path),
             "#{name}.project_id(#{inspect(spelling)}) is not sha256(#{inspect(expected_path)})"
    end
  end

  setup do
    base = WorkspaceFixture.tmp_dir!("project-scope")
    on_exit(fn -> File.rm_rf(base) end)

    real = Path.join(base, "real")
    alias_path = Path.join(base, "alias")
    File.mkdir_p!(real)
    :ok = File.ln_s(real, alias_path)

    %{real: real, alias_path: alias_path}
  end

  test "a real checkout and its symlinked alias share one canonical path and id in every module",
       %{real: real, alias_path: alias_path} do
    login_path = File.cd!(alias_path, &File.cwd!/0)
    assert login_path == realpath(alias_path)
    assert login_path == realpath(real)
    refute login_path == Path.expand(alias_path)

    for spelling <- [real, alias_path] do
      assert Workspace.canonical(spelling) == login_path
      assert Kogen.ProjectScope.canonical(spelling) == login_path
      assert_ids(spelling, login_path)
    end
  end

  test "a missing child keeps one canonical path and id through both spellings once created",
       %{real: real, alias_path: alias_path} do
    via_real = Path.join([real, "not", "yet"])
    via_alias = Path.join([alias_path, "not", "yet"])
    refute File.exists?(via_real)

    before =
      for spelling <- [via_real, via_alias] do
        {Workspace.canonical(spelling), Enum.map(@id_functions, fn {_, id} -> id.(spelling) end)}
      end

    File.mkdir_p!(via_alias)
    created = realpath(via_real)
    assert created == File.cd!(via_alias, &File.cwd!/0)
    after_creation = {created, List.duplicate(sha(created), length(@id_functions))}

    assert before == [after_creation, after_creation]

    for spelling <- [via_real, via_alias] do
      assert Workspace.canonical(spelling) == created
      assert_ids(spelling, created)
    end
  end

  test "a plain fixture checkout keeps today's Path.expand id" do
    checkout = WorkspaceFixture.tmp_dir!("project-scope-plain")
    on_exit(fn -> File.rm_rf(checkout) end)

    assert checkout == realpath(checkout)
    assert_ids(checkout, Path.expand(checkout))
    assert Workspace.canonical(checkout) == Path.expand(checkout)
  end
end
