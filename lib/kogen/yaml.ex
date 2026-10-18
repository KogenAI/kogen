defmodule Kogen.Yaml do
  @moduledoc """
  A strict parser for the YAML subset `.kogen/project.yaml` uses (SET-4): block mappings and
  sequences, one-line flow `[...]` and `{...}`, plain and quoted scalars, comments. Every node
  keeps its line so problems can name it; duplicate keys are errors.

  Nodes: `{:map, line, [{key, line, node}]}`, `{:seq, line, [node]}`,
  `{:scalar, line, text | nil, :plain | :quoted}` (`nil` for an empty value, `null` or `~`).
  Plain `true`, `false` and numbers keep their text; `Kogen.Config` decides what each key accepts.
  """

  @spec parse(String.t()) :: {:ok, tuple()} | {:error, [{pos_integer(), String.t()}]}
  def parse(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {raw, n} ->
        content = strip_comment(String.trim_trailing(raw))

        if String.trim(content) == "",
          do: [],
          else: [{n, indent(content), String.trim_leading(content)}]
      end)

    case lines do
      [] ->
        {:error, [{1, "the file is empty"}]}

      [{_, i, _} | _] ->
        try do
          {node, rest} = block(lines, i)

          case rest do
            [] -> {:ok, node}
            [{n, _, _} | _] -> {:error, [{n, "unexpected indentation"}]}
          end
        catch
          {:yaml, n, msg} -> {:error, [{n, msg}]}
        end
    end
  end

  defp indent(s), do: byte_size(s) - byte_size(String.trim_leading(s, " "))

  # Removes a comment: `#` at the start or after a space, outside quotes.
  defp strip_comment(s), do: strip_comment(s, "", nil, " ")

  defp strip_comment("", acc, _q, _prev), do: acc

  defp strip_comment("#" <> _, acc, nil, prev) when prev in [" ", "\t"],
    do: String.trim_trailing(acc)

  defp strip_comment(<<c::utf8, rest::binary>>, acc, q, _prev) do
    q =
      cond do
        q == nil and c in [?", ?'] -> c
        q == c -> nil
        true -> q
      end

    strip_comment(rest, acc <> <<c::utf8>>, q, <<c::utf8>>)
  end

  defp block([{_, i, "-" <> _} | _] = lines, i), do: seq(lines, i, [])
  defp block([{n, i, _} | _] = lines, i), do: map(lines, i, [], n)

  defp seq([{n, i, "-" <> item} | rest], i, acc) do
    if item != "" and not String.starts_with?(item, " "),
      do: throw({:yaml, n, "expected a space after -"})

    at = i + 1 + byte_size(item) - byte_size(String.trim_leading(item, " "))
    item = String.trim_leading(item)
    {children, rest} = Enum.split_while(rest, fn {_, j, _} -> j > i end)

    node =
      cond do
        item == "" and children == [] -> {:scalar, n, nil, :plain}
        item == "" -> nested(children)
        mapping_line?(item) -> nested([{n, at, item} | children])
        children != [] -> throw({:yaml, elem(hd(children), 0), "unexpected indentation"})
        true -> value(item, n)
      end

    seq(rest, i, [node | acc])
  end

  defp seq(rest, _i, acc) do
    [first | _] = items = Enum.reverse(acc)
    {{:seq, elem(first, 1), items}, rest}
  end

  defp nested([{_, j, _} | _] = lines) do
    case block(lines, j) do
      {node, []} -> node
      {_, [{n, _, _} | _]} -> throw({:yaml, n, "unexpected indentation"})
    end
  end

  defp map([{n, i, line} | rest], i, acc, first) do
    {key, value_text} = split_key(line, n)
    if List.keymember?(acc, key, 0), do: throw({:yaml, n, "duplicate key #{key}"})
    {children, rest} = Enum.split_while(rest, fn {_, j, _} -> j > i end)

    # A sequence may sit at its key's own indentation.
    {children, rest} =
      if value_text == "" and children == [],
        do:
          Enum.split_while(rest, fn {_, j, c} ->
            j > i or (j == i and String.starts_with?(c, "-"))
          end),
        else: {children, rest}

    node =
      cond do
        value_text != "" and children != [] ->
          throw({:yaml, elem(hd(children), 0), "unexpected indentation"})

        value_text != "" ->
          value(value_text, n)

        children == [] ->
          {:scalar, n, nil, :plain}

        true ->
          nested(children)
      end

    map(rest, i, [{key, n, node} | acc], first)
  end

  defp map([{n, j, _} | _], i, _acc, _first) when j > i,
    do: throw({:yaml, n, "unexpected indentation"})

  defp map(rest, _i, acc, first), do: {{:map, first, Enum.reverse(acc)}, rest}

  defp mapping_line?(s), do: Regex.match?(~r/^[A-Za-z0-9_.\/-]+:( |$)/, s)

  defp split_key(line, n) do
    case Regex.run(~r/^([A-Za-z0-9_.\/-]+):(?: (.*))?$/, line) do
      [_, key] -> {key, ""}
      [_, key, v] -> {key, String.trim(v)}
      nil -> throw({:yaml, n, "expected key: value"})
    end
  end

  # An inline value: flow collection or scalar.
  # A block value: a flow collection, a quoted scalar, or a plain scalar that runs to the end of
  # the line (commas and brackets are part of it, as in `run: python3 -c "print(1, 2)"`).
  defp value(text, n) do
    {node, rest} =
      if String.starts_with?(text, ["[", "{", "\"", "'"]),
        do: flow(text, n),
        else: plain_block(text, n)

    if String.trim(rest) != "", do: throw({:yaml, n, "unexpected text #{String.trim(rest)}"})
    node
  end

  defp flow("[" <> rest, n),
    do:
      flow_items(String.trim_leading(rest), n, "]", [], &flow/2)
      |> then(fn {items, r} -> {{:seq, n, items}, r} end)

  defp flow("{" <> rest, n),
    do:
      flow_items(String.trim_leading(rest), n, "}", [], &flow_pair/2)
      |> then(fn {items, r} -> {{:map, n, dedupe(items, n)}, r} end)

  defp flow("\"" <> rest, n), do: quoted(rest, n, ?", "")
  defp flow("'" <> rest, n), do: quoted(rest, n, ?', "")
  defp flow(text, n), do: plain(text, n)

  defp flow_items(<<close::binary-size(1), rest::binary>>, _n, close, [], _f), do: {[], rest}

  defp flow_items(text, n, close, acc, f) do
    {item, rest} = f.(String.trim_leading(text), n)
    acc = [item | acc]

    case String.trim_leading(rest) do
      "," <> more -> flow_items(String.trim_leading(more), n, close, acc, f)
      <<^close::binary-size(1), more::binary>> -> {Enum.reverse(acc), more}
      _ -> throw({:yaml, n, "unclosed #{if close == "]", do: "[", else: "{"}"})
    end
  end

  defp flow_pair(text, n) do
    case Regex.run(~r/^([A-Za-z0-9_.\/-]+):\s*(.*)$/s, text) do
      [_, key, rest] ->
        {node, rest} =
          if rest == "" or String.starts_with?(rest, [",", "}"]),
            do: {{:scalar, n, nil, :plain}, rest},
            else: flow(rest, n)

        {{key, n, node}, rest}

      nil ->
        throw({:yaml, n, "expected key: value in {...}"})
    end
  end

  defp dedupe(pairs, n) do
    Enum.reduce(pairs, [], fn {k, _, _} = p, acc ->
      if List.keymember?(acc, k, 0), do: throw({:yaml, n, "duplicate key #{k}"}), else: acc ++ [p]
    end)
  end

  defp plain_block(text, n) do
    s = String.trim(text)

    if String.starts_with?(s, ["|", ">", "&", "*", "!"]),
      do: throw({:yaml, n, "unsupported YAML: #{s}; use a quoted string"})

    {{:scalar, n, if(s in ["null", "~"], do: nil, else: s), :plain}, ""}
  end

  defp plain(text, n) do
    {s, rest} =
      case Regex.run(~r/^([^,\]\}]*)(.*)$/s, text) do
        [_, s, rest] -> {String.trim(s), rest}
      end

    if String.starts_with?(s, ["|", ">", "&", "*", "!"]),
      do: throw({:yaml, n, "unsupported YAML: #{s}; use a quoted string"})

    {{:scalar, n, if(s in ["", "null", "~"], do: nil, else: s), :plain}, rest}
  end

  defp quoted("", n, _q, _acc), do: throw({:yaml, n, "unclosed quote"})
  defp quoted(<<q, q, rest::binary>>, n, q, acc) when q == ?', do: quoted(rest, n, q, acc <> "'")
  defp quoted(<<q, rest::binary>>, n, q, acc), do: {{:scalar, n, acc, :quoted}, rest}

  defp quoted(<<?\\, c, rest::binary>>, n, ?", acc),
    do: quoted(rest, n, ?", acc <> unescape(c, n))

  defp quoted(<<c::utf8, rest::binary>>, n, q, acc), do: quoted(rest, n, q, acc <> <<c::utf8>>)

  defp unescape(?n, _), do: "\n"
  defp unescape(?t, _), do: "\t"
  defp unescape(?", _), do: "\""
  defp unescape(?\\, _), do: "\\"
  defp unescape(c, n), do: throw({:yaml, n, "unknown escape \\#{<<c>>}"})
end
