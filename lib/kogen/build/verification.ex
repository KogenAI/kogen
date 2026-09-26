defmodule Kogen.Build.Verification do
  @moduledoc """
  Controller-owned verification for one outer attempt.

  After each Developer turn the Build controller (the trusted code the Build
  started with) runs one verification cycle itself: it reads the Candidate's
  catalog only as data, runs every planned Make target in rank order through
  `Kogen.Build.VerificationRunner`, re-checks the Candidate id after each
  target, and, when an admission catalog declares the integrity fields, runs
  the scenarios' proof selectors (`Kogen.Build.ProofSelectors`).

  Only this module writes the attempt's context, state and history files;
  no Developer-launched process receives their paths. Settlement never reads
  success from a file: the in-memory state is authoritative and the files
  must still hold exactly the bytes the controller wrote, with every receipt
  bound to its Candidate, attempt, context, catalog, cycle and log digest.

  Within one attempt a provider-backed target's passed receipt is reused only
  on a byte-identical Candidate id and catalog digest, marked `reused_from`;
  every offline target runs fresh every cycle. A new attempt reuses nothing.
  """

  alias Kogen.Build.{
    CatalogChange,
    ProofSelectors,
    TargetEvidence,
    VerificationPlan,
    VerificationRunner
  }

  @version 2
  @output_tail 16_384
  @digest ~r/^[0-9a-f]{64}$/

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

    context = %{
      "schema_version" => @version,
      "mode" => "controller",
      "build_id" => build_id,
      "outer_attempt" => outer_attempt,
      "attempt_token" => token,
      "project_root" => root,
      "targets" => targets,
      "verification_retries" => retries,
      "catalog_sha256" => plan && plan.catalog_sha256,
      "plan" => plan_context(plan)
    }

    bytes = Jason.encode!(context) <> "\n"

    state = %{
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

    state_bytes = Jason.encode!(state) <> "\n"
    paths = paths(directory)

    with :ok <- owned_directory(directory),
         :ok <- exclusive_write(paths.context, bytes),
         :ok <- exclusive_write(paths.state, state_bytes),
         :ok <- exclusive_write(paths.history, state_bytes),
         :ok <- File.mkdir_p(paths.logs),
         :ok <- File.mkdir_p(paths.receipts) do
      {:ok,
       %{
         context: context,
         directory: Path.expand(directory),
         context_path: paths.context,
         context_bytes: bytes,
         context_sha256: sha256(bytes),
         state_path: paths.state,
         history_path: paths.history,
         log_root: paths.logs,
         receipt_root: paths.receipts,
         state: state,
         state_bytes: state_bytes,
         history_bytes: state_bytes,
         workspace: nil
       }}
    else
      {:error, reason} ->
        {:error, "could not initialize controller verification context: #{inspect(reason)}"}
    end
  end

  defp paths(directory) do
    %{
      context: Path.expand(Path.join(directory, "context.json")),
      state: Path.expand(Path.join(directory, "state.json")),
      history: Path.expand(Path.join(directory, "state-history.jsonl")),
      logs: Path.expand(Path.join(directory, "logs")),
      receipts: Path.expand(Path.join(directory, "receipts"))
    }
  end

  defp plan_context(nil), do: nil

  defp plan_context(plan),
    do:
      Map.take(plan, [:catalog_sha256, :offline, :affected_paths, :rehearsals, :added])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

  @doc """
  Runs one controller verification cycle for `candidate_id` after a turn of
  `session_id` ends. `env` holds `:root`, `:catalog` (the admission
  catalog), `:plan`, `:scenarios`, `:base_commit` and optionally
  `:workspace` (the admission base workspace). Returns the updated execution
  and state; a failed cycle is a normal result, never an error. `{:error, _}`
  means the controller could not keep its own records.
  """
  def run_cycle(execution, session_id, candidate_id, env) do
    state = execution.state
    sequence = length(state["cycles"]) + 1
    started_at = now()
    failures = state["failures_since_pass"]

    base = %{
      "sequence" => sequence,
      "attempt_token" => execution.context["attempt_token"],
      "outer_attempt" => execution.context["outer_attempt"],
      "developer_session_id" => session_id,
      "candidate_id" => candidate_id,
      "context_sha256" => execution.context_sha256,
      "started_at" => started_at
    }

    {cycle, execution} =
      case CatalogChange.check(env.root, env.catalog, env.plan, env.scenarios) do
        {:ok, catalog} ->
          run_targets(execution, base, catalog, env)

        {:error, reason} ->
          failure = write_failure_log(execution, sequence, "catalog", reason)

          {Map.merge(base, %{
             "catalog_sha256" => nil,
             "receipts" => [],
             "proofs" => [],
             "failure" => Map.merge(failure, %{"kind" => "catalog", "target" => "catalog"})
           }), execution}
      end

    status = if cycle["failure"], do: "failed", else: "passed"
    after_count = if status == "passed", do: 0, else: failures + 1

    cycle =
      Map.merge(cycle, %{
        "status" => status,
        "failures_before" => failures,
        "failures_after" => after_count,
        "finished_at" => now()
      })

    terminal =
      cond do
        status == "passed" -> "passed"
        after_count > execution.context["verification_retries"] -> "exhausted"
        true -> "pending"
      end

    state =
      state
      |> Map.merge(%{
        "developer_session_id" => session_id,
        "candidate_id" => candidate_id,
        "cycles" => state["cycles"] ++ [cycle],
        "failures_since_pass" => after_count,
        "terminal_state" => terminal
      })

    persist(execution, state, session_id, candidate_id, cycle)
  end

  defp run_targets(execution, base, catalog, env) do
    base = Map.put(base, "catalog_sha256", catalog.sha256)

    {receipts, failure} =
      Enum.reduce_while(catalog.order, {[], nil}, fn target, {acc, nil} ->
        {receipt, failure} = target_receipt(execution, base, target, catalog, env)
        step = if failure, do: :halt, else: :cont
        {step, {acc ++ [receipt], failure}}
      end)

    {proofs, failure, execution} =
      if failure == nil and env.catalog.integrity do
        ProofSelectors.run(execution, base, env)
      else
        {[], failure, execution}
      end

    {Map.merge(base, %{"receipts" => receipts, "proofs" => proofs, "failure" => failure}),
     execution}
  end

  defp target_receipt(execution, base, target, catalog, env) do
    case reusable(execution.state["cycles"], target, base, catalog) do
      {:ok, receipt} -> {receipt, nil}
      :none -> run_target(execution, base, target, catalog, env)
    end
  end

  # A provider-backed target reuses the latest earlier passed receipt of this
  # attempt bound to the same Candidate id and catalog digest. Offline
  # targets always run fresh, whatever their name.
  defp reusable(cycles, target, base, catalog) do
    if catalog.provider_backed[target] == true do
      cycles
      |> Enum.reverse()
      |> Enum.find_value(:none, &reuse_from(&1, target, base))
    else
      :none
    end
  end

  defp reuse_from(cycle, target, base) do
    receipt = Enum.find(cycle["receipts"] || [], &(&1["target"] == target))

    if receipt && receipt["status"] == "passed" && is_nil(receipt["target_evidence_error"]) &&
         receipt["candidate_id"] == base["candidate_id"] &&
         receipt["catalog_sha256"] == base["catalog_sha256"] &&
         receipt["context_sha256"] == base["context_sha256"] do
      origin =
        receipt["reused_from"] ||
          %{"cycle_sequence" => cycle["sequence"], "log_sha256" => receipt["log_sha256"]}

      {:ok,
       receipt
       |> Map.put("cycle_sequence", base["sequence"])
       |> Map.put("developer_session_id", base["developer_session_id"])
       |> Map.put("reused_from", origin)}
    end
  end

  defp run_target(execution, base, target, catalog, env) do
    log = Path.join(execution.log_root, "cycle-#{base["sequence"]}-#{target}.log")

    case VerificationRunner.run_target(env.root, target, log) do
      {:ok, facts} ->
        receipt = receipt(execution, base, target, catalog, facts, env.root)
        {receipt, receipt_failure(receipt, base, env)}

      {:error, reason} ->
        failure = write_failure_log(execution, base["sequence"], "#{target}-supervisor", reason)
        {nil, Map.merge(failure, %{"kind" => "runner", "target" => target})}
    end
    |> case do
      {nil, failure} -> {placeholder(base, target, catalog, failure), failure}
      result -> result
    end
  end

  # A runner error still leaves a failed receipt, bound to its failure log.
  defp placeholder(base, target, catalog, failure) do
    base
    |> receipt_binding(target, catalog)
    |> Map.merge(%{
      "status" => "failed",
      "exit_code" => 1,
      "cleanup" => "failed",
      "timed_out" => false,
      "started_at" => base["started_at"],
      "finished_at" => now(),
      "elapsed_ms" => 0,
      "log_path" => failure["log_path"],
      "log_sha256" => failure["log_sha256"],
      "output" => failure["output"]
    })
  end

  defp receipt(execution, base, target, catalog, facts, root) do
    output = facts["log_bytes"]

    receipt =
      base
      |> receipt_binding(target, catalog)
      |> Map.merge(%{
        "status" => VerificationRunner.status(facts),
        "exit_code" => facts["exit_code"],
        "cleanup" => facts["cleanup"],
        "timed_out" => facts["timed_out"],
        "started_at" => facts["started_at"],
        "finished_at" => facts["finished_at"],
        "elapsed_ms" => facts["elapsed_ms"],
        "log_path" => relative(facts["log_path"], root),
        "log_sha256" => facts["log_sha256"],
        "output" => tail(output)
      })

    case TargetEvidence.capture(output, target, execution.context["attempt_token"], root) do
      {:ok, nil} -> receipt
      {:ok, evidence} -> Map.put(receipt, "target_evidence", evidence)
      {:error, reason} -> Map.put(receipt, "target_evidence_error", reason)
    end
  end

  defp receipt_binding(base, target, catalog) do
    %{
      "target" => target,
      "provider_backed" => catalog.provider_backed[target] == true,
      "candidate_id" => base["candidate_id"],
      "attempt_token" => base["attempt_token"],
      "developer_session_id" => base["developer_session_id"],
      "context_sha256" => base["context_sha256"],
      "catalog_sha256" => base["catalog_sha256"],
      "cycle_sequence" => base["sequence"]
    }
  end

  defp receipt_failure(receipt, base, env) do
    cond do
      receipt["status"] == "failed" ->
        %{
          "kind" => "target",
          "target" => receipt["target"],
          "log_path" => receipt["log_path"],
          "log_sha256" => receipt["log_sha256"],
          "output" => receipt["output"]
        }

      receipt["target_evidence_error"] ->
        %{
          "kind" => "target_evidence",
          "target" => receipt["target"],
          "log_path" => receipt["log_path"],
          "log_sha256" => receipt["log_sha256"],
          "output" =>
            "Kogen target evidence validation failed: " <> receipt["target_evidence_error"]
        }

      true ->
        candidate_mutation(receipt, base, env)
    end
  end

  defp candidate_mutation(receipt, base, env) do
    expected = base["candidate_id"]

    case candidate_id(env) do
      {:ok, ^expected} ->
        nil

      other ->
        detail =
          case other do
            {:ok, id} ->
              "Candidate mutated during verification (#{base["candidate_id"]} -> #{id})"

            {:error, reason} ->
              "Candidate identity failed during verification: #{reason}"
          end

        %{
          "kind" => "candidate_mutation",
          "target" => receipt["target"],
          "log_path" => receipt["log_path"],
          "log_sha256" => receipt["log_sha256"],
          "output" => detail
        }
    end
  end

  defp candidate_id(env) do
    case Map.get(env, :candidate_id) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Kogen.Git.candidate_id()
    end
  end

  @doc false
  def write_failure_log(execution, sequence, name, reason) do
    path = Path.join(execution.log_root, "cycle-#{sequence}-#{name}.log")
    bytes = reason <> "\n"
    _ = exclusive_write(path, bytes)

    %{
      "log_path" => relative(path, execution.context["project_root"]),
      "log_sha256" => sha256(bytes),
      "output" => tail(bytes)
    }
  end

  # Writes the receipts, state and history, then the local Verification
  # Record in its established line format.
  defp persist(execution, state, session_id, candidate_id, cycle) do
    bytes = Jason.encode!(state) <> "\n"

    with :ok <- write_receipts(execution, cycle),
         :ok <- atomic_write(execution.state_path, bytes),
         :ok <- File.write(execution.history_path, bytes, [:append]),
         :ok <- local_record(execution, session_id, candidate_id, cycle) do
      {:ok,
       %{
         execution
         | state: state,
           state_bytes: bytes,
           history_bytes: execution.history_bytes <> bytes
       }, state}
    else
      {:error, reason} ->
        {:error, "could not persist controller verification: #{inspect(reason)}"}
    end
  end

  defp write_receipts(execution, cycle) do
    Enum.reduce_while(cycle["receipts"], :ok, fn receipt, :ok ->
      path = receipt_path(execution, cycle["sequence"], receipt["target"])

      case exclusive_write(path, Jason.encode!(receipt) <> "\n") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc "The retained receipt file of `target` in cycle `sequence`."
  def receipt_path(execution, sequence, target),
    do: Path.join(execution.receipt_root, "cycle-#{sequence}-#{target}.json")

  defp local_record(execution, session_id, candidate_id, cycle) do
    failure = cycle["failure"]

    reason =
      if failure,
        do:
          "controller verification cycle #{cycle["sequence"]} failed at #{failure["target"]} (log #{failure["log_path"]}):\n" <>
            String.slice(failure["output"] || "", -2_000, 2_000),
        else: "controller verification cycle #{cycle["sequence"]} passed"

    Kogen.Check.write_record(
      %{
        "candidate" => candidate_id,
        "status" => cycle["status"],
        "target" => "check",
        "exit_code" => failed_exit(cycle),
        "session_id" => session_id,
        "attempt_token" => execution.context["attempt_token"],
        # The record describes the cycle's last target run, so it carries that
        # receipt's own finished_at: one clock for receipts and history.
        "finished_at" => record_finished_at(cycle),
        "reason" => reason
      },
      execution.context["project_root"]
    )
  end

  defp failed_exit(%{"status" => "passed"}), do: 0

  defp failed_exit(cycle) do
    case Enum.find(cycle["receipts"], &(&1["status"] == "failed")) do
      %{"exit_code" => code} when is_integer(code) and code != 0 -> code
      _ -> 1
    end
  end

  @doc """
  Settles the attempt's verification for `session_id` and `candidate_id`.
  The in-memory state is authoritative; the controller's files must still
  hold exactly its bytes, and every cycle and receipt must be bound and
  consistent. Returns the settled state.
  """
  def settle(execution, session_id, candidate_id) do
    VerificationPlan.trace("Kogen.Build.Verification.settle")
    state = execution.state

    with :ok <- files_unchanged(execution),
         :ok <- validate_state(state, execution),
         true <- state["developer_session_id"] == session_id,
         true <- state["terminal_state"] in ["passed", "exhausted"],
         true <- List.last(state["cycles"])["candidate_id"] == candidate_id do
      {:ok, execution, state}
    else
      false -> {:error, "controller verification settlement has stale or contradictory binding"}
      {:error, _reason} = error -> error
    end
  end

  def unchanged?(%{state_bytes: bytes} = execution) when is_binary(bytes),
    do: files_unchanged(execution) == :ok and logs_unchanged(execution.state, execution) == :ok

  def unchanged?(_), do: false

  defp files_unchanged(execution) do
    cond do
      File.read(execution.context_path) != {:ok, execution.context_bytes} ->
        {:error, "controller verification context changed on disk"}

      File.read(execution.state_path) != {:ok, execution.state_bytes} ->
        {:error, "controller verification state changed on disk"}

      File.read(execution.history_path) != {:ok, execution.history_bytes} ->
        {:error, "controller verification chronology is incomplete or rolled back"}

      true ->
        :ok
    end
  end

  def final_receipts(%{"cycles" => cycles}), do: List.last(cycles)["receipts"]

  @doc """
  Validates a controller state against its execution: every cycle's
  sequence, attempt, session and failure counters, and every receipt's
  binding (Candidate id, attempt token, context and catalog digests, cycle),
  its status (exit code, time limit and cleanup only), its log digest, and
  for a reused receipt the earlier passed receipt it names.
  """
  def validate_state(state, execution) do
    context = execution.context

    with true <- is_map(state) and state["schema_version"] == @version,
         true <- state["context_sha256"] == execution.context_sha256,
         true <- state["attempt_token"] == context["attempt_token"],
         true <- state["outer_attempt"] == context["outer_attempt"],
         cycles when is_list(cycles) and cycles != [] <- state["cycles"],
         :ok <- validate_cycles(cycles, execution),
         :ok <- validate_terminal(state, context),
         :ok <- logs_unchanged(state, execution) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, "controller verification settlement has stale or contradictory binding"}
    end
  end

  defp validate_cycles(cycles, execution) do
    cycles
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, 0}, fn {cycle, sequence}, {:ok, failures} ->
      after_count = if cycle["status"] == "passed", do: 0, else: failures + 1

      if valid_cycle?(cycle, sequence, failures, after_count, execution) and
           Enum.all?(cycle["receipts"], &valid_receipt?(&1, cycle, cycles, execution)),
         do: {:cont, {:ok, after_count}},
         else:
           {:halt,
            {:error, "controller verification cycle #{sequence} is incomplete or contradictory"}}
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_cycle?(cycle, sequence, failures, after_count, execution) do
    context = execution.context
    receipts = cycle["receipts"]
    failure = cycle["failure"]
    passed = cycle["status"] == "passed"

    is_map(cycle) and cycle["sequence"] == sequence and
      cycle["attempt_token"] == context["attempt_token"] and
      cycle["outer_attempt"] == context["outer_attempt"] and
      cycle["context_sha256"] == execution.context_sha256 and
      is_binary(cycle["candidate_id"]) and cycle["candidate_id"] != "" and
      cycle["failures_before"] == failures and cycle["failures_after"] == after_count and
      cycle["status"] in ["passed", "failed"] and is_list(receipts) and
      ((passed and is_nil(failure) and receipts != [] and
          Enum.all?(receipts, &(&1["status"] == "passed"))) or
         (not passed and is_map(failure)))
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_receipt?(receipt, cycle, cycles, execution) do
    is_map(receipt) and receipt["status"] in ["passed", "failed"] and
      is_integer(receipt["exit_code"]) and
      receipt["status"] ==
        VerificationRunner.status(%{
          "exit_code" => receipt["exit_code"],
          "timed_out" => receipt["timed_out"],
          "cleanup" => receipt["cleanup"]
        }) and
      receipt["candidate_id"] == cycle["candidate_id"] and
      receipt["attempt_token"] == cycle["attempt_token"] and
      receipt["context_sha256"] == execution.context_sha256 and
      receipt["catalog_sha256"] == cycle["catalog_sha256"] and
      receipt["cycle_sequence"] == cycle["sequence"] and
      valid_timestamp?(receipt["finished_at"]) and is_binary(receipt["log_path"]) and
      is_binary(receipt["log_sha256"]) and Regex.match?(@digest, receipt["log_sha256"]) and
      valid_evidence?(receipt) and valid_reuse?(receipt, cycle, cycles)
  end

  defp valid_evidence?(%{"target_evidence" => evidence} = receipt),
    do:
      evidence["attempt_token"] == receipt["attempt_token"] and
        evidence["target"] == receipt["target"] and TargetEvidence.verify(evidence) == :ok

  defp valid_evidence?(_receipt), do: true

  # One conjunction binds a reused receipt to the earlier passed run it names,
  # so no partial validator can accept a forged or stale reuse.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_reuse?(%{"reused_from" => origin} = receipt, cycle, cycles) do
    source_cycle = is_map(origin) && Enum.at(cycles, origin["cycle_sequence"] - 1)

    source =
      source_cycle &&
        Enum.find(source_cycle["receipts"] || [], &(&1["target"] == receipt["target"]))

    is_map(source) and is_integer(origin["cycle_sequence"]) and
      origin["cycle_sequence"] < cycle["sequence"] and receipt["provider_backed"] == true and
      source["status"] == "passed" and is_nil(source["reused_from"]) and
      is_nil(source["target_evidence_error"]) and
      source["cycle_sequence"] == origin["cycle_sequence"] and
      source["candidate_id"] == receipt["candidate_id"] and
      source["catalog_sha256"] == receipt["catalog_sha256"] and
      source["context_sha256"] == receipt["context_sha256"] and
      source["log_sha256"] == receipt["log_sha256"] and
      origin["log_sha256"] == receipt["log_sha256"]
  rescue
    _ -> false
  end

  defp valid_reuse?(_receipt, _cycle, _cycles), do: true

  defp logs_unchanged(state, execution) do
    root = execution.context["project_root"]

    state["cycles"]
    |> Enum.flat_map(&((&1["receipts"] || []) ++ List.wrap(&1["proofs"])))
    |> Enum.reject(&Map.has_key?(&1, "reused_from"))
    |> Enum.reduce_while(:ok, fn receipt, :ok ->
      case log_unchanged(receipt, root) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp log_unchanged(receipt, root) do
    case File.read(Path.expand(receipt["log_path"], root)) do
      {:ok, bytes} ->
        if sha256(bytes) == receipt["log_sha256"],
          do: :ok,
          else: {:error, "controller verification log digest changed: #{receipt["log_path"]}"}

      _ ->
        {:error, "controller verification log is missing: #{receipt["log_path"]}"}
    end
  end

  defp validate_terminal(state, context) do
    last = List.last(state["cycles"])

    if valid_terminal?(state["terminal_state"], last, state, context["verification_retries"]),
      do: :ok,
      else: {:error, "controller verification terminal counter is inconsistent"}
  end

  defp valid_terminal?("passed", last, state, _retries),
    do: last["status"] == "passed" and state["failures_since_pass"] == 0

  defp valid_terminal?("exhausted", last, state, retries),
    do:
      last["status"] == "failed" and last["failures_after"] == retries + 1 and
        state["failures_since_pass"] == last["failures_after"]

  defp valid_terminal?("pending", last, state, retries),
    do:
      last["status"] == "failed" and last["failures_after"] <= retries and
        state["failures_since_pass"] == last["failures_after"]

  defp valid_terminal?(_terminal, _last, _state, _retries), do: false

  defp valid_timestamp?(value) when is_binary(value),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))

  defp valid_timestamp?(_value), do: false

  defp project_root(tracking_path) do
    expanded = Path.expand(tracking_path)
    marker = Path.join([".kogen", "runtime", "scenario-tracking"])

    case String.split(expanded, marker, parts: 2) do
      [prefix, _suffix] when prefix != "" -> String.trim_trailing(prefix, "/")
      _ -> File.cwd!() |> Path.expand()
    end
  end

  defp relative(path, root), do: Path.relative_to(Path.expand(path), Path.expand(root))

  defp tail(bytes) when byte_size(bytes) <= @output_tail, do: valid_utf8(bytes)

  defp tail(bytes),
    do: valid_utf8(binary_part(bytes, byte_size(bytes) - @output_tail, @output_tail))

  defp valid_utf8(bytes) do
    if String.valid?(bytes), do: bytes, else: String.replace_invalid(bytes)
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp owned_directory(directory) do
    with :ok <- File.mkdir_p(Path.dirname(directory)),
         :ok <- File.mkdir(directory) do
      File.chmod(directory, 0o700)
    end
  end

  defp atomic_write(path, bytes) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temporary, bytes) do
      File.rename(temporary, path)
    end
  end

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = IO.binwrite(io, bytes)
        File.close(io)
        result

      error ->
        error
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp record_finished_at(cycle) do
    case List.last(cycle["receipts"] || []) do
      %{"finished_at" => finished} when is_binary(finished) -> finished
      _ -> cycle["finished_at"]
    end
  end
end
