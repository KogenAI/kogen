defmodule Shop.Pricing do
  def apply(total, opts), do: total - Keyword.get(opts, :discount, 0)

  defmodule Rules do
    def default, do: []
  end

  def rules, do: Rules.default()
end
