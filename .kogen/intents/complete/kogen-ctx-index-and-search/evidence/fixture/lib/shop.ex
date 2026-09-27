defmodule Shop do
  alias Shop.Cart
  alias Shop.{Pricing, Tax}
  alias Shop.Inventory, as: Stock
  import Shop.Format
  require Logger

  def checkout(cart, opts \\ []) do
    cart
    |> Cart.total()
    |> Pricing.apply(opts)
    |> Tax.add()
    |> money()
  end

  def restock(item), do: Stock.put(item, 1)

  defp audit(event), do: Logger.info(inspect(event))

  defmacro trace(expr), do: expr

  defguard positive(n) when n > 0
end
