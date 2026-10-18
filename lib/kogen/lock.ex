defmodule Kogen.Lock do
  @moduledoc """
  A nonempty lock directory, published atomically with a unique owner file holding the PID.
  Recovery removes only the observed owner's file: rmdir cannot remove a new owner's nonempty
  directory. Old PID-file locks remain readable and are replaced when their owner is gone.
  """

  @doc "Takes the lock: `:ok`, `{:removed_stale, pid}` after removing a dead owner's lock, or `{:held, pid}`."
  def acquire(path) do
    File.mkdir_p!(Path.dirname(path))
    token = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    tmp = path <> "." <> token
    File.mkdir!(tmp)
    File.write!(Path.join(tmp, token), System.pid() <> "\n")

    try do
      take(path, tmp, token, :ok)
    after
      File.rm(Path.join(tmp, token))
      File.rmdir(tmp)
    end
  end

  defp take(path, tmp, token, result) do
    case File.rename(tmp, path) do
      :ok ->
        Process.put({__MODULE__, path}, token)
        result

      {:error, reason} when reason in [:eexist, :enotempty, :enotdir, :eisdir] ->
        case owner(path) do
          {:ok, file, pid} ->
            if alive?(pid) do
              {:held, pid}
            else
              # Never recursively delete: another contender may already have acquired it.
              File.rm(file)
              File.rmdir(path)
              take(path, tmp, token, {:removed_stale, pid})
            end

          :retry ->
            take(path, tmp, token, result)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "acquire lock", path: path
    end
  end

  defp owner(path) do
    case File.ls(path) do
      {:ok, [token]} -> read_owner(Path.join(path, token))
      {:error, :enotdir} -> read_owner(path)
      {:ok, []} -> :retry
      {:error, :enoent} -> :retry
      {:error, reason} -> raise File.Error, reason: reason, action: "read lock", path: path
    end
  end

  defp read_owner(file) do
    case File.read(file) do
      {:ok, pid} -> {:ok, file, String.trim(pid)}
      {:error, reason} when reason in [:enoent, :enotdir, :eisdir] -> :retry
      {:error, reason} -> raise File.Error, reason: reason, action: "read lock", path: file
    end
  end

  def release(path) do
    if token = Process.delete({__MODULE__, path}) do
      File.rm(Path.join(path, token))
      File.rmdir(path)
    end

    :ok
  end

  defp alive?(""), do: false
  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
end
