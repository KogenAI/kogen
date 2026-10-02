defmodule Kogen.State.FileStore do
  @moduledoc false

  @spec atomic_write(Path.t(), binary()) :: :ok | {:error, term()}
  def atomic_write(path, contents) do
    temporary = "#{path}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    with :ok <- File.write(temporary, contents, [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} = error ->
        _cleanup = File.rm(temporary)
        error
    end
  end

  @spec append_line(Path.t(), binary()) :: :ok | {:error, term()}
  def append_line(path, contents) do
    with {:ok, file} <- File.open(path, [:append, :binary]) do
      IO.binwrite(file, [contents, "\n"])

      case File.close(file) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
