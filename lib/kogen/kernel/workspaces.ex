defmodule Kogen.Kernel.Workspaces do
  @moduledoc false

  @spec root(Path.t(), Path.t()) :: Path.t()
  def root(project_root, home) do
    absolute_project = Path.expand(project_root)
    basename = absolute_project |> Path.basename() |> safe_basename()
    digest = :sha256 |> :crypto.hash(absolute_project) |> Base.encode16(case: :lower)

    Path.join([home, ".kogen", "workspaces", "#{basename}-#{binary_part(digest, 0, 10)}"])
  end

  defp safe_basename(name), do: Regex.replace(~r/[^A-Za-z0-9._-]+/, name, "-")
end
