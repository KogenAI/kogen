defmodule Kogen.Checks.Ledger.Validation do
  @moduledoc false

  alias Kogen.Checks.LedgerRow
  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.Failure

  @spec candidate([AcceptanceItem.t()], [LedgerRow.t()], integer(), String.t()) :: [String.t()]
  def candidate(items, rows, exit_status, slug) do
    current = current_rows(rows, slug)
    unknown = Enum.reject(current, &known_id?(&1.tag, items))
    missing = Enum.reject(items, &Enum.any?(current, fn row -> row.tag == "#{slug}/#{&1.id}" end))
    failed = current |> Enum.reject(&(&1.status == :passed)) |> Enum.map(&item_id(&1.tag, slug))
    suite_failure = if exit_status == 0, do: [], else: ["suite"]

    Enum.uniq(
      Enum.map(unknown, & &1.tag) ++
        Enum.map(missing, & &1.id) ++ failed ++ suite_failure
    )
  end

  @spec base([AcceptanceItem.t()], [LedgerRow.t()], String.t()) :: :ok | {:error, Failure.t()}
  def base(items, rows, slug) do
    current = current_rows(rows, slug)
    unknown = Enum.reject(current, &known_id?(&1.tag, items))

    if unknown == [] do
      verify_items(items, current, slug)
    else
      {:error,
       failure(:candidate, :unknown_acceptance_id, Enum.map_join(unknown, ", ", & &1.tag))}
    end
  end

  defp verify_items([], _rows, _slug), do: :ok

  defp verify_items([%AcceptanceItem{} = item | rest], rows, slug) do
    id = "#{slug}/#{item.id}"
    matches = Enum.filter(rows, &(&1.tag == id))

    cond do
      matches == [] ->
        {:error, failure(:candidate, :acceptance_missing_on_base, id)}

      item.verify == :test and Enum.any?(matches, &(&1.status == :passed)) ->
        {:error, failure(:candidate, :green_on_base, id)}

      item.verify == :test and Enum.any?(matches, &(&1.status != :failed)) ->
        {:error, failure(:candidate, :not_red_on_base, id)}

      item.verify == :test_keep and Enum.any?(matches, &(&1.status != :passed)) ->
        {:error, failure(:candidate, :keep_not_green_on_base, id)}

      true ->
        verify_items(rest, rows, slug)
    end
  end

  defp current_rows(rows, slug), do: Enum.filter(rows, &String.starts_with?(&1.tag, slug <> "/"))

  defp item_id(tag, slug), do: String.replace_prefix(tag, slug <> "/", "")

  defp known_id?(tag, items) do
    case String.split(tag, "/", parts: 2) do
      [_slug, id] -> Enum.any?(items, &(&1.id == id))
      _ -> false
    end
  end

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
