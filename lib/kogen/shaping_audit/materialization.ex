defmodule Kogen.ShapingAudit.Materialization do
  @moduledoc """
  A private, disposable git work tree the deterministic and auditor layers
  read instead of the checkout: a `git clone --local --no-checkout` of the
  checkout, `HEAD` checked out, and the package files written on top. It is
  never linked back to the checkout and never pushed. `remove/1` always
  deletes it, even after a failure, so a run never leaks a private temp
  directory (see risk `auditor-detection-not-prevention`).
  """

  @doc """
  Creates the materialization: a private 0700 directory under
  `System.tmp_dir!()` (`kogen-audit-*`), a local no-checkout clone of `root`,
  `HEAD` checked out, and `files` (relative path to bytes) written at
  `package_rel` inside it. Returns `{:ok, %{dir: work_dir, base: tmp_base}}`;
  `dir` is the git work tree the audit reads, `base` is the private directory
  `remove/1` deletes.
  """
  @spec create(Path.t(), String.t(), %{String.t() => binary()}) ::
          {:ok, %{dir: Path.t(), base: Path.t()}} | {:error, term()}
  def create(root, package_rel, files) when is_map(files) do
    base =
      Path.join(
        System.tmp_dir!(),
        "kogen-audit-#{:erlang.phash2(self())}-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    work_dir = Path.join(base, "work")

    with :ok <- File.mkdir_p(base),
         :ok <- File.chmod(base, 0o700),
         :ok <- clone(root, work_dir),
         :ok <- checkout_head(work_dir),
         :ok <- write_package(work_dir, package_rel, files) do
      {:ok, %{dir: work_dir, base: base}}
    else
      {:error, reason} ->
        File.rm_rf(base)
        {:error, reason}
    end
  end

  @doc "Removes the materialization's private directory. Always safe, idempotent."
  @spec remove(%{base: Path.t()} | Path.t()) :: :ok
  def remove(%{base: base}), do: remove(base)

  def remove(base) when is_binary(base) do
    File.rm_rf(base)
    :ok
  end

  def remove(_other), do: :ok

  @doc """
  A manifest of every entry under `dir`: entry type, mode and a SHA-256 of
  its bytes without following links (a symlink is hashed by its target
  text), including `.git`'s refs, `HEAD`, index and hooks. Used to detect
  any write during an auditor session.
  """
  @spec manifest(Path.t()) :: %{String.t() => map()}
  def manifest(dir) do
    dir
    |> walk()
    |> Map.new(fn path -> {path, entry(dir, path)} end)
  end

  defp clone(root, work_dir) do
    case System.cmd("git", ["clone", "--local", "--no-checkout", "--quiet", root, work_dir],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, _code} ->
        {:error, "could not clone checkout for materialization: #{String.trim(out)}"}
    end
  end

  defp checkout_head(work_dir) do
    env = [{"GIT_OPTIONAL_LOCKS", "0"}]

    case System.cmd("git", ["checkout", "--quiet", "HEAD"],
           cd: work_dir,
           env: env,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, "could not check out HEAD in materialization: #{String.trim(out)}"}
    end
  end

  defp write_package(work_dir, package_rel, files) do
    Enum.reduce_while(files, :ok, fn {relative, bytes}, :ok ->
      full = Path.join([work_dir, package_rel, relative])

      with :ok <- File.mkdir_p(Path.dirname(full)),
           :ok <- File.write(full, bytes) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, "could not write package file #{relative}: #{inspect(reason)}"}}
      end
    end)
  end

  defp walk(dir) do
    walk(dir, dir, [])
  end

  defp walk(root_dir, dir, acc) do
    case File.ls(dir) do
      {:ok, names} -> Enum.reduce(Enum.sort(names), acc, &walk_entry(root_dir, dir, &1, &2))
      {:error, _reason} -> acc
    end
  end

  defp walk_entry(root_dir, dir, name, acc) do
    path = Path.join(dir, name)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> walk(root_dir, path, acc)
      {:ok, _stat} -> [Path.relative_to(path, root_dir) | acc]
      {:error, _reason} -> acc
    end
  end

  defp entry(dir, relative) do
    full = Path.join(dir, relative)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :symlink, mode: mode}} ->
        %{"type" => "symlink", "mode" => mode, "sha256" => sha256(File.read_link!(full))}

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        %{"type" => "regular", "mode" => mode, "sha256" => sha256(read_bytes(full))}

      {:ok, %File.Stat{type: type, mode: mode}} ->
        %{"type" => to_string(type), "mode" => mode, "sha256" => nil}

      {:error, reason} ->
        %{"type" => "missing", "mode" => nil, "sha256" => nil, "error" => inspect(reason)}
    end
  end

  defp read_bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> ""
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
