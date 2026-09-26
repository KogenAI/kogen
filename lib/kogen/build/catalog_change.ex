defmodule Kogen.Build.CatalogChange do
  @moduledoc """
  Checks the Candidate's verification-target catalog each cycle.

  The catalog is no longer byte-frozen after admission. The controller reads
  the Candidate's catalog and Makefile only as data (never loading Candidate
  code) and requires that every planned target exists in both and that the
  whole catalog still meets every catalog rule. The admission catalog stays
  the trust anchor: a target that existed at admission keeps its admission
  entry (rank, dependencies, provider backing), and only targets the Intent
  declared in `catalog_changes.add` take their entry from the Candidate.
  Removing, renaming or editing unselected targets needs no declaration; the
  verification-surface ledger shows it. Any violation is a verification
  failure that returns to the same Developer, never a Build stop.
  """

  alias Kogen.Build.VerificationPlan

  @doc """
  Returns `{:ok, %{sha256, order, provider_backed, entries}}` for the
  Candidate in `root`, or `{:error, reason}`.
  """
  def check(root, admission, plan, scenarios) do
    added = Map.get(plan, :added, [])

    with {:ok, candidate} <- load(root),
         :ok <- selected_present(plan.targets, candidate),
         entries = effective_entries(plan.targets, admission, candidate, added),
         :ok <- scenario_rules(scenarios, entries),
         :ok <- added_rehearsals(scenarios, entries, added),
         {:ok, order} <- VerificationPlan.order_names(plan.targets, entries) do
      {:ok,
       %{
         sha256: candidate.sha256,
         order: order,
         provider_backed:
           Map.new(entries, fn {name, entry} -> {name, entry["provider_backed"]} end),
         entries: entries
       }}
    end
  end

  defp load(root) do
    case VerificationPlan.load(root) do
      {:ok, catalog} -> {:ok, catalog}
      {:error, reason} -> {:error, "Candidate verification target catalog is invalid: #{reason}"}
    end
  end

  defp selected_present(targets, candidate) do
    case Enum.reject(targets, &Map.has_key?(candidate.targets, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         "selected verification target missing from the Candidate catalog or Makefile: " <>
           Enum.join(missing, ", ")}
    end
  end

  defp effective_entries(targets, admission, candidate, added) do
    Map.new(targets, fn name ->
      entry =
        if name in added,
          do: candidate.targets[name],
          else: admission.targets[name]

      {name, entry}
    end)
  end

  defp scenario_rules(scenarios, entries) do
    scenarios
    |> Enum.flat_map(fn scenario ->
      scenario
      |> VerificationPlan.verified_by_errors(entries)
      |> Enum.map(&"scenario #{scenario["id"]}: #{&1}")
    end)
    |> case do
      [] ->
        :ok

      errors ->
        {:error, "Candidate catalog breaks a selected target rule: " <> Enum.join(errors, "; ")}
    end
  end

  # A scenario selecting an added provider-backed target lists that target's
  # rehearsal test as a file selector, so the controller runs it.
  defp added_rehearsals(scenarios, entries, added) do
    scenarios
    |> Enum.flat_map(fn scenario ->
      offline = get_in(scenario, ["proof", "offline"]) || []

      for name <- scenario["verified_by"],
          name in added,
          entries[name]["provider_backed"] == true,
          command = get_in(entries[name], ["rehearsal", "command"]) || "",
          not Enum.any?(
            offline,
            &(String.ends_with?(&1, ".exs") and String.contains?(command, &1))
          ) do
        "scenario #{scenario["id"]} selects added provider-backed target #{name} without listing its rehearsal test as a file selector"
      end
    end)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "; ")}
    end
  end
end
