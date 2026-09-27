defmodule Kogen.ShapingAudit.Questions do
  @moduledoc """
  Parses the slice-1 `## Dispositions` section of a questions document.

  Slice 1 has no question state machine. Only lines declaring a `not a defect`
  disposition are retained; all other sections and lines are ignored.
  """

  @spec parse(binary() | nil) :: %{dispositions: %{String.t() => map()}}
  def parse(nil), do: %{dispositions: %{}}

  def parse(text) when is_binary(text) do
    %{dispositions: parse_dispositions(text)}
  end

  def parse(_), do: %{dispositions: %{}}

  defp parse_dispositions(text) do
    text
    |> disposition_lines()
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_line(line) do
        {:ok, id, reason} -> Map.put(acc, id, %{"kind" => "not-a-defect", "reason" => reason})
        :ignore -> acc
      end
    end)
  end

  defp disposition_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({false, []}, fn line, {inside?, lines} ->
      trimmed = String.trim(line)

      cond do
        Regex.match?(~r/^##\s+Dispositions\s*$/i, trimmed) ->
          {true, lines}

        inside? and String.starts_with?(trimmed, "##") ->
          {false, lines}

        inside? ->
          {true, [line | lines]}

        true ->
          {false, lines}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp parse_line(line) do
    line = String.trim(line)
    line = if String.starts_with?(line, "- "), do: String.trim_leading(line, "- "), else: line

    case Regex.run(~r/^`?(.*?)`?\s*:\s*not\s+a\s+defect\s*(?:—|--|-)\s*(.+?)\s*$/iu, line) do
      [_, id, reason] ->
        id = String.trim(id)
        reason = String.trim(reason)
        if id != "" and reason != "", do: {:ok, id, reason}, else: :ignore

      _ ->
        :ignore
    end
  end
end
