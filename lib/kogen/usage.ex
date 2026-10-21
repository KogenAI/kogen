defmodule Kogen.Usage do
  @moduledoc "Token usage per request and in total (GPT-9)."

  def state(u) do
    valid = Enum.all?(Map.values(u), &(is_nil(&1) or (is_integer(&1) and &1 >= 0)))
    if valid, do: validated_state(u), else: "inconsistent"
  end

  defp validated_state(u) do
    bounded = fn a, b -> is_nil(a) or is_nil(b) or a <= b end

    disjoint =
      is_nil(u.cached) or is_nil(u.write) or is_nil(u.input) or u.cached + u.write <= u.input

    lifetimes =
      is_nil(u.write) or is_nil(u.write_30m) or is_nil(u.write_12h) or
        u.write_30m + u.write_12h == u.write

    cond do
      not bounded.(u.cached, u.input) or not bounded.(u.write, u.input) or
        not bounded.(u.write_30m, u.write) or not bounded.(u.write_12h, u.write) or
        not bounded.(u.reasoning, u.output) or not disjoint or not lifetimes ->
        "inconsistent"

      Enum.all?(Map.values(u), &is_nil/1) ->
        "unknown"

      Enum.any?(Map.values(u), &is_nil/1) ->
        "partial"

      true ->
        "known"
    end
  end

  def zero, do: %{input: 0, cached: 0, output: 0, reasoning: 0}
  def add(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)

  def line(u),
    do: "input=#{u.input} cached=#{u.cached} output=#{u.output} reasoning=#{u.reasoning}"

  def total(u), do: u.input + u.output
end
