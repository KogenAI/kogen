defmodule Kogen.Build.BaseWorkspace do
  @moduledoc """
  Controller-owned workspaces outside the repository for proof runs.

  The base workspace is a `git archive` export of the admission commit plus
  copies of the admission catalog's `base_cache` paths (the catalog loader
  already refused controller volatile state such as `.kogen/runtime` or
  `.kogen/build.lock`). The controller records its digest at creation and
  re-checks it before each use, rebuilding it on a mismatch. Runs never
  mutate it: each run works in a scratch copy with only the permitted
  overlay applied. Every run there uses the workspace's own `MIX_BUILD_PATH`
  and working directory, so `priv/` and prompts resolve inside it, never in
  the parent checkout or the controller's application directory.
  """

  @doc """
  Exports `tree` (a commit or tree id) of the repository at `root` into a new
  directory outside it, copies `cache` paths from `root`, and records its
  digest.
  """
  @spec create(Path.t(), String.t(), [String.t()], String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def create(root, tree, cache, label \\ "base") do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-#{label}-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    with :ok <- File.mkdir_p(path),
         :ok <- export(root, tree, path),
         :ok <- copy_cache(root, cache, path) do
      {:ok,
       %{path: path, tree: tree, cache: cache, root: Path.expand(root), digest: digest(path)}}
    else
      {:error, reason} ->
        File.rm_rf(path)
        {:error, "could not build #{label} workspace: #{reason}"}
    end
  end

  @doc "Re-checks a workspace's digest, rebuilding it at a new path on a mismatch."
  @spec ensure(map()) :: {:ok, map(), boolean()} | {:error, String.t()}
  def ensure(workspace) do
    if File.dir?(workspace.path) and digest(workspace.path) == workspace.digest do
      {:ok, workspace, false}
    else
      File.rm_rf(workspace.path)

      with {:ok, rebuilt} <- create(workspace.root, workspace.tree, workspace.cache) do
        {:ok, rebuilt, true}
      end
    end
  end

  @doc """
  Copies `workspace` to a fresh scratch directory and applies `overlays`
  (`{relative_path, bytes}` or `{relative_path, :delete}`).
  """
  @spec scratch(map(), [{String.t(), binary() | :delete}]) ::
          {:ok, Path.t()} | {:error, String.t()}
  def scratch(workspace, overlays) do
    dir = workspace.path <> "-run-" <> Integer.to_string(System.unique_integer([:positive]))

    with {_out, 0} <- System.cmd("cp", ["-R", workspace.path, dir], stderr_to_stdout: true),
         :ok <- apply_overlays(dir, overlays) do
      {:ok, dir}
    else
      {out, code} when is_binary(out) ->
        File.rm_rf(dir)
        {:error, "could not copy workspace (#{code}): #{String.trim(out)}"}

      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  end

  @doc "Environment for a run inside workspace directory `dir`."
  def run_environment(dir),
    do: [
      {"MIX_BUILD_PATH", Path.join([dir, "_build", "test"])},
      {"MIX_ENV", "test"},
      {"MIX_EXS", nil},
      {"MIX_DEPS_PATH", nil}
    ]

  @doc "Removes a workspace."
  def remove(nil), do: :ok

  def remove(%{path: path}) do
    File.rm_rf(path)
    :ok
  end

  @doc """
  Digest over every entry's relative path, type, executable bit and content.
  """
  @spec digest(Path.t()) :: String.t()
  def digest(path) do
    path
    |> entries("")
    |> Enum.sort()
    |> Enum.map_join("\n", fn {relative, kind, value} -> "#{kind}\t#{relative}\t#{value}" end)
    |> then(&Base.encode16(:crypto.hash(:sha256, &1), case: :lower))
  end

  @doc "The sha256 digest of a list of overlays."
  def overlay_digest(overlays) do
    overlays
    |> Enum.sort()
    |> Enum.map_join("\n", fn
      {path, :delete} -> "delete\t#{path}"
      {path, bytes} -> "write\t#{path}\t#{sha256(bytes)}"
    end)
    |> sha256()
  end

  defp entries(root, relative) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.flat_map(&entries(root, Path.join(relative, &1) |> String.trim_leading("/")))

      {:ok, %{type: :regular, mode: mode}} ->
        [{relative, "file#{Bitwise.band(mode, 0o111)}", sha256(File.read!(path))}]

      {:ok, %{type: :symlink}} ->
        [{relative, "link", File.read_link!(path)}]

      _ ->
        [{relative, "other", ""}]
    end
  end

  defp export(root, tree, path) do
    command =
      "git -C #{shell_quote(Path.expand(root))} archive --format=tar #{shell_quote(tree)} | tar -x -C #{shell_quote(path)}"

    case System.cmd("sh", ["-c", "set -o pipefail 2>/dev/null; " <> command],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "git archive failed (#{code}): #{String.trim(out)}"}
    end
  end

  defp copy_cache(root, cache, path) do
    Enum.reduce_while(cache, :ok, fn relative, :ok ->
      case copy_entry(Path.join(root, relative), Path.join(path, relative)) do
        :ok -> {:cont, :ok}
        {:error, out} -> {:halt, {:error, "could not copy base_cache #{relative}: #{out}"}}
      end
    end)
  end

  # An absent cache path is skipped; the base then compiles cold.
  defp copy_entry(source, target) do
    if File.exists?(source) do
      File.mkdir_p!(Path.dirname(target))

      case System.cmd("cp", ["-R", source, target], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, _code} -> {:error, out}
      end
    else
      :ok
    end
  end

  defp apply_overlays(dir, overlays) do
    Enum.reduce_while(overlays, :ok, fn
      {relative, :delete}, :ok ->
        File.rm_rf(Path.join(dir, relative))
        {:cont, :ok}

      {relative, bytes}, :ok ->
        target = Path.join(dir, relative)

        with :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- File.write(target, bytes) do
          {:cont, :ok}
        else
          {:error, reason} ->
            {:halt, {:error, "could not overlay #{relative}: #{inspect(reason)}"}}
        end
    end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
