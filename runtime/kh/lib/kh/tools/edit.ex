defmodule Kh.Tools.Edit do
  @moduledoc "Exact-text replacement, pi semantics: edits[] matched against the original, unique, non-overlapping; fuzzy fallback."

  def spec do
    %{
      name: "edit",
      description:
        "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit. Do not include large unchanged regions just to connect distant changes.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file to edit (relative or absolute)"},
          "edits" => %{
            "type" => "array",
            "description" =>
              "One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "oldText" => %{"type" => "string", "description" => "Exact text to replace. Must be unique in the file."},
                "newText" => %{"type" => "string", "description" => "Replacement text."}
              },
              "required" => ["oldText", "newText"]
            }
          }
        },
        "required" => ["path", "edits"]
      }
    }
  end

  def run(%{"path" => path} = args, ctx) when is_binary(path) do
    with {:ok, edits} <- normalize_edits(args),
         abs = Kh.Util.resolve(path, ctx.cwd),
         {:ok, raw} <- read(abs, path),
         {bom, content} = split_bom(raw),
         ending = if(String.contains?(content, "\r\n"), do: "\r\n", else: "\n"),
         norm = String.replace(content, "\r\n", "\n"),
         {:ok, new} <- apply_edits(norm, edits, path, ctx) do
      restored = if ending == "\r\n", do: String.replace(new, "\n", "\r\n"), else: new

      case File.write(abs, bom <> restored) do
        :ok -> {:ok, "Successfully replaced #{length(edits)} block(s) in #{path}."}
        {:error, r} -> {:error, "Could not write #{path}: #{:file.format_error(r)}"}
      end
    end
  end

  def run(_, _), do: {:error, "edit requires 'path' and 'edits'"}

  defp read(abs, path) do
    case File.read(abs) do
      {:ok, b} -> {:ok, Kh.Util.utf8(b)}
      {:error, r} -> {:error, "Could not edit file: #{path}. Error code: #{r}."}
    end
  end

  defp split_bom("﻿" <> rest), do: {"﻿", rest}
  defp split_bom(s), do: {"", s}

  @doc false
  def normalize_edits(args) do
    edits = args["edits"]

    edits =
      case edits do
        s when is_binary(s) ->
          case JSON.decode(s) do
            {:ok, l} when is_list(l) -> l
            {:ok, %{} = m} -> [m]
            _ -> nil
          end

        %{} = m ->
          [m]

        l when is_list(l) ->
          l

        _ ->
          nil
      end

    legacy =
      case {args["oldText"] || args["old_string"] || args["old_text"], args["newText"] || args["new_string"] || args["new_text"]} do
        {o, n} when is_binary(o) and is_binary(n) -> [%{"oldText" => o, "newText" => n}]
        _ -> []
      end

    all = (edits || []) ++ legacy

    all =
      Enum.map(all, fn e ->
        %{
          "oldText" => e["oldText"] || e["old_string"] || e["old_text"],
          "newText" => e["newText"] || e["new_string"] || e["new_text"]
        }
      end)

    cond do
      all == [] -> {:error, "Edit tool input is invalid. edits must contain at least one replacement."}
      Enum.any?(all, &(not is_binary(&1["oldText"]) or not is_binary(&1["newText"]))) -> {:error, "Each edit needs string oldText and newText."}
      true -> {:ok, all}
    end
  end

  def apply_edits(content, edits, path, ctx) do
    total = length(edits)

    with :ok <- check_empty(edits, path, total) do
      norm_edits = Enum.map(edits, &%{&1 | "oldText" => String.replace(&1["oldText"], "\r\n", "\n"), "newText" => String.replace(&1["newText"], "\r\n", "\n")})
      exact = Enum.map(norm_edits, &:binary.matches(content, &1["oldText"]))
      use_fuzzy = Enum.any?(exact, &(&1 == []))
      base = if use_fuzzy, do: fuzzy(content), else: content

      results =
        norm_edits
        |> Enum.with_index()
        |> Enum.map(fn {e, i} ->
          needle = if use_fuzzy, do: fuzzy(e["oldText"]), else: e["oldText"]
          {i, e, :binary.matches(base, needle), needle}
        end)

      case Enum.find(results, fn {_, _, m, _} -> length(m) != 1 end) do
        {i, _e, [], _} ->
          {:error, not_found(path, i, total) <> hint(base, Enum.at(norm_edits, i)["oldText"], ctx)}

        {i, _e, m, _} ->
          {:error, dup(path, i, total, length(m))}

        nil ->
          spans = for {_i, e, [{pos, len}], _n} <- results, do: {pos, len, e["newText"]}
          sorted = Enum.sort(spans)

          if overlap?(sorted) do
            {:error, "edits overlap in #{path}. Merge nearby or overlapping changes into a single edit."}
          else
            new = sorted |> Enum.reverse() |> Enum.reduce(base, fn {pos, len, rep}, acc ->
              binary_part(acc, 0, pos) <> rep <> binary_part(acc, pos + len, byte_size(acc) - pos - len)
            end)

            if new == base do
              {:error, "No changes made to #{path}. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."}
            else
              {:ok, new}
            end
          end
      end
    end
  end

  defp overlap?(sorted) do
    sorted |> Enum.chunk_every(2, 1, :discard) |> Enum.any?(fn [{p1, l1, _}, {p2, _, _}] -> p1 + l1 > p2 end)
  end

  defp check_empty(edits, path, total) do
    case Enum.find_index(edits, &(&1["oldText"] == "")) do
      nil -> :ok
      _ when total == 1 -> {:error, "oldText must not be empty in #{path}."}
      i -> {:error, "edits[#{i}].oldText must not be empty in #{path}."}
    end
  end

  defp not_found(path, _i, 1), do: "Could not find the exact text in #{path}. The old text must match exactly including all whitespace and newlines."
  defp not_found(path, i, _), do: "Could not find edits[#{i}] in #{path}. The oldText must match exactly including all whitespace and newlines."

  defp dup(path, _i, 1, n), do: "Found #{n} occurrences of the text in #{path}. The text must be unique. Please provide more context to make it unique."
  defp dup(path, i, _, n), do: "Found #{n} occurrences of edits[#{i}] in #{path}. Each oldText must be unique. Please provide more context to make it unique."

  @doc "Progressive normalisation for fuzzy matching (trailing whitespace, smart quotes/dashes, odd spaces)."
  def fuzzy(text) do
    text
    |> String.normalize(:nfkc)
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.replace(~r/[\x{2018}\x{2019}\x{201A}\x{201B}]/u, "'")
    |> String.replace(~r/[\x{201C}\x{201D}\x{201E}\x{201F}]/u, "\"")
    |> String.replace(~r/[\x{2010}-\x{2015}\x{2212}]/u, "-")
    |> String.replace(~r/[\x{00A0}\x{2002}-\x{200A}\x{202F}\x{205F}\x{3000}]/u, " ")
  end

  # Feature edit_hints: point at the closest line when oldText is not found.
  defp hint(base, old, ctx) do
    if MapSet.member?(ctx.features, "edit_hints") do
      first = old |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find("", &(&1 != ""))
      lines = String.split(base, "\n")

      best =
        lines
        |> Enum.with_index(1)
        |> Enum.map(fn {l, n} -> {String.jaro_distance(String.trim(l), first), n} end)
        |> Enum.max_by(&elem(&1, 0), fn -> {0.0, 0} end)

      case best do
        {score, n} when score >= 0.8 and first != "" ->
          ctxl = lines |> Enum.with_index(1) |> Enum.filter(fn {_, i} -> i >= n - 2 and i <= n + 4 end)
          "\n\nClosest match near line #{n} (re-read the file and copy the text exactly):\n" <> Enum.map_join(ctxl, "\n", fn {l, i} -> "#{i}: #{l}" end)

        _ ->
          "\n\nNo similar line found; read the file again before retrying."
      end
    else
      ""
    end
  end
end
