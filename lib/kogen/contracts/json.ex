defmodule Kogen.Contracts.JSON do
  @moduledoc """
  Decodes JSON values with consistent errors across Kogen domains.

  Duplicate object keys are accepted; the last value for a key wins.
  Non-whitespace trailing bytes after a complete value are rejected and reported by byte count.
  """

  @spec decode(term()) :: {:ok, term()} | {:error, {:invalid_json, term()}}
  def decode(binary) when is_binary(binary) do
    case :json.decode(binary, nil, decoders()) do
      {value, _outer, <<>>} ->
        {:ok, value}

      {_value, _outer, trailing} ->
        {:error, {:invalid_json, {:trailing_data, byte_size(trailing)}}}
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_json, error}}
  catch
    :error, :unexpected_end -> {:error, {:invalid_json, :unexpected_end}}
    :error, {:invalid_byte, _byte} = detail -> {:error, {:invalid_json, detail}}
    :error, {:unexpected_sequence, _bytes} = detail -> {:error, {:invalid_json, detail}}
  end

  def decode(_value), do: {:error, {:invalid_json, :expected_binary}}

  defp decoders do
    %{
      object_start: fn _outer -> %{} end,
      object_push: fn key, value, object -> Map.put(object, key, value) end,
      object_finish: fn object, outer -> {object, outer} end
    }
  end
end
