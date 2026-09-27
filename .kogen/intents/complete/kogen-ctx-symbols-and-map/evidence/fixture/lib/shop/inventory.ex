defmodule Shop.Inventory do
  use Agent
  def put(item, count), do: Agent.update(__MODULE__, &Map.put(&1, item, count))
  def lookup(item), do: Agent.get(__MODULE__, &Map.get(&1, item))
  def fetcher, do: &Shop.Tax.add/1
end
