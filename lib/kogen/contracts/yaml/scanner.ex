defmodule Kogen.Contracts.Yaml.Scanner do
  @moduledoc false

  def remove_quotes(text) do
    Regex.replace(~r/"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'/, text, "")
  end

  def strip_comment(text), do: strip_comment(text, [], nil, false)

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
end
