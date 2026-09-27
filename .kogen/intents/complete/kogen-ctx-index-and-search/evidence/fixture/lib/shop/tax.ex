defmodule Shop.Tax do
  @rate 0.2
  def add(total), do: total * (1 + @rate)
  def rate, do: @rate
end
