defmodule Kogen.Provider.ChatGPT.HostId do
  @moduledoc false

  import Bitwise

  alias Kogen.Contracts.JSON
  alias Kogen.Provider.ChatGPT.FileStore
  alias Kogen.Provider.ChatGPT.Lock

  @spec get_or_create(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def get_or_create(root) when is_binary(root) do
    case read(root) do
      {:ok, host_id} -> {:ok, host_id}
      {:error, :enoent} -> create(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(root) do
    case Lock.with_lock(root, "host-id", fn -> create_locked(root) end) do
      {:ok, {:ok, host_id}} -> {:ok, host_id}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_locked(root) do
    case read(root) do
      {:ok, host_id} ->
        {:ok, host_id}

      {:error, :enoent} ->
        host_id = uuid_uri()
        contents = %{"ext_agent_host_id" => host_id} |> :json.encode() |> IO.iodata_to_binary()

        case FileStore.atomic_write(Path.join(root, "host.json"), contents) do
          :ok -> {:ok, host_id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read(root) do
    case File.read(Path.join(root, "host.json")) do
      {:ok, contents} ->
        with {:ok, %{"ext_agent_host_id" => host_id}} when is_binary(host_id) <-
               JSON.decode(contents),
             true <- String.starts_with?(host_id, "urn:uuid:") do
          {:ok, host_id}
        else
          _invalid -> {:error, :invalid_host_id}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp uuid_uri do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    groups = [
      {a, 8},
      {b, 4},
      {c, 4},
      {d, 4},
      {e, 12}
    ]

    "urn:uuid:" <>
      Enum.map_join(groups, "-", fn {value, width} ->
        value |> Integer.to_string(16) |> String.pad_leading(width, "0")
      end)
  end
end
