defmodule Kogen.Build.DispatchLedger do
  @moduledoc """
  The controller's record of actual provider dispatches, and the failure
  classification derived from it.

  A dispatch is one supervised child of a provider-backed target that
  actually started (its process-group identity was registered). Each is
  recorded exactly once, keyed by `{cycle, target, attempt}` where `attempt`
  is `"initial"`, `"provider-retry"` or `"same-tree-retry"`. Concurrency is a resource ceiling,
  never a spend count: a target dispatched in parallel with others counts one
  dispatch, a reused receipt counts none, a target that never started counts
  none.

  Entries are plain JSON maps stored in the verification state
  (`state["dispatch_ledger"]`) with a digest (`state["dispatch_ledger_sha256"]`)
  and validated on settlement by `validate/2`.

  `classify/3` derives a failure's class from the ledger and typed evidence,
  never from an exit status alone:

    * an explicit provider marker is `provider` (a login rejection is
      `environment`);
    * a custody or supervisor failure, a toolchain/account failure, a missing
      or non-integer exit, a failed cleanup, or a timeout without a marker is
      `environment` with `pending_evidence: true`;
    * a failure with no recorded dispatch is `offline`;
    * any other failure of a dispatched target is `paid`.
  """

  @attempts ~w(initial provider-retry same-tree-retry)
  @digest ~r/^[0-9a-f]{64}$/

  @doc "An empty ledger."
  def new, do: []

  @doc """
  Starts an entry for a dispatch whose child `group` identity is registered.
  """
  @spec begin(map(), map()) :: map()
  def begin(binding, group) do
    %{
      "target" => binding.target,
      "candidate_id" => binding.candidate_id,
      "cycle" => binding.cycle,
      "attempt" => binding.attempt || "initial",
      "pid" => group["pid"],
      "pgid" => group["pgid"],
      "process_started_at" => group["started_at"],
      "started_at" => now(),
      "finished_at" => nil,
      "outcome" => "running"
    }
  end

  @doc """
  Finishes an entry from run facts (`{:ok, facts}`) or a failure
  (`{:error, reason}`); `cancelled?` marks a run the controller reaped.
  """
  @spec finish(map(), {:ok, map()} | {:error, String.t()}, boolean()) :: map()
  def finish(entry, result, cancelled? \\ false)

  def finish(entry, {:ok, facts}, cancelled?) do
    Map.merge(entry, %{
      "finished_at" => facts["finished_at"] || now(),
      "exit_code" => facts["exit_code"],
      "outcome" => if(cancelled?, do: "cancelled", else: "exited")
    })
  end

  def finish(entry, {:error, _reason}, cancelled?) do
    outcome = if cancelled?, do: "cancelled", else: "transport_error"
    Map.merge(entry, %{"finished_at" => now(), "outcome" => outcome})
  end

  @doc """
  Marks the entries of a job that the controller reaped as `cancelled`.
  """
  def mark_cancelled(entries),
    do: Enum.map(entries, &Map.put(&1, "outcome", "cancelled"))

  @doc """
  Appends `entries` (one settled job's dispatches) to `ledger`, assigning
  sequence numbers. An entry whose key is already present is not added twice.
  """
  @spec append([map()], [map()]) :: [map()]
  def append(ledger, entries) do
    Enum.reduce(entries, ledger, fn entry, acc ->
      if Enum.any?(acc, &(key(&1) == key(entry))),
        do: acc,
        else: acc ++ [Map.put(entry, "seq", length(acc) + 1)]
    end)
  end

  @doc "The entries of one cycle."
  def for_cycle(ledger, cycle), do: Enum.filter(ledger, &(&1["cycle"] == cycle))

  @doc "Number of actual dispatches (each recorded once)."
  def count(ledger), do: length(ledger)

  @doc "The digest of a ledger, over its canonical JSON."
  def digest(ledger), do: sha256(Jason.encode!(ledger))

  @doc """
  Whether `target` has a recorded dispatch in `cycle`.
  """
  def dispatched?(ledger, cycle, target),
    do: Enum.any?(ledger, &(&1["cycle"] == cycle and &1["target"] == target))

  @doc """
  Validates a ledger against the cycles it belongs to: well-formed entries,
  unique keys, contiguous sequence, every entry bound to an existing cycle
  and its Candidate, and every retry preceded by its initial dispatch.
  """
  @spec validate([map()], [map()]) :: :ok | {:error, String.t()}
  def validate(ledger, cycles) when is_list(ledger) and is_list(cycles) do
    keys = Enum.map(ledger, &key/1)

    cond do
      not Enum.all?(ledger, &valid_entry?(&1, cycles)) ->
        {:error, "dispatch ledger has a malformed or unbound entry"}

      length(Enum.uniq(keys)) != length(keys) ->
        {:error, "dispatch ledger records a dispatch more than once"}

      Enum.map(ledger, & &1["seq"]) != Enum.to_list(1..length(ledger)//1) ->
        {:error, "dispatch ledger sequence is not contiguous"}

      not Enum.all?(ledger, &retry_has_initial?(&1, keys)) ->
        {:error, "dispatch ledger has a retry without an initial dispatch"}

      true ->
        :ok
    end
  end

  def validate(_ledger, _cycles), do: {:error, "dispatch ledger is not a list"}

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_entry?(entry, cycles) when is_map(entry) do
    cycle = is_integer(entry["cycle"]) && Enum.at(cycles, entry["cycle"] - 1)

    is_map(cycle) and is_integer(entry["seq"]) and is_binary(entry["target"]) and
      entry["attempt"] in @attempts and cycle["candidate_id"] == entry["candidate_id"] and
      (entry["role"] == "reviewer" or
         (is_integer(entry["pid"]) and is_binary(entry["process_started_at"]))) and
      is_binary(entry["started_at"]) and
      entry["outcome"] in ~w(exited cancelled transport_error) and
      entry["cycle"] == cycle["sequence"]
  end

  defp valid_entry?(_entry, _cycles), do: false

  defp retry_has_initial?(%{"attempt" => attempt} = entry, keys)
       when attempt in ["provider-retry", "same-tree-retry"],
       do: {entry["cycle"], entry["target"], "initial"} in keys

  defp retry_has_initial?(_entry, _keys), do: true

  defp key(entry), do: {entry["cycle"], entry["target"], entry["attempt"]}

  @doc "True when `digest` looks like a sha256 hex digest."
  def digest?(digest), do: is_binary(digest) and Regex.match?(@digest, digest)

  @doc """
  Classifies a failed receipt of a target.

  `evidence` is a map of typed facts: `"kind"` (the failure kind:
  `"target"`, `"runner"`, `"target_evidence"`, `"candidate_mutation"`,
  `"prepare"`, `"catalog"`, `"proof"`), `"provider_backed"`, `"marker"` (an
  explicit `Kogen.Harness.ProviderMarker` result, or nil), `"exit_code"`,
  `"timed_out"`, `"cleanup"`, `"credential_scope_refusal"` (the output carries a
  `Kogen.Codex.State` scope refusal), `"target"` and `"cycle"`.

  Returns `%{"class" => class, "pending_evidence" => boolean, "reason" => text}`.
  """
  @spec classify(list(), map()) :: map()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def classify(ledger, evidence) do
    cycle = evidence["cycle"]
    target = evidence["target"]

    cond do
      match?(%{"kind" => "login_rejected"}, evidence["marker"]) ->
        result("environment", false, "provider login was rejected")

      is_map(evidence["marker"]) ->
        result("provider", false, "explicit provider marker #{evidence["marker"]["kind"]}")

      evidence["kind"] == "runner" ->
        result("environment", true, "supervisor or custody error")

      evidence["credential_scope_refusal"] == true ->
        result("environment", false, "Kogen credential scope refused the launch")

      evidence["provider_backed"] != true ->
        result("offline", false, "offline target failure")

      not dispatched?(ledger, cycle, target) ->
        result("offline", false, "failure before any provider dispatch")

      evidence["cleanup"] == "failed" ->
        result("environment", true, "process cleanup failed")

      not is_integer(evidence["exit_code"]) ->
        result("environment", true, "no exit status was reported")

      evidence["timed_out"] == true ->
        result("environment", true, "timed out without a provider marker")

      true ->
        result("paid", false, "dispatched target failed")
    end
  end

  defp result(class, pending, reason),
    do: %{"class" => class, "pending_evidence" => pending, "reason" => reason}

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
