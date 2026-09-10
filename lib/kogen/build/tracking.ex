defmodule Kogen.Build.Tracking do
  @moduledoc """
  Build-owned, append-oriented persistence for one scenario-tracking run.

  A tracking state is deliberately process-local: it contains the exact bytes
  last written by this controller. `verify/1` compares those bytes before an
  external boundary, and `update/2` refuses to replace a record that changed
  underneath the controller. Records are evidence only; this module never
  reloads one as Build state.
  """

  @runtime_base ".kogen/runtime/scenario-tracking"
  @record_name "record.json"
  @schema_version 1

  @type tracking_record :: %{required(String.t()) => term()}
  @type state :: %{path: Path.t(), bytes: binary(), record: tracking_record()}

  @doc """
  Creates one exclusively-owned runtime record for this Build.

  `contract` is the already validated Approved contract and must contain its
  scenarios and risks under either string or atom keys. `approved_entries` is
  the Build's frozen package-entry snapshot; only its SHA-256 digest is stored.
  """
  @spec new(map(), map(), list()) :: {:ok, state()} | {:error, String.t()}
  def new(intent, contract, approved_entries) when is_map(intent) and is_map(contract) do
    with {:ok, frozen_intent} <- freeze_intent(intent),
         {:ok, scenarios} <- required_json_value(contract, "scenarios"),
         {:ok, risks, risks_supplied} <- frozen_risks(contract),
         true <- is_list(scenarios),
         {:ok, path} <- create_record_path(),
         record <-
           initial_record(frozen_intent, scenarios, risks, risks_supplied, approved_entries),
         {:ok, state} <- write_initial(path, record) do
      {:ok, state}
    else
      false -> {:error, "scenario tracking contract has invalid scenarios"}
      {:error, _reason} = error -> error
    end
  end

  def new(_intent, _contract, _approved_entries),
    do: {:error, "scenario tracking requires intent and contract maps"}

  @doc """
  Confirms that the record on disk remains byte-for-byte the controller's last
  persisted state. It never writes or attempts recovery.
  """
  @spec verify(state()) :: :ok | {:error, String.t()}
  def verify(%{path: path, bytes: expected}) when is_binary(path) and is_binary(expected) do
    case File.read(path) do
      {:ok, ^expected} ->
        :ok

      {:ok, _other} ->
        {:error, "scenario tracking record changed outside Build: #{path}"}

      {:error, reason} ->
        {:error, "could not read scenario tracking record #{path}: #{inspect(reason)}"}
    end
  end

  def verify(_state), do: {:error, "invalid scenario tracking state"}

  @doc """
  Verifies a cited file using its actual owner. Ordinary evidence stays frozen
  to the inspected digest. A citation of this Build's authoritative record is
  retained as a historical version, while the live file must match the latest
  controller-owned bytes. Only this exact path receives that ownership rule;
  external edits still fail `verify/1`, even when a role cited the record.
  """
  @spec verify_reference(state(), Path.t(), map()) :: :ok | {:error, String.t()}
  def verify_reference(state, path, snapshot) do
    if Path.expand(path) == Path.expand(state.path) do
      verify(state)
    else
      verify_frozen_reference(path, snapshot)
    end
  end

  defp verify_frozen_reference(path, snapshot) do
    case File.read(path) do
      {:ok, bytes} ->
        if Base.encode16(:crypto.hash(:sha256, bytes)) == snapshot["sha256"],
          do: :ok,
          else: {:error, "bound evidence reference mutated: #{path}"}

      _ ->
        {:error, "bound evidence reference missing: #{path}"}
    end
  end

  @doc """
  Atomically replaces the record after verifying its previous exact bytes.

  The immutable Approved snapshot fields cannot change through this generic
  update. Callers supply a complete string-keyed record so the controller's
  state remains explicit rather than hidden in this module.
  """
  @spec update(state(), tracking_record()) :: {:ok, state()} | {:error, String.t()}
  def update(%{path: path, record: previous} = state, record)
      when is_binary(path) and is_map(previous) and is_map(record) do
    with :ok <- verify(state),
         :ok <- string_keyed_map(record),
         :ok <- record_has_only_string_keys(record),
         :ok <- preserve_frozen_fields(previous, record),
         :ok <- preserve_finding_history(previous, record),
         {:ok, bytes} <- encode(record),
         :ok <- atomic_replace(path, bytes) do
      {:ok, %{path: path, bytes: bytes, record: record}}
    end
  end

  def update(_state, _record), do: {:error, "invalid scenario tracking update"}

  @doc "Adds a pending Build-owned attempt to the record."
  @spec start_attempt(state(), String.t(), non_neg_integer()) ::
          {:ok, state()} | {:error, String.t()}
  def start_attempt(state, token, number)
      when is_binary(token) and token != "" and is_integer(number) and number >= 0 do
    attempt = %{"attempt_token" => token, "number" => number, "status" => "pending"}
    record = Map.update!(state.record, "attempts", &(&1 ++ [attempt]))
    update(state, record)
  end

  def start_attempt(_state, _token, _number), do: {:error, "invalid scenario tracking attempt"}

  @doc "Returns blocking findings whose latest disposition is still open."
  @spec open_findings(state()) :: [tracking_record()]
  def open_findings(%{record: %{"findings" => findings}}) when is_list(findings) do
    Enum.filter(findings, &(Map.get(&1, "status") == "open"))
  end

  def open_findings(_state), do: []

  @doc """
  Applies a previously validated complete Reviewer verdict in one record update.

  The validator owns verdict correctness and bound-input checks. This helper
  only persists the transition: it attaches the verdict to the latest attempt,
  appends reviewer dispositions, assigns new immutable `F1`, `F2`, … IDs, and
  sets the Build status to `accepted` or `rework`.
  """
  @spec apply_verdict(state(), map(), String.t()) :: {:ok, state()} | {:error, String.t()}
  def apply_verdict(state, verdict, reviewer_session),
    do: apply_verdict(state, verdict, reviewer_session, nil)

  @doc """
  Like `apply_verdict/3`, retaining Build-owned reference snapshots with the
  latest attempt in the same atomic record update.
  """
  @spec apply_verdict(state(), map(), String.t(), map() | nil) ::
          {:ok, state()} | {:error, String.t()}
  def apply_verdict(state, verdict, reviewer_session, reference_snapshots)
      when is_map(verdict) and is_binary(reviewer_session) and reviewer_session != "" do
    with {:ok, decision} <- verdict_decision(verdict),
         :ok <- valid_reference_snapshots(reference_snapshots),
         {:ok, record} <-
           verdict_record(state.record, verdict, reviewer_session, decision, reference_snapshots) do
      update(state, record)
    end
  end

  def apply_verdict(_state, _verdict, _reviewer_session, _reference_snapshots),
    do: {:error, "invalid scenario tracking verdict"}

  defp initial_record(intent, scenarios, risks, risks_supplied, approved_entries) do
    %{
      "schema_version" => @schema_version,
      "purpose" => "inspection evidence; not a recovery checkpoint",
      "intent" => intent,
      "approved_package_digest" => approved_digest(approved_entries),
      "scenarios" => scenarios,
      "risks" => risks,
      "risks_supplied" => risks_supplied,
      "attempts" => [],
      "findings" => [],
      "status" => "pending"
    }
  end

  defp freeze_intent(intent) do
    raw = fetch(intent, "raw") || intent

    case json_value(raw) do
      {:ok, frozen} when is_map(frozen) ->
        with :ok <- string_keyed_map(frozen), do: {:ok, frozen}

      {:ok, _other} ->
        {:error, "scenario tracking intent is not a string-keyed map"}

      {:error, _reason} = error ->
        error
    end
  end

  defp required_json_value(map, key) do
    case fetch(map, key) do
      nil -> {:error, "scenario tracking contract missing #{key}"}
      value -> json_value(value)
    end
  end

  defp frozen_risks(contract) do
    case fetch(contract, "risks") do
      nil ->
        {:ok, [], false}

      risks ->
        with {:ok, normalized} <- json_value(risks),
             true <- is_list(normalized) do
          {:ok, normalized, fetch(contract, "risks_supplied") != false}
        else
          false -> {:error, "scenario tracking contract has invalid risks"}
          {:error, _reason} = error -> error
        end
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp json_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp json_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case json_value(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp json_value(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with true <- is_binary(key) or is_atom(key),
           {:ok, normalized} <- json_value(value) do
        {:cont, {:ok, Map.put(acc, to_string(key), normalized)}}
      else
        false -> {:halt, {:error, "scenario tracking record must contain JSON values"}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp json_value(_value), do: {:error, "scenario tracking record must contain JSON values"}

  defp string_keyed_map(map) do
    if Enum.all?(Map.keys(map), &is_binary/1),
      do: :ok,
      else: {:error, "scenario tracking record must use string keys"}
  end

  defp record_has_only_string_keys(record) do
    case json_value(record) do
      {:ok, ^record} -> :ok
      _ -> {:error, "scenario tracking record must use string keys at every level"}
    end
  end

  defp preserve_frozen_fields(previous, record) do
    fields = ~w(schema_version intent approved_package_digest scenarios risks risks_supplied)

    if Enum.all?(fields, &(Map.get(previous, &1) == Map.get(record, &1))),
      do: :ok,
      else: {:error, "scenario tracking update changed frozen Approved inputs"}
  end

  defp preserve_finding_history(%{"findings" => previous}, %{"findings" => current})
       when is_list(previous) and is_list(current) do
    if Enum.all?(previous, &preserved_finding?(&1, current)) do
      :ok
    else
      {:error, "scenario tracking update changed immutable finding history"}
    end
  end

  defp preserve_finding_history(_previous, _record),
    do: {:error, "scenario tracking record has invalid findings"}

  defp preserved_finding?(%{"id" => id, "origin" => origin} = finding, current)
       when is_binary(id) and is_map(origin) do
    case Enum.find(current, &(Map.get(&1, "id") == id)) do
      %{"origin" => ^origin} = replacement ->
        history = Map.get(finding, "disposition_history", [])
        updated_history = Map.get(replacement, "disposition_history", [])

        is_list(history) and is_list(updated_history) and
          List.starts_with?(updated_history, history)

      _ ->
        false
    end
  end

  defp preserved_finding?(_finding, _current), do: false

  defp create_record_path do
    case File.mkdir_p(@runtime_base) do
      :ok ->
        create_record_directory(0)

      {:error, reason} ->
        {:error, "could not create scenario tracking runtime root: #{inspect(reason)}"}
    end
  end

  defp create_record_directory(attempt) when attempt < 10 do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(@runtime_base, id)

    case File.mkdir(directory) do
      :ok ->
        File.chmod!(directory, 0o700)
        {:ok, Path.join(directory, @record_name)}

      {:error, :eexist} ->
        create_record_directory(attempt + 1)

      {:error, reason} ->
        {:error, "could not create exclusive scenario tracking directory: #{inspect(reason)}"}
    end
  end

  defp create_record_directory(_attempt),
    do: {:error, "could not create a unique scenario tracking directory"}

  defp write_initial(path, record) do
    with {:ok, bytes} <- encode(record),
         :ok <- write_exclusive(path, bytes) do
      {:ok, %{path: path, bytes: bytes, record: record}}
    end
  end

  defp encode(record) do
    {:ok, Jason.encode!(record) <> "\n"}
  rescue
    _error -> {:error, "could not encode scenario tracking record"}
  end

  defp write_exclusive(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- IO.binwrite(io, bytes), :ok <- :file.sync(io) do
            :ok
          else
            {:error, reason} ->
              {:error, "could not write scenario tracking record: #{inspect(reason)}"}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, "could not create scenario tracking record: #{inspect(reason)}"}
    end
  end

  defp atomic_replace(path, bytes) do
    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- write_exclusive(temporary, bytes),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "could not replace scenario tracking record: #{inspect(reason)}"}
      end
    after
      File.rm(temporary)
    end
  end

  defp approved_digest(entries) do
    entries
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp verdict_decision(verdict) do
    case fetch(verdict, "verdict") do
      "accept" -> {:ok, "accepted"}
      "rework" -> {:ok, "rework"}
      _ -> {:error, "scenario tracking verdict has invalid decision"}
    end
  end

  defp verdict_record(
         %{"attempts" => attempts, "findings" => findings} = record,
         verdict,
         session,
         decision,
         reference_snapshots
       )
       when is_list(attempts) and attempts != [] and is_list(findings) do
    latest = List.last(attempts)
    prior = Enum.drop(attempts, -1)
    dispositions = fetch(verdict, "dispositions") || []
    new_findings = fetch(verdict, "new_findings") || fetch(verdict, "findings") || []

    with true <- is_list(dispositions) and is_list(new_findings),
         {:ok, updated_findings} <- apply_dispositions(findings, dispositions, session, decision),
         {:ok, appended_findings} <-
           append_findings(updated_findings, new_findings, latest, session) do
      updated_attempt =
        latest
        |> Map.put("verdict", normalize_verdict(verdict))
        |> Map.put("reviewer_session", session)
        |> Map.put("status", decision)
        |> merge_reference_snapshots(reference_snapshots)

      {:ok,
       record
       |> Map.put("attempts", prior ++ [updated_attempt])
       |> Map.put("findings", appended_findings)
       |> Map.put("status", decision)}
    else
      false -> {:error, "scenario tracking verdict has invalid findings or dispositions"}
      {:error, _reason} = error -> error
    end
  end

  defp verdict_record(_record, _verdict, _session, _decision, _reference_snapshots),
    do: {:error, "scenario tracking record has no current attempt"}

  defp valid_reference_snapshots(nil), do: :ok

  defp valid_reference_snapshots(snapshots) when is_map(snapshots) do
    with :ok <- string_keyed_map(snapshots),
         {:ok, ^snapshots} <- json_value(snapshots) do
      :ok
    else
      _ -> {:error, "scenario tracking reference snapshots must be a string-keyed JSON map"}
    end
  end

  defp valid_reference_snapshots(_),
    do: {:error, "scenario tracking reference snapshots must be a string-keyed JSON map"}

  defp merge_reference_snapshots(attempt, nil), do: attempt

  defp merge_reference_snapshots(attempt, snapshots) do
    attempt
    |> Map.put("reviewer_reference_snapshots", snapshots)
    |> Map.update("reference_snapshots", snapshots, &Map.merge(&1, snapshots))
  end

  defp apply_dispositions(findings, dispositions, session, decision) do
    dispositions
    |> Enum.reduce_while({:ok, findings}, fn disposition, {:ok, current} ->
      with {:ok, normalized} <- json_value(disposition),
           true <- is_map(normalized),
           id when is_binary(id) <- Map.get(normalized, "finding_id") || Map.get(normalized, "id"),
           {:ok, status} <- disposition_status(Map.get(normalized, "status")) do
        history = %{
          "reviewer_session" => session,
          "verdict" => decision,
          "status" => status,
          "reason" => Map.get(normalized, "reason", ""),
          "evidence" => Map.get(normalized, "evidence", [])
        }

        put_disposition(current, id, status, history)
      else
        false -> {:halt, {:error, "scenario tracking verdict has invalid disposition"}}
        _ -> {:halt, {:error, "scenario tracking verdict has invalid disposition"}}
      end
    end)
  end

  defp put_disposition(findings, id, status, history) do
    case Enum.find_index(findings, &(Map.get(&1, "id") == id)) do
      nil ->
        {:halt, {:error, "scenario tracking verdict disposes unknown finding #{id}"}}

      index ->
        updated =
          findings
          |> Enum.at(index)
          |> Map.put("status", status)
          |> Map.update("disposition_history", [history], &(&1 ++ [history]))

        {:cont, {:ok, List.replace_at(findings, index, updated)}}
    end
  end

  defp disposition_status("closed"), do: {:ok, "closed"}
  defp disposition_status("open"), do: {:ok, "open"}
  defp disposition_status("remains_open"), do: {:ok, "open"}
  defp disposition_status(_), do: {:error, "invalid disposition status"}

  defp append_findings(findings, new_findings, attempt, session) do
    start = next_finding_number(findings)

    new_findings
    |> Enum.with_index(start)
    |> Enum.reduce_while({:ok, findings}, fn {finding, number}, {:ok, current} ->
      with {:ok, normalized} <- json_value(finding),
           true <- is_map(normalized),
           scenario_ids when is_list(scenario_ids) and scenario_ids != [] <-
             Map.get(normalized, "scenario_ids"),
           true <- Enum.all?(scenario_ids, &(is_binary(&1) and &1 != "")),
           reason when is_binary(reason) and reason != "" <- Map.get(normalized, "reason"),
           evidence when is_list(evidence) <- Map.get(normalized, "evidence") do
        origin = %{
          "scenario_ids" => scenario_ids,
          "reason" => reason,
          "evidence" => evidence,
          "candidate_id" => Map.get(attempt, "candidate_id"),
          "attempt_token" => Map.get(attempt, "attempt_token"),
          "reviewer_session" => session
        }

        item = %{
          "id" => "F#{number}",
          "scenario_ids" => scenario_ids,
          "status" => "open",
          "origin" => origin,
          "disposition_history" => []
        }

        {:cont, {:ok, current ++ [item]}}
      else
        false -> {:halt, {:error, "scenario tracking verdict has invalid new finding"}}
        _ -> {:halt, {:error, "scenario tracking verdict has invalid new finding"}}
      end
    end)
  end

  defp next_finding_number(findings) do
    findings
    |> Enum.map(&Map.get(&1, "id", ""))
    |> Enum.map(fn id -> Regex.run(~r/^F([1-9][0-9]*)$/, id) end)
    |> Enum.flat_map(fn
      [_, number] -> [String.to_integer(number)]
      _ -> []
    end)
    |> case do
      [] -> 1
      numbers -> Enum.max(numbers) + 1
    end
  end

  defp normalize_verdict(verdict) do
    {:ok, normalized} = json_value(verdict)
    normalized
  end
end
