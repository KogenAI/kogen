defmodule KogenLedgerFormatter do
  @moduledoc false
  use GenServer

  def init(_opts) do
    case System.get_env("KOGEN_LEDGER_REPORT") do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        {:stop, :missing_report_path}
    end
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, path) do
    status = status(test.state)
    tags = intent_tags(test.tags)

    Enum.each(tags, fn tag ->
      row = ledger_row(tag, test_title(test), status)
      :ok = File.write!(path, row <> "\n", [:append, :binary])
    end)

    {:noreply, path}
  end

  def handle_cast(_event, path), do: {:noreply, path}

  # ExUnit.Test gained :description in newer Elixir; target projects may run older versions.
  defp test_title(%{description: description}) when is_binary(description), do: description
  defp test_title(%{name: name}), do: name |> Atom.to_string() |> String.replace_prefix("test ", "")

  defp intent_tags(%{intent: tag}) when is_binary(tag), do: [tag]
  defp intent_tags(%{intent: tags}) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp intent_tags(_tags), do: [""]

  defp status(nil), do: :passed
  defp status({:failed, _}), do: :failed
  defp status({:skipped, _}), do: :skipped
  defp status({:excluded, _}), do: :excluded
  defp status({:invalid, _}), do: :invalid
  defp status(_other), do: :invalid

  defp ledger_row(tag, test, status) do
    "{\"tag\":#{json_string(tag)},\"test\":#{json_string(test)},\"status\":\"#{status}\"}"
  end

  defp json_string(binary), do: "\"" <> (binary |> String.to_charlist() |> escape()) <> "\""
  defp escape(characters), do: Enum.map_join(characters, &escape_character/1)
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
end
