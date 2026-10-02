defmodule Kogen.Contracts.Yaml do
  @moduledoc """
  Parses Kogen's strict YAML subset without dependencies.

  Maps, lists, quoted and plain scalars, flow collections, and comments are supported.
  All scalar values remain strings so each schema controls its own conversions.
  """

  @type value :: String.t() | [value()] | %{String.t() => value()}
  @type error :: %{required(:line) => pos_integer(), required(:message) => String.t()}

  @spec parse(String.t()) :: {:ok, value()} | {:error, [error()]}
  def parse(source) when is_binary(source) do
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
  catch
    {:yaml_error, line, message} -> error(line, message)
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
    plain = text |> strip_comment() |> remove_quotes()
    Regex.match?(~r/(?:^|[\s\[{,:-])[&*!][A-Za-z0-9_][A-Za-z0-9_-]*/, plain)
  end

  defp remove_quotes(text) do
    Regex.replace(~r/"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'/, text, "")
  end

  defp prepare(lines) do
    for {number, text} <- lines,
        cleaned = text |> strip_comment() |> String.trim_trailing(),
        String.trim(cleaned) != "",
        do: {number, indent(cleaned), String.trim(cleaned)}
  end

  defp indent(text), do: byte_size(text) - byte_size(String.trim_leading(text, " "))

  defp root([]), do: {:error, {1, "empty document"}}

  defp root([{number, 0, _text} | _] = lines) do
    {value, rest} = parse_block(lines, number)
    {:ok, value, rest}
  end

  defp root([{number, _indent, _text} | _]), do: {:error, {number, "unexpected indentation"}}

  defp parse_block([{number, indentation, text} | _] = lines, _parent_indent) do
    cond do
      sequence_line?(text) ->
        parse_sequence(lines, indentation, [])

      key_line?(text) ->
        parse_map(lines, indentation, %{})

      String.starts_with?(text, ["[", "{"]) ->
        parse_inline(number, text, tl(lines))

      true ->
        {value, rest} = parse_inline(number, text, tl(lines))
        {value, rest}
    end
  end

  defp parse_map([{number, indentation, text} | rest], indentation, values) do
    {key, value_text} = split_key(number, text)
    duplicate_key!(number, values, key)
    {value, rest} = parse_map_value(number, indentation, value_text, rest)
    parse_map(rest, indentation, Map.put(values, key, value))
  end

  defp parse_map([{number, indentation, _text} | _], current, _values) when indentation > current,
    do: throw({:yaml_error, number, "unexpected indentation"})

  defp parse_map(rest, _indentation, values), do: {values, rest}

  defp parse_map_value(number, indentation, "", rest) do
    case rest do
      [{_child_line, child_indent, _text} | _] when child_indent > indentation ->
        parse_block(rest, indentation)

      _ ->
        throw({:yaml_error, number, "mapping key has no value"})
    end
  end

  defp parse_map_value(number, _indentation, text, rest), do: parse_inline(number, text, rest)

  defp parse_sequence([{number, indentation, "-" <> item} | rest], indentation, values) do
    item = String.trim_leading(item)
    {value, rest} = parse_sequence_item(number, indentation, item, rest)
    parse_sequence(rest, indentation, [value | values])
  end

  defp parse_sequence([{number, indentation, _text} | _], current, _values)
       when indentation > current, do: throw({:yaml_error, number, "unexpected indentation"})

  defp parse_sequence(rest, _indentation, values), do: {Enum.reverse(values), rest}

  defp parse_sequence_item(number, indentation, "", rest) do
    case rest do
      [{_line, child_indent, _text} | _] when child_indent > indentation ->
        parse_block(rest, indentation)

      _ ->
        throw({:yaml_error, number, "list item has no value"})
    end
  end

  defp parse_sequence_item(number, indentation, text, rest) do
    if key_line?(text) do
      parse_map([{number, indentation + 2, text} | rest], indentation + 2, %{})
    else
      parse_inline(number, text, rest)
    end
  end

  defp sequence_line?("-"), do: true
  defp sequence_line?("- " <> _), do: true
  defp sequence_line?(_text), do: false

  defp key_line?(text) do
    not String.starts_with?(text, ["[", "{", "\"", "'"]) and
      Regex.match?(~r/^[^:\s][^:]*:(?: |$)/, text)
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

  defp parse_inline(number, text, rest) do
    if String.starts_with?(text, ["[", "{"]) do
      {flow_text, rest} = gather(text, rest)
      {value, tail} = parse_flow(number, String.trim(flow_text))

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
    plain = remove_quotes(text)
    count(plain, "[") + count(plain, "{") == count(plain, "]") + count(plain, "}")
  end

  defp count(text, token), do: length(String.split(text, token)) - 1

  defp parse_flow(number, "[" <> rest),
    do: parse_flow_items(number, String.trim_leading(rest), "]", [])

  defp parse_flow(number, "{" <> rest),
    do: parse_flow_items(number, String.trim_leading(rest), "}", [])

  defp parse_flow_items(number, <<close::binary-size(1), rest::binary>>, close, values),
    do: {finish_flow(number, values, close), rest}

  defp parse_flow_items(number, text, close, values) do
    {item, rest} = parse_flow_item(number, text, close)
    rest = String.trim_leading(rest)

    case rest do
      "," <> tail ->
        parse_flow_items(number, String.trim_leading(tail), close, [item | values])

      <<^close::binary-size(1), tail::binary>> ->
        {finish_flow(number, [item | values], close), tail}

      _ ->
        throw({:yaml_error, number, "malformed flow collection near #{inspect(rest)}"})
    end
  end

  defp parse_flow_item(number, text, "}") do
    {key, rest} = flow_scalar(number, text, ":")

    case String.trim_leading(rest) do
      ":" <> tail ->
        {value, tail} = flow_value(number, String.trim_leading(tail), "}")
        {{key, value}, tail}

      _ ->
        throw({:yaml_error, number, "expected `key: value` in flow map"})
    end
  end

  defp parse_flow_item(number, text, "]"), do: flow_value(number, text, "]")

  defp flow_value(number, text, close) do
    if String.starts_with?(text, ["[", "{"]) do
      parse_flow(number, text)
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
        _ -> throw({:yaml_error, number, "unsupported escape \\#{escaped}"})
      end
    end)
  end

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

  defp strip_comment(text), do: strip_comment(text, [], nil, false)

  defp strip_comment(<<>>, acc, _quote, _escaped),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_comment(<<char::utf8, rest::binary>>, acc, ?\", true),
    do: strip_comment(rest, [<<char::utf8>> | acc], ?\", false)

  defp strip_comment(<<?\\, rest::binary>>, acc, ?\", false),
    do: strip_comment(rest, ["\\" | acc], ?\", true)

  defp strip_comment(<<char::utf8, rest::binary>>, acc, quote, _escaped)
       when quote != nil and char == quote,
       do: strip_comment(rest, [<<char::utf8>> | acc], nil, false)

  defp strip_comment(<<char::utf8, rest::binary>>, acc, nil, _escaped) when char in [?\", ?'],
    do: strip_comment(rest, [<<char::utf8>> | acc], char, false)

  defp strip_comment(<<?#, _rest::binary>>, acc, nil, _escaped) when acc == [] or hd(acc) == " ",
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_comment(<<char::utf8, rest::binary>>, acc, quote, _escaped),
    do: strip_comment(rest, [<<char::utf8>> | acc], quote, false)

  defp error(line, message), do: {:error, [%{line: line, message: message}]}
end
