defmodule Kogen.Checks.LedgerCodec do
  @moduledoc false

  alias Kogen.Checks.LedgerRow

  @row ~r/^\{"tag":"((?:\\.|[^"\\])*)","test":"((?:\\.|[^"\\])*)","status":"(passed|failed|skipped|excluded|invalid)"\}$/

  @spec encode(LedgerRow.t()) :: binary()
  def encode(%LedgerRow{} = row) do
    "{\"tag\":#{string(row.tag)},\"test\":#{string(row.test)},\"status\":\"#{row.status}\"}"
  end

  @spec decode(binary()) :: {:ok, LedgerRow.t()} | {:error, :invalid_row}
  def decode(line) do
    case Regex.run(@row, line) do
      [_, tag, test, status] ->
        {:ok,
         %LedgerRow{
           tag: unescape(tag),
           test: unescape(test),
           status: status_atom(status)
         }}

      _ ->
        {:error, :invalid_row}
    end
  end

  defp status_atom("passed"), do: :passed
  defp status_atom("failed"), do: :failed
  defp status_atom("skipped"), do: :skipped
  defp status_atom("excluded"), do: :excluded
  defp status_atom("invalid"), do: :invalid

  defp string(binary), do: "\"" <> (binary |> String.to_charlist() |> escape()) <> "\""

  defp escape(characters) do
    Enum.map_join(characters, &escape_character/1)
  end

  defp escape_character(?\"), do: "\\\""
  defp escape_character(?\\), do: "\\\\"
  defp escape_character(?\n), do: "\\n"
  defp escape_character(?\r), do: "\\r"
  defp escape_character(?\t), do: "\\t"
  defp escape_character(?\b), do: "\\b"
  defp escape_character(?\f), do: "\\f"

  defp escape_character(codepoint) when codepoint < 0x20 do
    "\\u" <> (codepoint |> Integer.to_string(16) |> String.pad_leading(4, "0"))
  end

  defp escape_character(codepoint), do: <<codepoint::utf8>>

  defp unescape(binary), do: binary |> String.to_charlist() |> unescape([])
  defp unescape([], reversed), do: reversed |> Enum.reverse() |> List.to_string()
  defp unescape([?\\, ?\" | rest], reversed), do: unescape(rest, [?\" | reversed])
  defp unescape([?\\, ?\\ | rest], reversed), do: unescape(rest, [?\\ | reversed])
  defp unescape([?\\, ?/ | rest], reversed), do: unescape(rest, [?/ | reversed])
  defp unescape([?\\, ?n | rest], reversed), do: unescape(rest, [?\n | reversed])
  defp unescape([?\\, ?r | rest], reversed), do: unescape(rest, [?\r | reversed])
  defp unescape([?\\, ?t | rest], reversed), do: unescape(rest, [?\t | reversed])
  defp unescape([?\\, ?b | rest], reversed), do: unescape(rest, [?\b | reversed])
  defp unescape([?\\, ?f | rest], reversed), do: unescape(rest, [?\f | reversed])

  defp unescape([?\\, ?u, a, b, c, d | rest], reversed) do
    codepoint = String.to_integer(List.to_string([a, b, c, d]), 16)
    unescape(rest, [codepoint | reversed])
  end

  defp unescape([character | rest], reversed), do: unescape(rest, [character | reversed])
end
