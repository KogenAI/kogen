defmodule Kogen.ShapingAudit.Questions do
  @moduledoc """
  The fixed `questions.md` grammar the Shaping audit reads.

  The audit reads six `##` sections and ignores every other `##` heading
  (approval notes, history):

  - `## Ask the Shaper`: numbered entries, each with `Question:`,
    `Recommendation:` and `Evidence:` (a path under the package's
    `evidence/`, a `path:line`, a quoted decision, or
    `unproven — <what would prove it>`);
  - `## Shaper answers`: the Shaper's words, quoted, with the entry number;
  - `## Left undecided`: open entries that never block;
  - `## Assumed`: each with `Reason:` and `Undo:`;
  - `## Settled`;
  - `## Dispositions`: `<finding id>: fixed — <what changed>` or
    `<finding id>: not a defect — <reason>`.

  An entry starts with `N. ` or `- ` at the start of a line; indented lines
  continue it. Any open `## Ask the Shaper` entry means the session is asking.
  """

  alias Kogen.ShapingAudit.Finding

  @sections [
    "Ask the Shaper",
    "Shaper answers",
    "Left undecided",
    "Assumed",
    "Settled",
    "Dispositions"
  ]
  @fields ~w(Question Recommendation Evidence Reason Undo)
  @field_pattern ~r/(?:^|\s)(Question|Recommendation|Evidence|Reason|Undo):\s*(.*?)(?=\s(?:Question|Recommendation|Evidence|Reason|Undo):|\z)/s
  @disposition_pattern ~r/^(?<id>.+?):\s+(?<kind>fixed|not a defect)\s*(?:—|--|-)\s*(?<text>.*)$/s

  @doc "The sections the audit reads, in grammar order."
  def sections, do: @sections

  @doc "Parses `questions.md` text (`nil` for a package without one)."
  def parse(nil), do: parse("")

  def parse(text) when is_binary(text) do
    sections =
      text
      |> String.split("\n")
      |> split_sections()
      |> Enum.reduce(Map.new(@sections, &{&1, []}), fn {name, lines}, acc ->
        parsed = if name == "Dispositions", do: disposition_entries(lines), else: entries(lines)
        Map.update!(acc, name, &(&1 ++ parsed))
      end)

    %{sections: sections, dispositions: dispositions(sections["Dispositions"])}
  end

  @doc "`:asking` while any `## Ask the Shaper` entry is open, otherwise `:autonomous`."
  def state(%{sections: %{"Ask the Shaper" => [_ | _]}}), do: :asking
  def state(_parsed), do: :autonomous

  @doc "The entries of one section."
  def entries(parsed, section), do: Map.get(parsed.sections, section, [])

  @doc """
  The deterministic `questions.md` rules. `files` is the package's relative
  paths (a map or list) used to resolve `evidence/` citations.
  """
  def findings(parsed, files) do
    paths = if is_map(files), do: Map.keys(files), else: files

    asks =
      for entry <- entries(parsed, "Ask the Shaper"),
          reason = ask_defect(entry, paths),
          reason != nil do
        Finding.new("recommendation-without-evidence", subject(entry), %{
          "layer" => "questions",
          "paths" => ["questions.md"],
          "message" =>
            "## Ask the Shaper #{label(entry)} #{reason}: give a Recommendation: and an Evidence: line (a path under evidence/, a path:line, a quoted decision, or \"unproven — <what would prove it>\")"
        })
      end

    assumed =
      for entry <- entries(parsed, "Assumed"),
          missing = Enum.reject(["Reason", "Undo"], &Map.has_key?(entry.fields, &1)),
          missing != [] do
        Finding.new("assumption-without-reason", subject(entry), %{
          "layer" => "questions",
          "paths" => ["questions.md"],
          "message" =>
            "## Assumed #{label(entry)} has no #{Enum.map_join(missing, " or ", &"#{&1}:")} — every assumption states why and how to undo it"
        })
      end

    asks ++ assumed
  end

  @doc "Whether an `Evidence:` value is one of the four accepted forms."
  def valid_evidence?(value, paths) do
    value = value |> String.trim() |> String.trim("`") |> String.trim()

    cond do
      value == "" -> false
      Regex.match?(~r/^unproven\s*(—|--|-)\s*\S/u, value) -> true
      String.starts_with?(value, ["\"", "“", ">"]) -> true
      String.starts_with?(value, "evidence/") -> evidence_exists?(value, paths)
      Regex.match?(~r/^[A-Za-z0-9_.\/~-]+:\d+/, value) -> true
      true -> false
    end
  end

  defp evidence_exists?(value, paths) do
    [path | _] = String.split(value, ~r/[\s:]/, parts: 2)
    path = String.trim_trailing(path, "/")
    Enum.any?(paths, &(&1 == path or String.starts_with?(&1, path <> "/")))
  end

  defp ask_defect(entry, paths) do
    cond do
      blank?(entry.fields["Recommendation"]) -> "has no Recommendation:"
      blank?(entry.fields["Evidence"]) -> "has no Evidence:"
      not valid_evidence?(entry.fields["Evidence"], paths) -> "has no valid Evidence:"
      true -> nil
    end
  end

  defp blank?(value), do: value == nil or String.trim(value) == ""

  defp subject(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  defp subject(entry), do: entry.title |> String.slice(0, 40) |> String.replace(~r/\s+/, "-")

  defp label(%{number: number}) when is_integer(number), do: "entry #{number}"
  defp label(entry), do: "entry \"#{String.slice(entry.title, 0, 60)}\""

  defp split_sections(lines) do
    {sections, current} =
      Enum.reduce(lines, {[], nil}, fn line, {done, current} ->
        case Regex.run(~r/^##\s+(.+?)\s*$/, line) do
          [_, heading] ->
            {close(done, current), open_section(heading)}

          _ ->
            {done, append(current, line)}
        end
      end)

    sections |> close(current) |> Enum.reverse()
  end

  defp open_section(heading) do
    if heading in @sections, do: {heading, []}, else: :ignored
  end

  defp append({name, lines}, line), do: {name, [line | lines]}
  defp append(other, _line), do: other

  defp close(done, {name, lines}), do: [{name, Enum.reverse(lines)} | done]
  defp close(done, _other), do: done

  defp entries(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      cond do
        match = Regex.run(~r/^(\d+)\.\s+(.*)$/, line) ->
          [_, number, rest] = match
          [%{number: String.to_integer(number), lines: [rest]} | acc]

        match = Regex.run(~r/^[-*]\s+(.*)$/, line) ->
          [_, rest] = match
          [%{number: nil, lines: [rest]} | acc]

        acc != [] and Regex.match?(~r/^\s+\S/, line) ->
          [entry | rest] = acc
          [%{entry | lines: [String.trim(line) | entry.lines]} | rest]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&entry/1)
  end

  defp disposition_entries(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line -> %{number: nil, lines: [String.trim_leading(line, "- ")]} end)
    |> Enum.map(&entry/1)
  end

  defp entry(%{number: number, lines: lines}) do
    text = lines |> Enum.reverse() |> Enum.join(" ") |> String.trim()
    [title | _] = String.split(text, ~r/\s(?:#{Enum.join(@fields, "|")}):/, parts: 2)

    fields =
      @field_pattern
      |> Regex.scan(text)
      |> Map.new(fn [_, field, value] -> {field, String.trim(value)} end)

    %{number: number, title: String.trim(title), text: text, fields: fields}
  end

  defp dispositions(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      entry.text |> disposition() |> put_disposition(acc)
    end)
  end

  defp disposition(text) do
    case Regex.named_captures(@disposition_pattern, text) do
      %{"id" => id, "kind" => kind, "text" => text} ->
        kind = if kind == "fixed", do: "fixed", else: "not-a-defect"

        {id |> String.trim() |> String.trim("`"),
         %{"kind" => kind, "reason" => String.trim(text)}}

      nil ->
        nil
    end
  end

  defp put_disposition(nil, acc), do: acc
  defp put_disposition({id, value}, acc), do: Map.put(acc, id, value)
end
