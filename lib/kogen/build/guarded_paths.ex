defmodule Kogen.Build.GuardedPaths do
  @moduledoc "Controller-memory snapshot used to reject Candidate topology outside Approved guards."

  @volatile ~w(.kogen/runtime .kogen/build.lock .kogen/codex .codex/sessions _build deps cover .elixir_ls)

  def capture(root \\ File.cwd!()) do
    with {:ok, head} <- git(root, ["rev-parse", "HEAD^{tree}"]),
         {:ok, config} <-
           snapshot_files(root, [".git/config", ".git/info/exclude", ".gitmodules", ".gitignore"]),
         {:ok, ignored} <- ignored_manifest(root) do
      {:ok,
       %{root: Path.expand(root), head_tree: String.trim(head), config: config, ignored: ignored}}
    end
  end

  def check(snapshot, guards) when is_map(snapshot) and is_list(guards) do
    with {:ok, config} <- snapshot_files(snapshot.root, Map.keys(snapshot.config)),
         :ok <- same_config(config, snapshot.config),
         {:ok, paths} <- changed_paths(snapshot.root, snapshot.head_tree, snapshot.ignored),
         invalid <- Enum.reject(paths, &allowed?(&1, guards)),
         :ok <- no_invalid(invalid) do
      :ok
    else
      {:error, _} = error ->
        error
    end
  end

  defp same_config(value, value), do: :ok

  defp same_config(_, _),
    do: {:error, "Git configuration or ignore policy changed during Developer turn"}

  defp no_invalid([]), do: :ok

  defp no_invalid(paths),
    do: {:error, "Candidate changed paths outside Approved guards: #{Enum.join(paths, ", ")}"}

  defp changed_paths(root, tree, frozen_ignored) do
    args = [
      "-c",
      "diff.external=",
      "-c",
      "diff.trustExitCode=false",
      "-c",
      "core.fsmonitor=false",
      "diff",
      "--raw",
      "-z",
      "--no-renames",
      tree,
      "--"
    ]

    with {:ok, raw} <- git(root, args),
         {:ok, untracked} <- git(root, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, ignored} <- ignored_manifest(root) do
      tracked = raw |> String.split(<<0>>, trim: true) |> raw_paths()

      ignored_changes =
        (Map.keys(ignored) ++ Map.keys(frozen_ignored))
        |> Enum.uniq()
        |> Enum.filter(&(ignored[&1] != frozen_ignored[&1]))

      extras = String.split(untracked, <<0>>, trim: true) ++ ignored_changes
      {:ok, (tracked ++ extras) |> Enum.reject(&volatile?/1) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp raw_paths(entries),
    do:
      entries
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        [_metadata, path] -> [path]
        _ -> []
      end)

  # credo:disable-for-lines:38 Credo.Check.Refactor.Nesting
  defp ignored_manifest(root) do
    with {:ok, output} <-
           git(root, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]) do
      output
      |> String.split(<<0>>, trim: true)
      |> Enum.reject(&volatile?/1)
      |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
        full = Path.join(root, path)

        case File.lstat(full) do
          {:ok, %{type: :regular, mode: mode}} ->
            case File.read(full) do
              {:ok, bytes} ->
                {:cont, {:ok, Map.put(acc, path, {mode, :crypto.hash(:sha256, bytes)})}}

              {:error, reason} ->
                {:halt, {:error, "could not read ignored path #{path}: #{inspect(reason)}"}}
            end

          {:ok, %{type: :symlink, mode: mode}} ->
            {:cont, {:ok, Map.put(acc, path, {mode, File.read_link!(full)})}}

          {:ok, _} ->
            {:cont, {:ok, acc}}

          {:error, :enoent} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, "could not inspect ignored path #{path}: #{inspect(reason)}"}}
        end
      end)
    end
  end

  defp snapshot_files(root, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      full = Path.join(root, path)

      value =
        case File.read(full) do
          {:ok, bytes} -> {:file, bytes}
          {:error, :enoent} -> :missing
          {:error, reason} -> {:error, reason}
        end

      case value do
        {:error, reason} -> {:halt, {:error, "could not snapshot #{path}: #{inspect(reason)}"}}
        _ -> {:cont, {:ok, Map.put(acc, path, value)}}
      end
    end)
  end

  defp allowed?(path, guards), do: Enum.any?(guards, &matches?(path, &1))

  defp matches?(path, guard) do
    regex =
      guard |> Regex.escape() |> String.replace("\\*\\*", ".*") |> String.replace("\\*", "[^/]*")

    Regex.match?(Regex.compile!("^" <> regex <> "$"), path)
  end

  defp volatile?(path),
    do:
      path in ["erl_crash.dump", ".DS_Store"] or
        Enum.any?(@volatile, &(path == &1 or String.starts_with?(path, &1 <> "/"))) or
        String.contains?(path, "__pycache__")

  defp git(root, args) do
    # Repository configuration is an admitted input, not authority to hide a
    # mode-only Candidate change. Force mode comparison for every query used
    # to construct or compare the frozen topology.
    args = ["-c", "core.filemode=true" | args]

    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
