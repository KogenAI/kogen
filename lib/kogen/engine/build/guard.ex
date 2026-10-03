defmodule Kogen.Engine.Build.Guard do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Engine.Runtime
  alias Kogen.Proc

  @snapshot_script """
  set -eu
  index=$1; trap 'rm -f "$index" "$index.lock"' EXIT
  export GIT_INDEX_FILE="$index"; git read-tree HEAD; git add -A -- .; tree=$(git write-tree)
  if [ -n "$2" ]; then git diff --no-renames --name-only -z "$2" "$tree" > "$3"
  else printf '%s\n' "$tree" > "$3"; fi
  """

  @spec check(Path.t(), String.t(), Intent.t(), Project.t(), map(), map()) ::
          :ok | {:error, Failure.t()}
  def check(workdir, base_sha, intent, project, manifest, git_env) do
    case changed_paths(workdir, base_sha, git_env) do
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
  def tree_hash(workdir, git_env), do: snapshot(workdir, "", git_env, :tree)

  defp changed_paths(workdir, base_sha, git_env), do: snapshot(workdir, base_sha, git_env, :paths)

  defp snapshot(workdir, base_sha, git_env, mode) do
    suffix = "#{System.pid()}-#{System.unique_integer([:positive])}"
    temp_dir = Runtime.temporary_directory(git_env)

    [index, output, log] =
      Enum.map(["index", "output", "log"], &Path.join(temp_dir, "kogen-#{&1}-#{suffix}"))

    result =
      ["/bin/sh", "-c", @snapshot_script, "kogen-snapshot", index, base_sha, output]
      |> Proc.run(cd: workdir, env: git_env, timeout_ms: 120_000, log_path: log)
      |> snapshot_result(output, mode)

    case cleanup_temp_files([index, output, log, index <> ".lock"]) do
      :ok -> result
      {:error, reason} -> {:error, {:temporary_file_cleanup, reason}}
    end
  end

  defp snapshot_result({:ok, %ProcResult{exit_status: 0, timed_out: false}}, path, mode),
    do: read_snapshot(path, if(mode == :tree, do: &String.trim/1, else: &decode_paths/1))

  defp snapshot_result({:ok, %ProcResult{timed_out: true}}, _path, _mode), do: {:error, :timeout}

  defp snapshot_result({:ok, %ProcResult{exit_status: nil}}, _path, _mode),
    do: {:error, :missing_exit_status}

  defp snapshot_result({:ok, %ProcResult{exit_status: status}}, _path, _mode),
    do: {:error, {:git_failed, status}}

  defp snapshot_result({:error, reason}, _path, _mode), do: {:error, reason}

  defp read_snapshot(path, transform) do
    with {:ok, output} <- File.read(path), do: {:ok, transform.(output)}
  end

  defp decode_paths(output),
    do: output |> :binary.split(<<0>>, [:global]) |> Enum.reject(&(&1 == ""))

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

  defp cleanup_temp_files(paths),
    do:
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        case File.rm(path) do
          {:error, reason} when reason != :enoent -> {:halt, {:error, reason}}
          _result -> {:cont, :ok}
        end
      end)

  defp failure(reason, detail, class \\ :candidate),
    do: {:error, %Failure{class: class, reason: reason, detail: detail}}
end
