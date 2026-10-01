defmodule Kogen.ShapingEvaluation.RouteRunner do
  @moduledoc false

  # A failed route is retained as evidence; it must not prevent another route
  # from running. Both the live owner and its offline control call this code.
  def run(routes, run) do
    Enum.map(routes, fn route ->
      try do
        {:ok, route, run.(route)}
      rescue
        error ->
          {:error, route,
           %{
             "route" => route,
             "type" => error.__struct__ |> Module.split() |> Enum.join("."),
             "message" => Exception.message(error)
           }}
      end
    end)
  end
end
