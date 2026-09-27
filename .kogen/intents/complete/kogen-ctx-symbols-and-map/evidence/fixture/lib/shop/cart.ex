defmodule Shop.Cart do
  def total(cart), do: Enum.sum(cart.items)
  def total(cart, discount) when discount > 0, do: total(cart) - discount
  def total(cart, _discount), do: total(cart)
  def empty, do: %__MODULE__{}
  defstruct items: []
  def merge(a, b), do: __MODULE__.total(a) + total(b)
end
