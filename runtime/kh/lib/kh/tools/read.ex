defmodule Kh.Tools.Read do
  @moduledoc false
  alias Kh.Trunc

  def spec do
    %{
      name: "read",
      description:
        "Read the contents of a text file. Output is truncated to #{Trunc.max_lines()} lines or #{div(Trunc.max_bytes(), 1024)}KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file to read (relative or absolute)"},
          "offset" => %{"type" => "number", "description" => "Line number to start reading from (1-indexed)"},
          "limit" => %{"type" => "number", "description" => "Maximum number of lines to read"}
        },
        "required" => ["path"]
      }
    }
  end

  def run(%{"path" => path} = args, ctx) when is_binary(path) do
    abs = Kh.Util.resolve(path, ctx.cwd)

    case File.read(abs) do
      {:error, reason} ->
        {:error, "Could not read #{path}: #{:file.format_error(reason)}"}

      {:ok, bin} ->
        if String.valid?(bin) or not binary?(bin), do: text(bin, args, path), else: {:error, "#{path} looks like a binary file; use bash to inspect it."}
    end
  end

  def run(_, _), do: {:error, "read requires a string 'path'"}

  defp binary?(bin), do: :binary.match(binary_part(bin, 0, min(byte_size(bin), 8000)), <<0>>) != :nomatch

  defp text(bin, args, path) do
    all = String.split(Kh.Util.utf8(bin), "\n")
    total = length(all)
    offset = int(args["offset"])
    limit = int(args["limit"])
    start = if offset, do: max(0, offset - 1), else: 0

    if start >= total do
      {:error, "Offset #{offset} is beyond end of file (#{total} lines total)"}
    else
      rest = Enum.drop(all, start)
      {selected, user_limited} = if limit, do: {Enum.take(rest, limit), min(limit, length(rest))}, else: {rest, nil}
      joined = Enum.join(selected, "\n")
      t = Trunc.head(joined)
      shown_from = start + 1

      out =
        cond do
          t.first_line_exceeds ->
            size = Trunc.format_size(byte_size(Enum.at(all, start)))
            "[Line #{shown_from} is #{size}, exceeds #{Trunc.format_size(Trunc.max_bytes())} limit. Use bash: sed -n '#{shown_from}p' #{path} | head -c #{Trunc.max_bytes()}]"

          t.truncated ->
            last = shown_from + t.output_lines - 1
            why = if t.by == :lines, do: "", else: " (#{Trunc.format_size(Trunc.max_bytes())} limit)"
            t.content <> "\n\n[Showing lines #{shown_from}-#{last} of #{total}#{why}. Use offset=#{last + 1} to continue.]"

          user_limited != nil and start + user_limited < total ->
            t.content <> "\n\n[#{total - (start + user_limited)} more lines in file. Use offset=#{start + user_limited + 1} to continue.]"

          true ->
            t.content
        end

      {:ok, out}
    end
  end

  defp int(nil), do: nil
  defp int(n) when is_number(n), do: trunc(n)

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil
end
