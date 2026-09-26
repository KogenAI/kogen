defmodule Kogen.ProjectScope do
  @moduledoc """
  The canonical checkout path that keys every project scope: login selectors
  (`Kogen.ClaudeCode`, `Kogen.Codex`) and the Build workspaces root
  (`Kogen.Build.Workspace`). A symlinked spelling of a checkout and its
  physical path give one canonical path, so one project id.

  A leaf boundary: it depends on nothing else in Kogen.
  """
  use Boundary, deps: []

  @doc """
  The symlink-resolved form of a path: the realpath of its nearest existing
  ancestor with the missing tail appended, so a path that does not exist yet
  already has the canonical form it will have once created.
  """
  @spec canonical(Path.t()) :: Path.t()
  def canonical(path) do
    expanded = Path.expand(path)
    {existing, tail} = split_existing(expanded, [])

    case System.cmd("/bin/realpath", [existing], stderr_to_stdout: true) do
      {out, 0} -> Path.join([String.trim_trailing(out, "\n") | tail])
      _ -> expanded
    end
  rescue
    _ -> Path.expand(path)
  end

  defp split_existing(path, tail) do
    parent = Path.dirname(path)

    if File.exists?(path) or parent == path,
      do: {path, tail},
      else: split_existing(parent, [Path.basename(path) | tail])
  end
end
