defmodule Kogen.Build.Progress do
  @moduledoc """
  No-progress and budget accounting for repair rounds.

  Limits are frozen when the state is created (`max_rounds`, `max_no_progress`,
  `max_dispatches`, `max_developer_resumptions`). Spent counters only grow:
  resolving a finding never resets them.

  `record_round/2` takes `%{tree:, signatures:, dispatches:, review_no_change:}`
  (`flaky: true` marks a cycle whose target passed only on the same-tree
  retry; a later flaky round counts as no progress. `dispatches` is the number
  of actual provider dispatches this round, taken
  from the dispatch ledger; `developer_resumption: true` optionally charges a
  Developer resumption). The first round is the baseline and spends no
  no-progress unit. A later round records one no-progress unit when it clears none
  of the previously unresolved signatures, reintroduces any previously cleared
  signature (oscillation), or is a same-tree Review no-change round. Repetition
  of a signature is diagnostic only; what stops repair is the frozen
  `max_no_progress` allowance: once the spent units reach it while any
  signature remains unresolved, `record_round/2` stops with `:no_progress`.

  Timing is diagnostic only. `charge/3` adds the milliseconds of each
  controller-active span to the Build's `"elapsed_ms"` (which only grows across
  continuations) and to the named phase in `"phases"`; `observe/2` records the
  last Developer turn and every verification cycle (`"cycles_ms"`). The frozen
  `build_time_nudge_minutes` (optional so older states stay valid) is never a
  limit: `nudge_due?/1` says when the Build first passed it so the controller
  can warn once (`mark_nudged/1`). Nothing here ever stops a Build for elapsed
  time. `record_turn_nudge/2` keeps the Developer turn nudges (never charged
  as resumptions).

  The state serializes to a JSON-compatible string-keyed map (`to_map/1`,
  `from_map/1`), validated on read.
  """

  @limit_keys ~w(max_rounds max_no_progress max_dispatches max_developer_resumptions)
  @counter_keys ~w(rounds no_progress dispatches developer_resumptions)
  @time_key "build_time_nudge_minutes"
  @time_extra_keys ~w(elapsed_ms last_turn_ms last_cycle_ms phases cycles_ms nudged turn_nudges)
  @time_defaults %{
    "elapsed_ms" => 0,
    "last_turn_ms" => 0,
    "last_cycle_ms" => 0,
    "phases" => %{},
    "cycles_ms" => [],
    "nudged" => false,
    "turn_nudges" => []
  }

  @type t :: %{required(String.t()) => term()}

  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(limits) when is_map(limits) do
    limits = Map.new(limits, fn {k, v} -> {to_string(k), v} end)

    with :ok <- validate_limits(limits) do
      {:ok,
       %{
         "limits" => Map.take(limits, [@time_key | @limit_keys]) |> drop_nil(),
         "rounds" => 0,
         "no_progress" => 0,
         "dispatches" => 0,
         "developer_resumptions" => 0,
         "unresolved" => [],
         "cleared" => [],
         "last_tree" => nil,
         "history" => []
       }
       |> Map.merge(@time_defaults)}
    end
  end

  defp drop_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  @doc "Builds limits from a `Kogen.Intent.read_config/2` config."
  def new_from_config(config) do
    new(%{
      build_time_nudge_minutes: Map.get(config, :build_time_nudge_minutes),
      max_rounds: config.max_rounds,
      max_no_progress: config.max_no_progress,
      max_dispatches: config.max_dispatches,
      max_developer_resumptions: config.max_developer_resumptions
    })
  end

  @spec record_round(t(), map()) :: {:ok, t()} | {:stop, atom(), map()}
  def record_round(state, round) do
    sigs =
      round |> Map.get(:signatures, []) |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

    dispatches = Map.get(round, :dispatches, 0)
    tree = Map.get(round, :tree)
    no_change? = Map.get(round, :review_no_change, false) == true
    baseline? = state["rounds"] == 0

    prev = state["unresolved"]
    cleared_now = prev -- sigs
    # One charge per reintroduction event: a cleared signature that was absent
    # last round and is back now. One that merely persists is not charged again.
    reintroduced = Enum.filter(sigs, &(&1 in state["cleared"] and &1 not in prev))

    flaky? = Map.get(round, :flaky, false) == true

    reason =
      if flaky? and not baseline?,
        do: :flaky,
        else: no_progress_reason(baseline?, reintroduced, cleared_now, no_change?)

    resumption = if Map.get(round, :developer_resumption, false) == true, do: 1, else: 0

    next = %{
      state
      | "rounds" => state["rounds"] + 1,
        "no_progress" => state["no_progress"] + if(reason, do: 1, else: 0),
        "dispatches" => state["dispatches"] + max(dispatches, 0),
        "developer_resumptions" => state["developer_resumptions"] + resumption,
        "unresolved" => sigs,
        "cleared" => Enum.sort(Enum.uniq(state["cleared"] ++ cleared_now)),
        "last_tree" => tree,
        "history" =>
          state["history"] ++
            [
              %{
                "tree" => tree,
                "signatures" => sigs,
                "dispatches" => dispatches,
                "no_progress_reason" => reason && Atom.to_string(reason)
              }
            ]
    }

    case stop_class(next, sigs) do
      nil -> {:ok, next}
      class -> {:stop, class, details(next, class, reason)}
    end
  end

  defp no_progress_reason(true, _reintroduced, _cleared, _no_change), do: nil
  defp no_progress_reason(false, [_ | _], _cleared, _no_change), do: :oscillation
  defp no_progress_reason(false, [], [], _no_change), do: :nothing_cleared
  defp no_progress_reason(false, [], _cleared, true), do: :review_no_change
  defp no_progress_reason(false, [], _cleared, false), do: nil

  @spec remaining(t()) :: map()
  def remaining(state) do
    l = state["limits"]

    %{
      rounds: max(l["max_rounds"] - state["rounds"], 0),
      no_progress: max(l["max_no_progress"] - state["no_progress"], 0),
      dispatches: max(l["max_dispatches"] - state["dispatches"], 0),
      developer_resumptions:
        max(l["max_developer_resumptions"] - state["developer_resumptions"], 0)
    }
  end

  @doc """
  Adds `ms` of active controller time (never negative) to the Build's elapsed
  time and, when `phase` is given, to that phase's total.
  """
  @spec charge(t(), integer(), String.t() | nil) :: t()
  def charge(state, ms, phase \\ nil) do
    ms = max(ms, 0)
    state = Map.put(state, "elapsed_ms", Map.get(state, "elapsed_ms", 0) + ms)

    if is_binary(phase),
      do:
        Map.update(
          state,
          "phases",
          %{phase => ms},
          &Map.update(&1, phase, ms, fn v -> v + ms end)
        ),
      else: state
  end

  @doc "Records the last Developer turn and verification cycle durations (cycles are listed)."
  @spec observe(t(), keyword()) :: t()
  def observe(state, opts) do
    Enum.reduce(opts, state, fn
      {:turn_ms, ms}, acc when is_integer(ms) and ms > 0 ->
        Map.put(acc, "last_turn_ms", ms)

      {:cycle_ms, ms}, acc when is_integer(ms) and ms > 0 ->
        acc
        |> Map.put("last_cycle_ms", ms)
        |> Map.update("cycles_ms", [ms], &(&1 ++ [ms]))

      _other, acc ->
        acc
    end)
  end

  @doc "True once elapsed time has passed the configured nudge and it was not yet warned."
  @spec nudge_due?(t()) :: boolean()
  def nudge_due?(%{"limits" => %{@time_key => minutes}} = state) when is_integer(minutes),
    do: Map.get(state, "nudged", false) != true and elapsed_ms(state) >= minutes * 60_000

  def nudge_due?(_state), do: false

  @doc "Marks the one-time Build time warning as given."
  @spec mark_nudged(t()) :: t()
  def mark_nudged(state), do: Map.put(state, "nudged", true)

  @doc "True when the Build has passed its configured nudge (for handoff lines)."
  @spec past_nudge?(t()) :: boolean()
  def past_nudge?(%{"limits" => %{@time_key => minutes}} = state) when is_integer(minutes),
    do: elapsed_ms(state) >= minutes * 60_000

  def past_nudge?(_state), do: false

  @spec elapsed_ms(t()) :: non_neg_integer()
  def elapsed_ms(state), do: Map.get(state, "elapsed_ms", 0)

  @doc "Appends a Developer turn nudge (not a resumption charge)."
  @spec record_turn_nudge(t(), map()) :: t()
  def record_turn_nudge(state, entry),
    do: Map.update(state, "turn_nudges", [entry], &(&1 ++ [entry]))

  @doc "The diagnostic timing measurement of a state."
  @spec time_summary(t()) :: map()
  def time_summary(state) do
    %{
      "elapsed_ms" => elapsed_ms(state),
      "phases" => Map.get(state, "phases", %{}),
      "cycles_ms" => Map.get(state, "cycles_ms", []),
      "nudge_minutes" => get_in(state, ["limits", @time_key]),
      "nudged" => Map.get(state, "nudged", false),
      "turn_nudges" => Map.get(state, "turn_nudges", [])
    }
  end

  @doc "Charges a Developer resumption outside a round; stops when over the limit."
  def record_resumption(state) do
    next = %{state | "developer_resumptions" => state["developer_resumptions"] + 1}

    if next["developer_resumptions"] > next["limits"]["max_developer_resumptions"],
      do: {:stop, :developer_resumption_limit, details(next, :developer_resumption_limit, nil)},
      else: {:ok, next}
  end

  defp stop_class(s, sigs) do
    l = s["limits"]

    cond do
      s["dispatches"] > l["max_dispatches"] -> :dispatch_limit
      s["developer_resumptions"] > l["max_developer_resumptions"] -> :developer_resumption_limit
      sigs == [] -> nil
      s["dispatches"] >= l["max_dispatches"] -> :dispatch_limit
      s["no_progress"] >= l["max_no_progress"] -> :no_progress
      s["rounds"] >= l["max_rounds"] -> :max_rounds
      true -> nil
    end
  end

  defp details(s, class, reason) do
    %{
      class: class,
      last_no_progress_reason: reason,
      remaining: remaining(s),
      ledger: %{
        rounds: s["rounds"],
        no_progress: s["no_progress"],
        dispatches: s["dispatches"],
        developer_resumptions: s["developer_resumptions"],
        elapsed_ms: Map.get(s, "elapsed_ms", 0)
      },
      time: time_summary(s),
      unresolved: s["unresolved"],
      next_action: next_action(class),
      state: s
    }
  end

  defp next_action(:no_progress),
    do: "Review the no-progress history and use a different repair approach if appropriate."

  defp next_action(:max_rounds),
    do:
      "Round budget spent. Review the failure report and start a new Build with a narrower Intent."

  defp next_action(:dispatch_limit),
    do:
      "Dispatch budget spent. Audit the dispatch ledger for waste before raising max_dispatches in a new Build."

  defp next_action(:developer_resumption_limit),
    do: "Developer resumptions exhausted. Return the Intent to Draft and start a new Build."

  @spec to_map(t()) :: map()
  def to_map(state), do: state

  @spec from_map(term()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{"limits" => limits} = map) when is_map(limits) do
    with :ok <- validate_limits(limits),
         true <- Enum.all?(@counter_keys, &(is_integer(map[&1]) and map[&1] >= 0)),
         true <- Enum.all?(~w(unresolved cleared history), &is_list(map[&1])),
         true <- Enum.all?(map["unresolved"] ++ map["cleared"], &is_binary/1) do
      {:ok,
       Map.take(
         map,
         [
           "limits",
           "last_tree" | @counter_keys ++ @time_extra_keys ++ ~w(unresolved cleared history)
         ]
       )
       |> then(&Map.merge(@time_defaults, &1))}
    else
      {:error, _} = e -> e
      _ -> {:error, "invalid progress state"}
    end
  end

  def from_map(_), do: {:error, "invalid progress state"}

  defp validate_limits(limits) do
    optional = if is_nil(limits[@time_key]), do: [], else: [@time_key]

    case Enum.find(@limit_keys ++ optional, fn k ->
           not (is_integer(limits[k]) and limits[k] > 0)
         end) do
      nil -> :ok
      key -> {:error, "progress limit #{key} must be a positive integer"}
    end
  end
end
