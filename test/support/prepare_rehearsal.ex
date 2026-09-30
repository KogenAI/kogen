defmodule Kogen.PrepareRehearsal do
  @moduledoc """
  Route-aware expectations for `scripts/check/rehearsals.exs`'s prepare
  rehearsal.

  A live target's `prepare` runs on the Build's selected route (frozen at
  admission and exported to the gate as `KOGEN_ROUTE`), the same route the
  live target itself exercises; only without one does it use the Candidate's
  `default_route`. The owner's setup entry points it must trace depend on
  that route's harnesses: a scope check is
  traced for exactly the harnesses the route's roles run on. The catalog
  declares every entry point the owner can trace; `required_trace/2` keeps the
  ones the route actually reaches, and never fewer than the route needs.

  Lives in `test/support` like `Kogen.FixtureValidation`: offline-gate tooling
  that never ships in a release.
  """

  @scope_entry ~r/\.(claude|codex)_scope_ready\?$/

  @doc """
  The configuration of the selected route: `route` (the Build's selected
  route, normally `KOGEN_ROUTE`), or the config's `default_route` when `nil`
  or empty.
  """
  def selected_config!(root, route \\ System.get_env("KOGEN_ROUTE")) do
    route = if route in [nil, ""], do: nil, else: route

    case Kogen.Intent.read_config(Path.join(root, ".kogen/config.yaml"), route) do
      {:ok, config} -> config
      {:error, reason} -> raise "cannot resolve the selected route: #{reason}"
    end
  end

  @doc """
  The catalog's declared `entries` narrowed to the entry points the route's
  harnesses trace. A route harness with no declared scope entry point raises,
  since the catalog would then no longer prove that harness's scope check.
  """
  def required_trace(entries, config) do
    harnesses = Kogen.Intent.harnesses(config)
    declared = for entry <- entries, harness = scope_harness(entry), do: harness

    if declared != [] do
      missing = harnesses -- declared

      if missing != [] do
        raise "prepare_trace_assertions declare no scope check for route " <>
                "#{inspect(config.route)} harness #{Enum.join(missing, ", ")}"
      end
    end

    Enum.filter(entries, fn entry ->
      case scope_harness(entry) do
        nil -> true
        harness -> harness in harnesses
      end
    end)
  end

  defp scope_harness(entry) do
    case Regex.run(@scope_entry, entry) do
      [_, harness] -> harness
      _ -> nil
    end
  end
end
