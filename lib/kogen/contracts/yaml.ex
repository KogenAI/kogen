defmodule Kogen.Contracts.Yaml do
  @moduledoc """
  Parses Kogen's strict YAML subset without dependencies.

  Maps, lists, quoted and plain scalars, flow collections, and comments are supported.
  All scalar values remain strings so each schema controls its own conversions.

  Documents are limited to 1 MiB and 64 nested collections. A leading UTF-8 BOM is
  rejected, as are YAML merge keys and Unicode escapes in double-quoted strings.
  """

  alias Kogen.Contracts.Yaml.Scanner

  @type value :: String.t() | [value()] | %{String.t() => value()}
  @type error :: %{required(:line) => pos_integer(), required(:message) => String.t()}

  @max_document_bytes 1_048_576
  @max_nesting_depth 64

  @spec parse(String.t()) :: {:ok, value()} | {:error, [error()]}
  def parse(source) when is_binary(source) do
    cond do
      byte_size(source) > @max_document_bytes ->
        error(1, "document exceeds the maximum size of #{@max_document_bytes} bytes")

      String.starts_with?(source, <<0xEF, 0xBB, 0xBF>>) ->
        error(1, "leading UTF-8 BOM is not allowed")

      not String.valid?(source) ->
        error(1, "document is not valid UTF-8")

      true ->
        parse_document(source)
    end
  catch
    {:yaml_error, line, message} -> error(line, message)
  end

  def parse(_source), do: error(1, "document must be a UTF-8 string")

  defp parse_document(source) do
    lines = source |> String.split("\n") |> Enum.with_index(1) |> Enum.map(&line_pair/1)

    with :ok <- check_lines(lines),
         prepared = prepare(lines),
         {:ok, value, []} <- root(prepared) do
      {:ok, value}
    else
      {:ok, _value, [{line, _indent, _text} | _]} -> error(line, "unexpected indentation")
      {:error, {line, message}} -> error(line, message)
      {:error, [issue | _]} -> {:error, [issue]}
    end
  end

  defp line_pair({text, number}), do: {number, text}

  defp check_lines(lines) do
    Enum.reduce_while(lines, :ok, fn {number, text}, :ok ->
      trimmed = String.trim_leading(text)

      cond do
        String.contains?(text, "\t") ->
          {:halt, {:error, {number, "tab character: indent with spaces"}}}

        document_marker?(trimmed) ->
          {:halt, {:error, {number, "directives and document markers are not allowed"}}}

        markup?(text) ->
          {:halt, {:error, {number, "anchors, aliases, and tags are not allowed"}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp document_marker?(text), do: String.starts_with?(text, ["%", "---", "..."])

  defp markup?(text) do
    plain = text |> Scanner.strip_comment() |> Scanner.remove_quotes()
    Regex.match?(~r/(?:^|[\s\[{,:-])[&*!][A-Za-z0-9_][A-Za-z0-9_-]*/, plain)
  end

  defp prepare(lines) do
    for {number, text} <- lines,
        cleaned = text |> Scanner.strip_comment() |> String.trim_trailing(),
        String.trim(cleaned) != "",
        do: {number, indent(cleaned), String.trim(cleaned)}
  end

  defp indent(text), do: byte_size(text) - byte_size(String.trim_leading(text, " "))

  defp root([]), do: {:error, {1, "empty document"}}

  defp root([{number, 0, _text} | _] = lines) do
    {value, rest} = parse_block(lines, number, 0)
    {:ok, value, rest}
  end

  defp root([{number, _indent, _text} | _]), do: {:error, {number, "unexpected indentation"}}

  defp parse_block([{number, indentation, text} | _] = lines, _parent_indent, parent_depth) do
    cond do
      sequence_line?(text) ->
        depth = parent_depth + 1
        ensure_depth!(number, depth)
        parse_sequence(lines, indentation, [], depth)

      key_line?(text) ->
        depth = parent_depth + 1
        ensure_depth!(number, depth)
        parse_map(lines, indentation, %{}, depth)

      String.starts_with?(text, ["[", "{"]) ->
        parse_inline(number, text, tl(lines), parent_depth)

      true ->
        {value, rest} = parse_inline(number, text, tl(lines), parent_depth)
        {value, rest}
    end
  end

  defp parse_map([{number, indentation, text} | rest], indentation, values, depth) do
    {key, value_text} = split_key(number, text)
    reject_merge_key!(number, key)
    duplicate_key!(number, values, key)
    {value, rest} = parse_map_value(number, indentation, value_text, rest, depth)
    parse_map(rest, indentation, Map.put(values, key, value), depth)
  end

  defp parse_map([{number, indentation, _text} | _], current, _values, _depth)
       when indentation > current, do: throw({:yaml_error, number, "unexpected indentation"})

  defp parse_map(rest, _indentation, values, _depth), do: {values, rest}

  defp parse_map_value(number, indentation, "", rest, depth) do
    case rest do
      [{_child_line, child_indent, _text} | _] when child_indent > indentation ->
        parse_block(rest, indentation, depth)

      _ ->
        throw({:yaml_error, number, "mapping key has no value"})
    end
  end

  defp parse_map_value(number, _indentation, text, rest, depth),
    do: parse_inline(number, text, rest, depth)

  defp parse_sequence([{number, indentation, "-" <> item} | rest], indentation, values, depth) do
    item = String.trim_leading(item)
    {value, rest} = parse_sequence_item(number, indentation, item, rest, depth)
    parse_sequence(rest, indentation, [value | values], depth)
  end

  defp parse_sequence([{number, indentation, _text} | _], current, _values, _depth)
       when indentation > current, do: throw({:yaml_error, number, "unexpected indentation"})

  defp parse_sequence(rest, _indentation, values, _depth), do: {Enum.reverse(values), rest}

  defp parse_sequence_item(number, indentation, "", rest, depth) do
    case rest do
      [{_line, child_indent, _text} | _] when child_indent > indentation ->
        parse_block(rest, indentation, depth)

      _ ->
        throw({:yaml_error, number, "list item has no value"})
    end
  end

  defp parse_sequence_item(number, indentation, text, rest, depth) do
    if key_line?(text) do
      nested_depth = depth + 1
      ensure_depth!(number, nested_depth)
      parse_map([{number, indentation + 2, text} | rest], indentation + 2, %{}, nested_depth)
    else
      parse_inline(number, text, rest, depth)
    end
  end

  defp sequence_line?("-"), do: true
  defp sequence_line?("- " <> _), do: true
  defp sequence_line?(_text), do: false

  defp key_line?(text) do
    Regex.match?(~r/^(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'):(?: +|$)/, text) or
      (not String.starts_with?(text, ["[", "{"]) and
         Regex.match?(~r/^[^:\s][^:]*:(?: |$)/, text))
  end

  defp split_key(number, text) do
    pattern = ~r/^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^:#&*!?|>{}\[\],"'][^:]*?):(?: +(.*))?$/

    case Regex.run(pattern, text) do
      [_, key] -> {scalar(number, key), ""}
      [_, key, value] -> {scalar(number, key), String.trim(value)}
      nil -> throw({:yaml_error, number, "expected `key: value`, got #{inspect(text)}"})
    end
  end

  defp duplicate_key!(number, values, key) do
    if Map.has_key?(values, key),
      do: throw({:yaml_error, number, "duplicate key #{inspect(key)}"})
  end

  defp reject_merge_key!(number, "<<"),
    do: throw({:yaml_error, number, "YAML merge key `<<` is not allowed"})

  defp reject_merge_key!(_number, _key), do: :ok

  defp parse_inline(number, text, rest, parent_depth) do
    if String.starts_with?(text, ["[", "{"]) do
      depth = parent_depth + 1
      ensure_depth!(number, depth)
      {flow_text, rest} = gather(text, rest)
      {value, tail} = parse_flow(number, String.trim(flow_text), depth)

      if String.trim(tail) != "",
        do: throw({:yaml_error, number, "trailing text after flow collection"})

      {value, rest}
    else
      {scalar(number, text), rest}
    end
  end

  defp gather(text, rest) do
    if balanced?(text) do
      {text, rest}
    else
      case rest do
        [{_number, _indent, more} | tail] -> gather(text <> " " <> more, tail)
        [] -> {text, []}
      end
    end
  end

  defp balanced?(text) do
    plain = Scanner.remove_quotes(text)
    count(plain, "[") + count(plain, "{") == count(plain, "]") + count(plain, "}")
  end

  defp count(text, token), do: length(String.split(text, token)) - 1

  defp parse_flow(number, "[" <> rest, depth),
    do: parse_flow_items(number, String.trim_leading(rest), "]", [], depth)

  defp parse_flow(number, "{" <> rest, depth),
    do: parse_flow_items(number, String.trim_leading(rest), "}", [], depth)

  defp parse_flow_items(number, <<close::binary-size(1), rest::binary>>, close, values, _depth),
    do: {finish_flow(number, values, close), rest}

  defp parse_flow_items(number, text, close, values, depth) do
    {item, rest} = parse_flow_item(number, text, close, depth)
    rest = String.trim_leading(rest)

    case rest do
      "," <> tail ->
        parse_flow_items(number, String.trim_leading(tail), close, [item | values], depth)

      <<^close::binary-size(1), tail::binary>> ->
        {finish_flow(number, [item | values], close), tail}

      _ ->
        throw({:yaml_error, number, "malformed flow collection near #{inspect(rest)}"})
    end
  end

  defp parse_flow_item(number, text, "}", depth) do
    {key, rest} = flow_scalar(number, text, ":")
    reject_merge_key!(number, key)

    case String.trim_leading(rest) do
      ":" <> tail ->
        {value, tail} = flow_value(number, String.trim_leading(tail), "}", depth)
        {{key, value}, tail}

      _ ->
        throw({:yaml_error, number, "expected `key: value` in flow map"})
    end
  end

  defp parse_flow_item(number, text, "]", depth), do: flow_value(number, text, "]", depth)

  defp flow_value(number, text, close, depth) do
    if String.starts_with?(text, ["[", "{"]) do
      nested_depth = depth + 1
      ensure_depth!(number, nested_depth)
      parse_flow(number, text, nested_depth)
    else
      flow_scalar(number, text, ",#{close}")
    end
  end

  defp flow_scalar(number, "\"" <> _ = text, _stops), do: quoted(number, text)
  defp flow_scalar(number, "'" <> _ = text, _stops), do: quoted(number, text)

  defp flow_scalar(number, text, stops) do
    pattern =
      if String.contains?(stops, ":"),
        do: ~r/^(.*?)(?=:\s|:$|[,\]}])/,
        else: ~r/^(.*?)(?=[#{Regex.escape(stops)}])/

    case Regex.run(pattern, text) do
      [_, value] ->
        if String.contains?(value, ["[", "{", "]", "}"]),
          do:
            throw(
              {:yaml_error, number,
               "quote #{inspect(String.trim(value))}: brackets inside a flow collection"}
            )

        {scalar(number, String.trim(value)),
         binary_part(text, byte_size(value), byte_size(text) - byte_size(value))}

      nil ->
        throw({:yaml_error, number, "unterminated flow collection"})
    end
  end

  defp finish_flow(_number, values, "]"), do: Enum.reverse(values)

  defp finish_flow(number, values, "}") do
    values
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn {key, value}, map ->
      reject_merge_key!(number, key)
      duplicate_key!(number, map, key)
      Map.put(map, key, value)
    end)
  end

  defp quoted(number, text) do
    pattern = ~r/^("((?:[^"\\]|\\.)*)"|'((?:[^']|'')*)')/

    case Regex.run(pattern, text) do
      [all, _whole, double] -> {unescape(number, double), drop_prefix(text, all)}
      [all, _whole, "", single] -> {String.replace(single, "''", "'"), drop_prefix(text, all)}
      _ -> throw({:yaml_error, number, "unterminated quoted string"})
    end
  end

  defp unescape(number, text) do
    Regex.replace(~r/\\(.)/, text, fn _match, escaped ->
      case escaped do
        "n" -> "\n"
        "t" -> "\t"
        "\"" -> "\""
        "\\" -> "\\"
        "/" -> "/"
        "u" -> throw({:yaml_error, number, "Unicode escape \\u is not supported"})
        _ -> throw({:yaml_error, number, "unsupported escape \\#{escaped}"})
      end
    end)
  end

  defp ensure_depth!(_number, depth) when depth <= @max_nesting_depth, do: :ok

  defp ensure_depth!(number, _depth),
    do:
      throw(
        {:yaml_error, number,
         "maximum nesting depth of #{@max_nesting_depth} collections exceeded"}
      )

  defp scalar(number, "\"" <> _ = text), do: whole_quoted(number, text)
  defp scalar(number, "'" <> _ = text), do: whole_quoted(number, text)

  defp scalar(number, text) do
    cond do
      text == "" ->
        throw({:yaml_error, number, "empty value"})

      String.starts_with?(text, ["&", "*", "!", "|", ">", "?", "@", "`", "%"]) ->
        throw({:yaml_error, number, "anchors, aliases, tags, and block scalars are not allowed"})

      String.starts_with?(text, "- ") ->
        throw({:yaml_error, number, "list item in a value position: #{inspect(text)}"})

      Regex.match?(~r/:\s/, text) ->
        throw({:yaml_error, number, "unquoted `: ` inside a value: #{inspect(text)}"})

      true ->
        text
    end
  end

  defp whole_quoted(number, text) do
    case quoted(number, text) do
      {value, ""} -> value
      {_value, rest} -> throw({:yaml_error, number, "text after closing quote: #{inspect(rest)}"})
    end
  end

  defp drop_prefix(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  defp error(line, message), do: {:error, [%{line: line, message: message}]}
end
