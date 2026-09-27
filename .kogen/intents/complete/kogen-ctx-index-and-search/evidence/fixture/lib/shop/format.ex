defmodule Shop.Format do
  def money(value), do: "$" <> Float.to_string(value)
end
