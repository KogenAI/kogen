defmodule Kogen.State.Serialization do
  @moduledoc false

  @spec encode(term()) :: {:ok, binary()} | {:error, :invalid_json_value}
  def encode(value) do
    with {:ok, normalized} <- normalize(value) do
      {:ok, normalized |> :json.encode() |> IO.iodata_to_binary()}
    end
  rescue
    ArgumentError -> {:error, :invalid_json_value}
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, :invalid_json}
  def decode(binary) when is_binary(binary) do
    case :json.decode(binary) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, :invalid_json}
    end
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp normalize(nil), do: {:ok, :null}
  defp normalize(true), do: {:ok, true}
  defp normalize(false), do: {:ok, false}
  defp normalize(value) when is_integer(value) or is_float(value), do: {:ok, value}
  defp normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp normalize(value) when is_binary(value) do
    if String.valid?(value) do
      {:ok, value}
    else
      {:ok, %{"base64" => Base.encode64(value)}}
    end
  end

  defp normalize(value) when is_list(value), do: normalize_list(value, [])

  defp normalize(value) when is_tuple(value) do
    with {:ok, items} <- normalize(Tuple.to_list(value)) do
      {:ok, %{"tuple" => items}}
    end
  end

  defp normalize(value) when is_struct(value), do: value |> Map.from_struct() |> normalize()

  defp normalize(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, result} ->
      with {:ok, json_key} <- normalize_key(key),
           {:ok, json_item} <- normalize(item) do
        {:cont, {:ok, Map.put(result, json_key, json_item)}}
      else
        :error -> {:halt, {:error, :invalid_json_value}}
      end
    end)
  end

  defp normalize(_value), do: {:error, :invalid_json_value}

  defp normalize_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_list([value | rest], acc) do
    case normalize(value) do
      {:ok, normalized} -> normalize_list(rest, [normalized | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(_key), do: :error
end
