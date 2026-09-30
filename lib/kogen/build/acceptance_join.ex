defmodule Kogen.Build.AcceptanceJoin do
  @moduledoc """
  The single final acceptance join.

  `check/1` accepts only structured, digest-bound inputs; it never trusts a
  self-reported success string. Every binding must name the final Candidate
  tree and the frozen context digest. All refusal reasons are collected.

  Inputs (atom keys):

    * `:tree`, `:context_digest` - the final Candidate tree and frozen context.
    * `:offline` - `%{tree:, context_digest:, status: "passed", sha256:}`.
    * `:selected_targets` - target ids that the frozen plan selects.
    * `:selected_offline_targets` - the exact offline target ids selected by the frozen plan.
    * `:offline_target_receipts` - bound receipts for the settled offline targets.
    * `:target_receipts` - `[%{target:, tree:, context_digest:, status: "passed", sha256:}]`
      (a reused receipt is acceptable only with the exact binding).
    * `:scenarios` - `%{scenario_id => true | :satisfied | "satisfied"}`; `:scenario_ids`
      optionally lists the ids that must be present.
    * `:findings` - `[%{id:, blocking: bool, status: "open" | ...}]`.
    * `:verdict` - `%{session:, verdict: "accept", tree:, provisional: bool, final: bool}`;
      a provisional verdict is usable only when `final: true` and bound to `:tree`.
    * `:settlement` - `%{seq:, tree:, receipt_digests: [..]}`.
    * `:addendum` - `%{session:, tree:, seq:, cited_digests: [..], outcome: "confirm"}`;
      `seq` must be greater than the settlement's `seq`.
  """

  @type reason :: {atom(), term()}

  @spec check(map()) :: :ok | {:refuse, [reason()]}
  def check(inputs) when is_map(inputs) do
    tree = fetch(inputs, :tree)
    ctx = fetch(inputs, :context_digest)

    reasons =
      List.flatten([
        base(tree, ctx),
        offline(fetch(inputs, :offline), tree, ctx),
        offline_targets(inputs, tree, ctx),
        targets(inputs, tree, ctx),
        scenarios(inputs),
        findings(fetch(inputs, :findings)),
        verdict(fetch(inputs, :verdict), tree),
        addendum(inputs, tree)
      ])

    case reasons |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> :ok
      reasons -> {:refuse, reasons}
    end
  end

  def check(_), do: {:refuse, [{:invalid_inputs, "inputs must be a map"}]}

  @doc "Digests the join must see cited: the offline receipt and every selected target receipt."
  @spec receipt_digests(map()) :: [String.t()]
  def receipt_digests(inputs) do
    offline = List.wrap(get(fetch(inputs, :offline), :sha256))

    targets =
      inputs
      |> fetch(:target_receipts, [])
      |> List.wrap()
      |> Enum.map(&get(&1, :sha256))

    (offline ++ targets) |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()
  end

  defp base(tree, ctx) do
    [
      if(blank?(tree), do: {:missing_tree, nil}),
      if(blank?(ctx), do: {:missing_context_digest, nil})
    ]
  end

  defp offline(nil, _, _), do: [{:missing_offline_receipt, nil}]

  defp offline(receipt, tree, ctx) do
    [
      if(get(receipt, :status) != "passed", do: {:offline_not_passed, get(receipt, :status)}),
      if(blank?(get(receipt, :sha256)), do: {:offline_receipt_unbound, nil}),
      binding(:offline, receipt, tree, ctx)
    ]
  end

  defp offline_targets(inputs, tree, ctx) do
    selected = fetch(inputs, :selected_offline_targets)
    receipts = fetch(inputs, :offline_target_receipts)

    with :ok <- valid_target_ids(selected, :selected_offline_targets),
         :ok <- valid_offline_receipts(receipts) do
      recorded = Enum.map(receipts, &get(&1, :target))
      missing = selected -- recorded
      unexpected = recorded -- selected

      membership_reasons =
        Enum.map(missing, &{:missing_offline_target_receipt, &1}) ++
          Enum.map(unexpected, &{:unexpected_offline_target_receipt, &1})

      receipt_reasons =
        Enum.flat_map(receipts, fn receipt ->
          target = get(receipt, :target)

          [
            if(get(receipt, :status) != "passed", do: {:offline_target_not_passed, target}),
            if(blank?(get(receipt, :sha256)), do: {:offline_target_receipt_unbound, target}),
            binding(:offline_target, receipt, tree, ctx) |> retag(target)
          ]
          |> List.flatten()
          |> Enum.reject(&is_nil/1)
        end)

      membership_reasons ++ receipt_reasons
    else
      {:error, field, reason} -> [{:invalid_offline_target_ids, %{field: field, reason: reason}}]
    end
  end

  defp valid_offline_receipts(receipts) when is_list(receipts) do
    ids = Enum.map(receipts, &get(&1, :target))

    case valid_target_ids(ids, :offline_target_receipts) do
      :ok -> :ok
      error -> error
    end
  end

  defp valid_offline_receipts(nil), do: {:error, :offline_target_receipts, :missing}
  defp valid_offline_receipts(_), do: {:error, :offline_target_receipts, :not_a_list}

  defp valid_target_ids(ids, field) when is_list(ids) do
    cond do
      Enum.any?(ids, &(not is_binary(&1) or String.trim(&1) == "")) ->
        {:error, field, :blank_or_non_string}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, field, :duplicate}

      true ->
        :ok
    end
  end

  defp valid_target_ids(nil, field), do: {:error, field, :missing}
  defp valid_target_ids(_, field), do: {:error, field, :not_a_list}

  defp binding(kind, receipt, tree, ctx) do
    [
      if(get(receipt, :tree) != tree,
        do: {:"stale_#{kind}_tree", %{expected: tree, actual: get(receipt, :tree)}}
      ),
      if(get(receipt, :context_digest) != ctx,
        do: {:"stale_#{kind}_context", %{expected: ctx, actual: get(receipt, :context_digest)}}
      )
    ]
  end

  defp targets(inputs, tree, ctx) do
    selected = inputs |> fetch(:selected_targets, []) |> List.wrap()
    receipts = inputs |> fetch(:target_receipts, []) |> List.wrap()

    recorded = Enum.map(receipts, &get(&1, :target))

    unselected =
      recorded
      |> Enum.reject(&(&1 in selected))
      |> Enum.uniq()
      |> Enum.map(&{:unexpected_target_receipt, &1})

    per_target =
      for target <- selected do
        case Enum.filter(receipts, &(get(&1, :target) == target)) do
          [] ->
            [{:missing_target_receipt, target}]

          list ->
            # Exactly one receipt per selected target; every receipt present is
            # still checked, so a stale one is never hidden beside a good one.
            [
              if(length(list) > 1, do: {:duplicate_target_receipt, target}),
              Enum.map(list, fn r ->
                [
                  if(get(r, :status) != "passed", do: {:target_not_passed, target}),
                  if(blank?(get(r, :sha256)), do: {:target_receipt_unbound, target}),
                  binding(:target, r, tree, ctx) |> retag(target)
                ]
              end)
            ]
        end
      end

    [unselected | per_target]
  end

  defp retag(list, target),
    do:
      Enum.map(list, fn
        nil -> nil
        {_tag, detail} -> {:stale_target_receipt, %{target: target, detail: detail}}
      end)

  defp scenarios(inputs) do
    map = fetch(inputs, :scenarios, %{})
    map = if is_map(map), do: map, else: %{}
    ids = fetch(inputs, :scenario_ids, Map.keys(map))

    if ids == [] do
      [{:no_scenarios, nil}]
    else
      for id <- ids, Map.get(map, id) not in [true, :satisfied, "satisfied"] do
        {:scenario_unsatisfied, id}
      end
    end
  end

  defp findings(nil), do: []

  defp findings(list) do
    for f <- List.wrap(list),
        get(f, :blocking) == true and get(f, :status) in ["open", :open, nil] do
      {:open_blocking_finding, get(f, :id)}
    end
  end

  defp verdict(nil, _), do: [{:missing_verdict, nil}]

  defp verdict(v, tree) do
    [
      if(get(v, :verdict) != "accept", do: {:verdict_not_accept, get(v, :verdict)}),
      if(blank?(get(v, :session)), do: {:verdict_without_session, nil}),
      if(get(v, :tree) != tree,
        do: {:verdict_wrong_tree, %{expected: tree, actual: get(v, :tree)}}
      ),
      if(get(v, :provisional) != false and get(v, :final) != true,
        do: {:provisional_verdict, nil}
      )
    ]
  end

  defp addendum(inputs, tree) do
    settlement = fetch(inputs, :settlement)
    add = fetch(inputs, :addendum)
    cited = inputs |> receipt_digests()

    cond do
      is_nil(settlement) ->
        [{:missing_settlement, nil}] ++ addendum_only(add, tree)

      is_nil(add) ->
        [{:missing_addendum, nil}]

      true ->
        addendum_only(add, tree) ++ settlement_requirements(settlement, add, tree, cited)
    end
  end

  defp settlement_requirements(settlement, add, tree, cited) do
    [
      if(get(settlement, :tree) != tree,
        do: {:settlement_wrong_tree, %{expected: tree, actual: get(settlement, :tree)}}
      ),
      if(
        not (is_integer(get(add, :seq)) and is_integer(get(settlement, :seq)) and
               get(add, :seq) > get(settlement, :seq)),
        do: {:addendum_not_after_settlement, nil}
      ),
      if(sorted(get(settlement, :receipt_digests)) != cited,
        do: {:settlement_digest_mismatch, nil}
      ),
      if(sorted(get(add, :cited_digests)) != cited,
        do: {:addendum_digest_mismatch, %{expected: cited}}
      )
    ]
  end

  defp addendum_only(nil, _), do: [{:missing_addendum, nil}]

  defp addendum_only(add, tree) do
    [
      if(get(add, :outcome) != "confirm", do: {:addendum_not_confirm, get(add, :outcome)}),
      if(blank?(get(add, :session)), do: {:addendum_without_session, nil}),
      if(get(add, :tree) != tree,
        do: {:addendum_wrong_tree, %{expected: tree, actual: get(add, :tree)}}
      )
    ]
  end

  defp sorted(list) when is_list(list), do: list |> Enum.uniq() |> Enum.sort()
  defp sorted(_), do: :invalid

  defp fetch(map, key, default \\ nil)

  defp fetch(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp fetch(_map, _key, default), do: default

  defp get(map, key) when is_map(map), do: fetch(map, key)
  defp get(_, _), do: nil

  defp blank?(v), do: not is_binary(v) or String.trim(v) == ""
end
