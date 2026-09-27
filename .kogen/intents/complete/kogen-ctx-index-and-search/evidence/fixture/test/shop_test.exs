defmodule ShopTest do
  use ExUnit.Case
  alias Shop.Cart

  test "total" do
    assert Cart.total(%{items: [1, 2]}) == 3
  end
end
