defmodule Kogen.ShapingAudit.Package do
  @moduledoc """
  Locates a Draft or Approved package by slug and reads it under a strict
  `lstat` walk: a symlink, FIFO, device or any other non-regular entry is
  refused, named, before anything is read. The revision is a SHA-256 over
  the package's sorted relative paths and bytes.
  """

  @drafts_dir ".kogen/intents/drafts"
  @approved_dir ".kogen/intents/approved"

  @doc """
  Finds `slug` under `drafts/` or `approved/`. Refuses (without touching
  file contents) when the slug is in both, or in neither.
  """
  @spec locate(Path.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:ambiguous | :not_found, String.t()}}
  def locate(root, slug) do
    draft_rel = Path.join(@drafts_dir, slug)
    approved_rel = Path.join(@approved_dir, slug)
    draft = package_entry(root, draft_rel)
    approved = package_entry(root, approved_rel)

    cond do
      non_regular?(draft) ->
        {:error, {:non_regular, draft_rel}}

      non_regular?(approved) ->
        {:error, {:non_regular, approved_rel}}

      draft == :directory and approved == :directory ->
        {:error,
         {:ambiguous, "slug #{inspect(slug)} exists in both drafts/ and approved/: refusing"}}

      draft == :directory ->
        {:ok, draft_rel}

      approved == :directory ->
        {:ok, approved_rel}

      true ->
        {:error, {:not_found, "no package #{inspect(slug)} under drafts/ or approved/"}}
    end
  end

  defp package_entry(root, relative) do
    case File.lstat(Path.join(root, relative)) do
      {:ok, %File.Stat{type: :directory}} -> :directory
      {:ok, _stat} -> :non_regular
      {:error, :enoent} -> :missing
      {:error, _reason} -> :non_regular
    end
  end

  defp non_regular?(:non_regular), do: true
  defp non_regular?(_), do: false

  @doc """
  Reads every regular file under `root/package_rel` via `lstat`, refusing a
  non-regular entry before any file is opened. `read` (default
  `&File.read/1`) is called once per regular file, absolute path.

  Returns `{:ok, %{files: %{relative_path => bytes}, revision: sha256hex}}`
  or `{:error, {:non_regular, relative_path}}` / `{:error, {reason, detail}}`.
  """
  @spec load(Path.t(), String.t(), (Path.t() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, %{files: %{String.t() => binary()}, revision: String.t()}}
          | {:error, term()}
  def load(root, package_rel, read \\ &File.read/1) do
    dir = Path.join(root, package_rel)

    with {:ok, relative_paths} <- lstat_walk(dir),
         {:ok, files} <- read_all(dir, relative_paths, read) do
      {:ok, %{files: files, revision: revision(files)}}
    end
  end

  @doc "SHA-256 hex over the package's sorted relative paths and bytes."
  @spec revision(%{String.t() => binary()}) :: String.t()
  def revision(files) do
    files
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, state ->
      state
      |> :crypto.hash_update(path)
      |> :crypto.hash_update(<<0>>)
      |> :crypto.hash_update(Map.fetch!(files, path))
      |> :crypto.hash_update(<<0>>)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp lstat_walk(dir) do
    case lstat_walk(dir, dir, []) do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp lstat_walk(root_dir, dir, acc) do
    case File.ls(dir) do
      {:ok, names} -> walk_names(root_dir, dir, Enum.sort(names), acc)
      {:error, reason} -> {:error, {:ls, Path.relative_to(dir, root_dir), reason}}
    end
  end

  defp walk_names(_root_dir, _dir, [], acc), do: {:ok, acc}

  defp walk_names(root_dir, dir, [name | rest], acc) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case lstat_walk(root_dir, path, acc) do
          {:ok, acc} -> walk_names(root_dir, dir, rest, acc)
          error -> error
        end

      {:ok, %File.Stat{type: :regular}} ->
        walk_names(root_dir, dir, rest, [Path.relative_to(path, root_dir) | acc])

      {:ok, _other} ->
        {:error, {:non_regular, Path.relative_to(path, root_dir)}}

      {:error, reason} ->
        {:error, {:lstat, Path.relative_to(path, root_dir), reason}}
    end
  end

  defp read_all(dir, relative_paths, read) do
    Enum.reduce_while(relative_paths, {:ok, %{}}, fn rel, {:ok, acc} ->
      case read.(Path.join(dir, rel)) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, rel, bytes)}}
        {:error, reason} -> {:halt, {:error, {:read, rel, reason}}}
      end
    end)
  end
end
