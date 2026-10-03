defmodule Kogen.Engine.Build.Guard do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Workspace

  @spec check(Path.t(), String.t(), Intent.t(), Project.t(), map(), map()) ::
          :ok | {:error, Failure.t()}
  def check(workdir, base_sha, intent, project, manifest, git_env) do
    case Workspace.changed_paths(workdir, base_sha, git_env) do
      {:ok, changed} ->
        protected =
          manifest
          |> Enum.filter(fn {path, sha} ->
            not safe_manifest_path?(path) or file_sha(workdir, path) != sha
          end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        prefixes =
          Enum.flat_map(intent.domains, &Map.get(project.domains, &1, [])) ++
            allowed_extra(intent)

        outside = Enum.reject(changed, &under_prefix?(&1, prefixes))

        cond do
          protected != [] ->
            failure(:protected_edit, "Protected paths changed: #{Enum.join(protected, ", ")}")

          outside != [] ->
            failure(:scope_edit, "Out-of-scope paths changed: #{Enum.join(outside, ", ")}")

          true ->
            :ok
        end

      {:error, reason} ->
        failure(
          :workspace_failed,
          "Cannot inspect protected paths: #{inspect(reason)}",
          :controller
        )
    end
  end

  @spec tree_hash(Path.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def tree_hash(workdir, git_env), do: Workspace.tree_hash(workdir, git_env)

  defp safe_manifest_path?(path),
    do: Path.type(path) == :relative and ".." not in Path.split(path) and path not in ["", "."]

  defp file_sha(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, contents} -> :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp under_prefix?(path, prefixes),
    do:
      Enum.any?(prefixes, fn prefix ->
        path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")
      end)

  defp allowed_extra(%Intent{slug: slug}),
    do: [
      ".kogen/intents/#{slug}"
      | Enum.map([".kogen/acceptance/", "test/acceptance/"], &(&1 <> slug <> "_test.exs"))
    ]

  defp failure(reason, detail, class \\ :candidate),
    do: {:error, %Failure{class: class, reason: reason, detail: detail}}
end
