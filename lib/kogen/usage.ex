defmodule Kogen.Usage do
  @moduledoc "Token usage per request and in total (GPT-9)."

  def zero, do: %{input: 0, cached: 0, output: 0, reasoning: 0}
  def add(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)

  def line(u),
    do: "input=#{u.input} cached=#{u.cached} output=#{u.output} reasoning=#{u.reasoning}"

  def total(u), do: u.input + u.output
end
