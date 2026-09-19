defmodule Kogen.Build.Verification do
  @moduledoc false

  alias Kogen.Build.TargetEvidence
  alias Kogen.Build.VerificationPlan

  @version 1

  def initialize(tracking_path, token, outer_attempt, targets, retries, plan \\ nil) do
    VerificationPlan.trace("Kogen.Build.Verification.initialize")
    root = project_root(tracking_path)
    build_id = tracking_path |> Path.dirname() |> Path.basename()

    directory =
      Path.join([
        Path.dirname(tracking_path),
        "verification",
        "attempt-#{outer_attempt}-#{token}"
      ])

    context_path = Path.join(directory, "context.json")
    state_path = Path.join(directory, "state.json")
    history_path = Path.join(directory, "state-history.jsonl")
    log_root = Path.join(directory, "logs")

    context = %{
      "schema_version" => @version,
      "mode" => "unified",
      "build_id" => build_id,
      "outer_attempt" => outer_attempt,
      "attempt_token" => token,
      "project_root" => root,
      "targets" => ["check" | Enum.reject(targets, &(&1 == "check"))] |> Enum.uniq(),
      "verification_retries" => retries,
      "state_path" => Path.expand(state_path),
      "history_path" => Path.expand(history_path),
      "log_root" => Path.expand(log_root),
      "plan" => plan_context(plan)
    }

    bytes = Jason.encode!(context) <> "\n"

    initial_state = %{
      "schema_version" => @version,
      "context_sha256" => sha256(bytes),
      "attempt_token" => token,
      "outer_attempt" => outer_attempt,
      "developer_session_id" => nil,
      "candidate_id" => nil,
      "cycles" => [],
      "failures_since_pass" => 0,
      "terminal_state" => "pending"
    }

    initial_bytes = Jason.encode!(initial_state) <> "\n"

    with :ok <- File.mkdir_p(directory),
         :ok <- exclusive_write(context_path, bytes),
         :ok <- exclusive_write(state_path, initial_bytes),
         :ok <- exclusive_write(history_path, initial_bytes),
         :ok <- File.mkdir_p(log_root) do
      {:ok,
       %{
         context: context,
         context_path: Path.expand(context_path),
         context_bytes: bytes,
         context_sha256: sha256(bytes),
         state_path: Path.expand(state_path),
         state_bytes: nil,
         history_path: Path.expand(history_path),
         history_bytes: nil
       }}
    else
      {:error, reason} ->
        {:error, "could not initialize unified verification context: #{inspect(reason)}"}
    end
  end

  defp plan_context(nil), do: nil

  defp plan_context(plan),
    do:
      Map.take(plan, [:catalog_sha256, :offline, :affected_paths, :rehearsals])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

  def environment(execution) do
    [
      {"KOGEN_VERIFICATION_CONTEXT", execution.context_path},
      {"KOGEN_VERIFICATION_RETRY_LIMIT",
       Integer.to_string(execution.context["verification_retries"])}
    ]
  end

  def settle(execution, session_id, candidate_id) do
    VerificationPlan.trace("Kogen.Build.Verification.settle")
    expected_context = execution.context_bytes

    with {:ok, ^expected_context} <- File.read(execution.context_path),
         {:ok, bytes} <- File.read(execution.state_path),
         {:ok, history_bytes} <- File.read(execution.history_path),
         {:ok, state} when is_map(state) <- Jason.decode(bytes),
         :ok <- validate_history(history_bytes, state),
         :ok <- validate_state(state, execution, session_id, candidate_id) do
      {:ok, %{execution | state_bytes: bytes, history_bytes: history_bytes}, state}
    else
      {:ok, _changed} ->
        {:error, "unified verification context changed during Developer turn"}

      {:error, :enoent} ->
        {:error, "unified verification produced no bound settlement"}

      {:error, reason} when is_atom(reason) ->
        {:error, "could not read unified verification settlement: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "unified verification settlement is malformed"}
    end
  end

  def unchanged?(%{state_bytes: bytes, history_bytes: history_bytes} = execution)
      when is_binary(bytes) and is_binary(history_bytes) do
    File.read(execution.context_path) == {:ok, execution.context_bytes} and
      File.read(execution.state_path) == {:ok, bytes} and
      File.read(execution.history_path) == {:ok, history_bytes}
  end

  def unchanged?(_), do: false

  def final_receipts(%{"cycles" => cycles}), do: List.last(cycles)["receipts"]

  defp validate_history(bytes, state) do
    entries =
      bytes
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode/1)

    case entries do
      [{:ok, %{"cycles" => []}} | _] ->
        decoded = Enum.map(entries, fn {:ok, entry} -> entry end)

        if length(decoded) == length(state["cycles"]) + 1 and List.last(decoded) == state,
          do: :ok,
          else: {:error, "unified verification chronology is incomplete or rolled back"}

      _ ->
        {:error, "unified verification chronology is malformed"}
    end
  rescue
    _ -> {:error, "unified verification chronology is malformed"}
  end

  defp validate_state(state, execution, session_id, candidate_id) do
    cycles = state["cycles"]
    terminal = state["terminal_state"]

    with true <- state["schema_version"] == @version,
         true <- state["context_sha256"] == execution.context_sha256,
         true <- state["attempt_token"] == execution.context["attempt_token"],
         true <- state["outer_attempt"] == execution.context["outer_attempt"],
         true <- state["developer_session_id"] == session_id,
         true <- terminal in ["passed", "exhausted"],
         true <- is_list(cycles) and cycles != [],
         :ok <- validate_cycles(cycles, execution.context, session_id),
         true <- List.last(cycles)["candidate_id"] == candidate_id,
         true <- valid_terminal?(state, execution.context) do
      :ok
    else
      false -> {:error, "unified verification settlement has stale or contradictory binding"}
      {:error, _} = error -> error
      _ -> {:error, "unified verification settlement is malformed"}
    end
  end

  # This mirrors the complete protocol predicate so contradictory combinations
  # are rejected together rather than accepted by partial validators.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_cycles(cycles, context, session_id) do
    expected_targets = context["targets"]

    Enum.reduce_while(Enum.with_index(cycles, 1), {:ok, 0}, fn {cycle, sequence},
                                                               {:ok, failures} ->
      receipts = cycle["receipts"]
      status = cycle["status"]
      after_count = if status == "passed", do: 0, else: failures + 1

      valid =
        is_map(cycle) and cycle["sequence"] == sequence and
          cycle["attempt_token"] == context["attempt_token"] and
          cycle["outer_attempt"] == context["outer_attempt"] and
          cycle["developer_session_id"] == session_id and
          is_binary(cycle["candidate_id"]) and cycle["candidate_id"] != "" and
          cycle["failures_before"] == failures and cycle["failures_after"] == after_count and
          status in ["passed", "failed"] and valid_receipts?(receipts, expected_targets, cycle)

      if valid,
        do: {:cont, {:ok, after_count}},
        else:
          {:halt,
           {:error, "unified verification cycle #{sequence} is incomplete or contradictory"}}
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_receipts?(receipts, targets, cycle) when is_list(receipts) and receipts != [] do
    names = Enum.map(receipts, & &1["target"])
    status = cycle["status"]
    failed = Enum.filter(receipts, &(&1["status"] == "failed"))

    prefix? = names == Enum.take(targets, length(names))
    complete? = status != "passed" or names == targets

    failure? =
      (status == "passed" and failed == []) or
        (status == "failed" and length(failed) == 1 and List.last(receipts)["status"] == "failed")

    prefix? and complete? and failure? and
      Enum.all?(receipts, &valid_receipt?(&1, cycle))
  end

  defp valid_receipts?(_, _, _), do: false

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_receipt?(receipt, cycle) when is_map(receipt) and is_map(cycle) do
    status = receipt["status"]
    evidence = receipt["target_evidence"]

    status in ["passed", "failed"] and is_integer(receipt["exit_code"]) and
      ((status == "passed" and receipt["exit_code"] == 0) or
         (status == "failed" and receipt["exit_code"] != 0)) and
      receipt["candidate_id"] == cycle["candidate_id"] and
      receipt["developer_session_id"] == cycle["developer_session_id"] and
      receipt["attempt_token"] == cycle["attempt_token"] and
      receipt["cycle_sequence"] == cycle["sequence"] and
      is_binary(receipt["finished_at"]) and valid_timestamp?(receipt["finished_at"]) and
      (is_nil(evidence) or
         (evidence["attempt_token"] == cycle["attempt_token"] and
            evidence["target"] == receipt["target"] and TargetEvidence.verify(evidence) == :ok))
  end

  defp valid_receipt?(_receipt, _cycle), do: false

  defp valid_timestamp?(value) do
    match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))
  end

  defp project_root(tracking_path) do
    expanded = Path.expand(tracking_path)
    marker = Path.join([".kogen", "runtime", "scenario-tracking"])

    case String.split(expanded, marker, parts: 2) do
      [prefix, _suffix] when prefix != "" -> String.trim_trailing(prefix, "/")
      _ -> File.cwd!() |> Path.expand()
    end
  end

  defp valid_terminal?(state, context) do
    last = List.last(state["cycles"])
    failures = last["failures_after"]

    case state["terminal_state"] do
      "passed" ->
        last["status"] == "passed" and state["failures_since_pass"] == 0

      "exhausted" ->
        last["status"] == "failed" and failures == context["verification_retries"] + 1 and
          state["failures_since_pass"] == failures
    end
  end

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        result = IO.binwrite(io, bytes)
        File.close(io)
        result

      error ->
        error
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
