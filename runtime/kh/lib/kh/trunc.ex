defmodule Kh.Trunc do
  @moduledoc "Line/byte truncation with pi-compatible limits (2000 lines / 50KB)."
  @max_lines 2000
  @max_bytes 50 * 1024

  def max_lines, do: @max_lines
  def max_bytes, do: @max_bytes

  def format_size(b) when b < 1024, do: "#{b}B"
  def format_size(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)}KB"
  def format_size(b), do: "#{Float.round(b / 1024 / 1024, 1)}MB"

  @doc "Keep leading whole lines."
  def head(text, max_lines \\ @max_lines, max_bytes \\ @max_bytes) do
    lines = String.split(text, "\n")
    total = length(lines)

    if total <= max_lines and byte_size(text) <= max_bytes do
      %{content: text, truncated: false, by: nil, total_lines: total, output_lines: total, first_line_exceeds: false}
    else
      {kept, by} = take(lines, max_lines, max_bytes, [], 0)

      %{
        content: Enum.join(kept, "\n"),
        truncated: true,
        by: by,
        total_lines: total,
        output_lines: length(kept),
        first_line_exceeds: kept == [] and hd(lines) != "" and byte_size(hd(lines)) > max_bytes
      }
    end
  end

  @doc "Keep trailing whole lines (partial last line if it alone exceeds the byte limit)."
  def tail(text, max_lines \\ @max_lines, max_bytes \\ @max_bytes) do
    lines = String.split(text, "\n")
    total = length(lines)

    if total <= max_lines and byte_size(text) <= max_bytes do
      %{content: text, truncated: false, by: nil, total_lines: total, output_lines: total, last_line_partial: false}
    else
      {kept_rev, by} = take(Enum.reverse(lines), max_lines, max_bytes, [], 0)
      kept = Enum.reverse(kept_rev)

      if kept == [] do
        last = List.last(lines)
        part = binary_part(last, byte_size(last) - max_bytes, max_bytes) |> Kh.Util.utf8()
        %{content: part, truncated: true, by: :bytes, total_lines: total, output_lines: 1, last_line_partial: true}
      else
        %{
          content: Enum.join(kept, "\n"),
          truncated: true,
          by: by,
          total_lines: total,
          output_lines: length(kept),
          last_line_partial: false
        }
      end
    end
  end

  # accumulates lines in reverse; returns them in original order of iteration
  defp take([], _ml, _mb, acc, _bytes), do: {Enum.reverse(acc), :lines}
  defp take(_l, ml, _mb, acc, _bytes) when length(acc) >= ml, do: {Enum.reverse(acc), :lines}

  defp take([line | rest], ml, mb, acc, bytes) do
    cost = byte_size(line) + if(acc == [], do: 0, else: 1)

    if bytes + cost > mb do
      {Enum.reverse(acc), :bytes}
    else
      take(rest, ml, mb, [line | acc], bytes + cost)
    end
  end
end
