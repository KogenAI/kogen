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

  Two roots are named explicitly in the persisted context: the Candidate
  (`candidate_root`), where `make -C` runs, the catalog is read as data and
  target evidence is captured and verified; and control (`control_root`,
  also `project_root`), which holds the attempt's verification directory, so
  every receipt, proof and failure `log_path` is relative to control.
  """

  alias Kogen.Build.{
    CatalogChange,
    ProofSelectors,
    TargetEvidence,
    VerificationPlan,
    VerificationRunner
  }

  alias Kogen.Harness.ProviderMarker

  @version 2
  @output_tail 16_384
  @digest ~r/^[0-9a-f]{64}$/

  def initialize(tracking_path, token, outer_attempt, targets, retries, plan \\ nil, roots \\ nil) do
    VerificationPlan.trace("Kogen.Build.Verification.initialize")

    case roots_for(tracking_path, roots) do
      {:ok, control, candidate} ->
        initialize_in(
          tracking_path,
          token,
          outer_attempt,
          targets,
          retries,
          plan,
          control,
          candidate
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp roots_for(_tracking_path, %{control_root: control, candidate_root: candidate})
       when is_binary(control) and is_binary(candidate),
       do: {:ok, Path.expand(control), Path.expand(candidate)}

  defp roots_for(tracking_path, nil) do
    case project_root(tracking_path) do
      nil ->
        {:error,
         "could not initialize controller verification context: no control root for #{tracking_path}"}

      root ->
        {:ok, root, root}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp initialize_in(tracking_path, token, outer_attempt, targets, retries, plan, root, candidate) do
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
      "control_root" => root,
      "candidate_root" => candidate,
      "targets" => targets,
      "verification_retries" => verification_retries(retries),
      "catalog_sha256" => plan && plan.catalog_sha256,
      "plan" => plan_context(plan)
    }

    context =
      case retries do
        %{offline: offline} when is_integer(offline) ->
          Map.put(context, "offline_retries", offline)

        _ ->
          context
      end

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

  # `retries` is the `verification_retries` integer, or `%{verification: v,
  # offline: o}` when the configuration carries `offline_retries`.
  defp verification_retries(%{verification: retries}), do: retries
  defp verification_retries(retries), do: retries

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

    env = Map.put_new(env, :control_root, execution.context["project_root"])

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
             "failure" =>
               Map.merge(failure, %{
                 "kind" => "catalog",
                 "target" => "catalog",
                 "class" => "offline"
               })
           }), execution}
      end

    status = if cycle["failure"], do: "failed", else: "passed"
    class = if status == "failed", do: failure_class(cycle["failure"], execution.context)
    offline_before = offline_failures(state)
    {after_count, offline_after} = counts(status, class, failures, offline_before)

    cycle =
      cycle
      |> Map.merge(%{
        "status" => status,
        "failures_before" => failures,
        "failures_after" => after_count,
        "finished_at" => now()
      })
      |> put_class(class, offline_before, offline_after, execution.context)

    terminal = terminal(status, class, after_count, offline_after, execution.context)

    state =
      state
      |> Map.merge(%{
        "developer_session_id" => session_id,
        "candidate_id" => candidate_id,
        "cycles" => state["cycles"] ++ [cycle],
        "failures_since_pass" => after_count,
        "terminal_state" => terminal
      })
      |> put_offline_count(offline_after, execution.context)

    persist(execution, state, session_id, candidate_id, cycle)
  end

  # The failure classes. `offline` (an offline target, the catalog check, or a
  # Candidate-caused `prepare` failure) spends only `offline_retries`; `paid`
  # (a provider-backed target) spends `verification_retries`; `environment`
  # (a `prepare` environment result) and `provider` (an explicit provider
  # marker, after its one retry where allowed) stop the Build and spend
  # nothing. A context without `offline_retries` (an attempt started before
  # the key existed) keeps the single `verification_retries` budget.
  @classes ~w(offline paid environment provider)
  # Terminal states that settle the attempt: passed, or a stop.
  @settled ~w(passed exhausted offline_exhausted environment provider)

  defp failure_class(failure, context) do
    class = failure["class"] || "paid"

    if class == "offline" and not offline_budget?(context), do: "paid", else: class
  end

  defp offline_budget?(context), do: is_integer(context["offline_retries"])

  defp offline_failures(state), do: state["offline_failures"] || 0

  defp counts("passed", _class, _failures, offline), do: {0, offline}
  defp counts("failed", "paid", failures, offline), do: {failures + 1, offline}
  defp counts("failed", "offline", failures, offline), do: {failures, offline + 1}
  defp counts("failed", _stop_class, failures, offline), do: {failures, offline}

  defp put_class(cycle, class, offline_before, offline_after, context) do
    if offline_budget?(context) do
      Map.merge(cycle, %{
        "class" => class,
        "offline_failures_before" => offline_before,
        "offline_failures_after" => offline_after
      })
    else
      cycle
    end
  end

  defp put_offline_count(state, offline, context) do
    if offline_budget?(context), do: Map.put(state, "offline_failures", offline), else: state
  end

  defp terminal("passed", _class, _paid, _offline, _context), do: "passed"
  defp terminal("failed", "environment", _paid, _offline, _context), do: "environment"
  defp terminal("failed", "provider", _paid, _offline, _context), do: "provider"

  defp terminal("failed", "offline", _paid, offline, context) do
    if offline > context["offline_retries"], do: "offline_exhausted", else: "pending"
  end

  defp terminal("failed", "paid", paid, _offline, context) do
    if paid > context["verification_retries"], do: "exhausted", else: "pending"
  end

  # Every selected offline target runs first, in catalog order, whatever the
  # catalog's dependencies would allow, followed by the proof selectors. Only
  # when all of them passed for this Candidate do the `prepare` steps of the
  # provider-backed targets that will actually run start, and only when every
  # `prepare` passed is any provider-backed target dispatched. No target name
  # is special here.
  defp run_targets(execution, base, catalog, env) do
    base = Map.put(base, "catalog_sha256", catalog.sha256)
    {offline, paid} = Enum.split_with(catalog.order, &(catalog.provider_backed[&1] != true))

    {receipts, failure} = run_sequence(execution, base, offline, catalog, env, [])

    # Proof selectors are focused offline runs, so they belong to the offline
    # gate too: their failure is offline and dispatches nothing paid.
    {proofs, failure, execution} =
      if failure == nil and env.catalog.integrity do
        {proofs, failure, execution} = ProofSelectors.run(execution, base, env)
        {proofs, failure && Map.put_new(failure, "class", "offline"), execution}
      else
        {[], failure, execution}
      end

    {prepares, receipts, failure, provider_failures} =
      if failure,
        do: {[], receipts, failure, []},
        else: paid_phase(execution, base, paid, catalog, env, receipts)

    cycle =
      Map.merge(base, %{"receipts" => receipts, "proofs" => proofs, "failure" => failure})

    cycle = if prepares == [], do: cycle, else: Map.put(cycle, "prepare", prepares)

    cycle =
      if provider_failures == [],
        do: cycle,
        else: Map.put(cycle, "provider_failures", provider_failures)

    {cycle, execution}
  end

  defp run_sequence(execution, base, targets, catalog, env, receipts) do
    Enum.reduce_while(targets, {receipts, nil}, fn target, {acc, nil} ->
      {receipt, failure} = target_receipt(execution, base, target, catalog, env)
      step = if failure, do: :halt, else: :cont
      {step, {acc ++ [receipt], failure}}
    end)
  end

  defp paid_phase(_execution, _base, [], _catalog, _env, receipts), do: {[], receipts, nil, []}

  defp paid_phase(execution, base, paid, catalog, env, receipts) do
    dispatched =
      Enum.filter(paid, &(reusable(execution.state["cycles"], &1, base, catalog) == :none))

    prepares = run_prepares(execution, base, dispatched, catalog, env)

    case prepare_failure(prepares) do
      nil ->
        {receipts, failure, provider_failures} =
          run_paid(execution, base, paid, catalog, env, receipts)

        {prepares, receipts, failure, provider_failures}

      failure ->
        {prepares, receipts, failure, []}
    end
  end

  defp run_paid(execution, base, targets, catalog, env, receipts) do
    Enum.reduce_while(targets, {receipts, nil, []}, fn target, {acc, nil, providers} ->
      {receipt, failure, providers} =
        paid_receipt(execution, base, target, catalog, env, providers)

      step = if failure, do: :halt, else: :cont
      {step, {acc ++ [receipt], failure, providers}}
    end)
  end

  # A provider-backed failure whose output carries an explicit provider
  # marker spends nothing. Overload, capacity and 5xx get one rerun of the
  # same target on the same Candidate; a usage limit gets none, and a second
  # provider failure stops the Build as `provider`. A timeout is never a
  # provider failure.
  defp paid_receipt(execution, base, target, catalog, env, providers) do
    {receipt, failure} = target_receipt(execution, base, target, catalog, env)

    case provider_marker(receipt, failure) do
      %{"retry" => true} = marker when providers == [] ->
        first = provider_record(receipt, marker)

        {retried, failure} =
          target_receipt(execution, base, target, catalog, env, "provider-retry")

        case provider_marker(retried, failure) do
          nil -> {retried, failure, [first]}
          again -> {retried, provider_failure(failure, again), [first]}
        end

      nil ->
        {receipt, failure, providers}

      marker ->
        if marker["kind"] == "login_rejected" do
          harness = marker["harness"] || "claude"

          reason =
            "make #{target}: #{harness} login rejected (401) (class environment); run `mix kogen.#{harness}.login`"

          {receipt,
           Map.merge(failure, %{
             "class" => "environment",
             "provider" => marker,
             "reason" => reason
           }), providers}
        else
          {receipt, provider_failure(failure, marker), providers}
        end
    end
  end

  defp provider_marker(receipt, %{"kind" => "target"}) when is_map(receipt) do
    if receipt["timed_out"] == true,
      do: nil,
      else:
        ProviderMarker.login_failure(receipt["output"] || "") ||
          ProviderMarker.classify(receipt["output"] || "")
  end

  defp provider_marker(_receipt, _failure), do: nil

  defp provider_record(receipt, marker) do
    receipt
    |> Map.take(~w(target log_path log_sha256 exit_code started_at finished_at))
    |> Map.put("marker", marker)
  end

  defp provider_failure(failure, marker),
    do: Map.merge(failure, %{"class" => "provider", "provider" => marker})

  # `prepare` runs for every provider-backed target that will be dispatched
  # and declares one, from the effective catalog entry (the admission entry,
  # or the Candidate's for an added target), through the same runner as the
  # targets: cwd is the Candidate, the environment scrubbed, provider
  # dispatch denied, its own process group and a controller-owned log.
  defp run_prepares(execution, base, targets, catalog, env) do
    for target <- targets,
        argv = get_in(catalog, [:entries, target, "prepare"]),
        valid_argv?(argv) do
      run_prepare(execution, base, target, argv, env)
    end
  end

  defp valid_argv?(argv),
    do: is_list(argv) and argv != [] and Enum.all?(argv, &(is_binary(&1) and &1 != ""))

  defp run_prepare(execution, base, target, argv, env) do
    log = Path.join(execution.log_root, "cycle-#{base["sequence"]}-prepare-#{target}.log")

    binding = %{
      "target" => target,
      "kind" => "prepare",
      "command" => argv,
      "candidate_id" => base["candidate_id"],
      "attempt_token" => base["attempt_token"],
      "context_sha256" => base["context_sha256"],
      "catalog_sha256" => base["catalog_sha256"],
      "cycle_sequence" => base["sequence"]
    }

    case VerificationRunner.run(argv, env.root, log, env: provider_denied(execution)) do
      {:ok, facts} ->
        output = facts["log_bytes"]
        status = VerificationRunner.status(facts)

        Map.merge(binding, %{
          "status" => status,
          "class" => prepare_class(status, output),
          "exit_code" => facts["exit_code"],
          "cleanup" => facts["cleanup"],
          "timed_out" => facts["timed_out"],
          "started_at" => facts["started_at"],
          "finished_at" => facts["finished_at"],
          "elapsed_ms" => facts["elapsed_ms"],
          "log_path" => relative(facts["log_path"], env.control_root),
          "log_sha256" => facts["log_sha256"],
          "output" => tail(output)
        })
        |> put_prepare_result(status, output)

      {:error, reason} ->
        failure =
          write_failure_log(execution, base["sequence"], "prepare-#{target}-supervisor", reason)

        Map.merge(binding, %{
          "status" => "failed",
          "class" => "offline",
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
  end

  @prepare_frame "KOGEN_PREPARE_RESULT\t"

  # The generic `prepare` result contract: exit 0 passes; a nonzero exit is a
  # Candidate failure (`offline`); a nonzero exit whose output carries one
  # `KOGEN_PREPARE_RESULT\t{"class":"environment","reason":…}` frame is an
  # environment failure that stops the Build.
  defp prepare_class("passed", _output), do: nil

  defp prepare_class(_status, output) do
    case prepare_result(output) do
      %{"class" => "environment"} -> "environment"
      _ -> "offline"
    end
  end

  defp put_prepare_result(receipt, "passed", _output), do: receipt

  defp put_prepare_result(receipt, _status, output) do
    case prepare_result(output) do
      nil -> receipt
      result -> Map.put(receipt, "prepare_result", result)
    end
  end

  @doc "The one `KOGEN_PREPARE_RESULT` frame in `output`, or nil."
  def prepare_result(output) when is_binary(output) do
    frames =
      for line <- String.split(output, ["\r\n", "\n"]),
          String.starts_with?(line, @prepare_frame),
          {:ok, %{"class" => class} = result} <-
            [Jason.decode(String.replace_prefix(line, @prepare_frame, ""))],
          is_binary(class),
          do: result

    case frames do
      [result] -> result
      _ -> nil
    end
  end

  def prepare_result(_output), do: nil

  # Every failed `prepare` is reported; an environment result takes
  # precedence, so a logged-out scope never reads as a Candidate failure.
  defp prepare_failure(prepares) do
    failed = Enum.filter(prepares, &(&1["status"] == "failed"))

    case Enum.find(failed, &(&1["class"] == "environment")) || List.first(failed) do
      nil ->
        nil

      receipt ->
        %{
          "kind" => "prepare",
          "target" => receipt["target"],
          "class" => receipt["class"],
          "log_path" => receipt["log_path"],
          "log_sha256" => receipt["log_sha256"],
          "output" => receipt["output"],
          "reason" => get_in(receipt, ["prepare_result", "reason"])
        }
    end
  end

  @credentials ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY OPENAI_BASE_URL AZURE_OPENAI_API_KEY CODEX_API_KEY)

  # A `prepare` never reaches a provider: provider credentials are removed,
  # `claude` and `codex` on PATH resolve to controller-written refusing shims,
  # and `KOGEN_PROVIDERS_DENIED=1` tells a cooperating command so.
  defp provider_denied(execution) do
    shims = Path.join(execution.directory, "provider-denied")

    for name <- ~w(claude codex) do
      path = Path.join(shims, name)

      unless File.exists?(path) do
        File.mkdir_p!(shims)

        File.write!(
          path,
          "#!/bin/sh\necho \"Kogen denied a provider launch during prepare: #{name} $*\" >&2\nexit 97\n"
        )

        File.chmod!(path, 0o755)
      end
    end

    [
      {"PATH", shims <> ":" <> (System.get_env("PATH") || "")},
      {"KOGEN_PROVIDERS_DENIED", "1"}
      | Enum.map(@credentials, &{&1, nil})
    ]
  end

  defp target_receipt(execution, base, target, catalog, env, attempt \\ nil)

  defp target_receipt(execution, base, target, catalog, env, nil) do
    case reusable(execution.state["cycles"], target, base, catalog) do
      {:ok, receipt} -> {receipt, nil}
      :none -> run_target(execution, base, target, catalog, env, nil)
    end
  end

  defp target_receipt(execution, base, target, catalog, env, attempt),
    do: run_target(execution, base, target, catalog, env, attempt)

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

  defp run_target(execution, base, target, catalog, env, attempt) do
    name = if attempt, do: "#{target}-#{attempt}", else: target
    log = Path.join(execution.log_root, "cycle-#{base["sequence"]}-#{name}.log")
    class = if catalog.provider_backed[target] == true, do: "paid", else: "offline"

    case VerificationRunner.run_target(env.root, target, log, control_root: env.control_root) do
      {:ok, facts} ->
        receipt = receipt(execution, base, target, catalog, facts, env)
        {receipt, receipt_failure(receipt, base, env)}

      {:error, reason} ->
        failure = write_failure_log(execution, base["sequence"], "#{name}-supervisor", reason)
        {nil, Map.merge(failure, %{"kind" => "runner", "target" => target})}
    end
    |> case do
      {nil, failure} -> {placeholder(base, target, catalog, failure), failure}
      result -> result
    end
    |> then(fn
      {receipt, nil} -> {receipt, nil}
      {receipt, failure} -> {receipt, Map.put(failure, "class", class)}
    end)
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

  defp receipt(execution, base, target, catalog, facts, env) do
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
        "log_path" => relative(facts["log_path"], env.control_root),
        "log_sha256" => facts["log_sha256"],
        "output" => tail(output)
      })

    case TargetEvidence.capture(output, target, execution.context["attempt_token"], env.root) do
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
      _ -> Kogen.Git.candidate_id(env.root)
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
    receipts =
      Enum.map(cycle["receipts"], &{&1["target"], &1}) ++
        Enum.map(List.wrap(cycle["prepare"]), &{"prepare-" <> &1["target"], &1})

    Enum.reduce_while(receipts, :ok, fn {name, receipt}, :ok ->
      path = receipt_path(execution, cycle["sequence"], name)

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
         true <- state["terminal_state"] in @settled,
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
    |> Enum.reduce_while({:ok, {0, 0}}, fn {cycle, sequence}, {:ok, {failures, offline}} ->
      class = if cycle["status"] == "failed", do: cycle["class"] || "paid"
      {after_count, offline_after} = counts(cycle["status"], class, failures, offline)

      if valid_cycle?(cycle, sequence, failures, after_count, execution) and
           valid_class?(cycle, class, offline, offline_after, execution.context) and
           Enum.all?(cycle["receipts"], &valid_receipt?(&1, cycle, cycles, execution)) and
           Enum.all?(List.wrap(cycle["prepare"]), &valid_prepare?(&1, cycle, execution)),
         do: {:cont, {:ok, {after_count, offline_after}}},
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

  # A classed cycle (an attempt with `offline_retries`) carries its class and
  # both offline counters; a legacy cycle carries neither.
  defp valid_class?(cycle, class, offline, offline_after, context) do
    if offline_budget?(context) do
      (is_nil(class) or class in @classes) and cycle["class"] == class and
        cycle["offline_failures_before"] == offline and
        cycle["offline_failures_after"] == offline_after and
        failure_class_matches?(class, get_in(cycle, ["failure", "class"]))
    else
      not Map.has_key?(cycle, "class")
    end
  end

  # A paid failure may predate the failure's own class field.
  defp failure_class_matches?(nil, _failure_class), do: true
  defp failure_class_matches?("paid", nil), do: true
  defp failure_class_matches?(class, failure_class), do: class == failure_class

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_prepare?(receipt, cycle, execution) do
    is_map(receipt) and receipt["kind"] == "prepare" and is_binary(receipt["target"]) and
      receipt["status"] in ["passed", "failed"] and is_integer(receipt["exit_code"]) and
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
      is_binary(receipt["log_sha256"]) and Regex.match?(@digest, receipt["log_sha256"])
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
      valid_evidence?(receipt, candidate_root(execution)) and
      valid_reuse?(receipt, cycle, cycles)
  end

  # Target evidence is Candidate-relative: it is verified against the
  # Candidate root the context names, never the process working directory.
  defp valid_evidence?(%{"target_evidence" => evidence} = receipt, root),
    do:
      evidence["attempt_token"] == receipt["attempt_token"] and
        evidence["target"] == receipt["target"] and TargetEvidence.verify(evidence, root) == :ok

  defp valid_evidence?(_receipt, _root), do: true

  @doc "The Candidate root an execution's context names."
  def candidate_root(execution),
    do: execution.context["candidate_root"] || execution.context["project_root"]

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
    |> Enum.flat_map(
      &((&1["receipts"] || []) ++
          List.wrap(&1["proofs"]) ++
          List.wrap(&1["prepare"]) ++ List.wrap(&1["provider_failures"]))
    )
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

    if valid_terminal?(state["terminal_state"], last, state, context["verification_retries"]) and
         valid_stop?(state["terminal_state"], last, state, context),
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

  defp valid_terminal?(stop, last, _state, _retries)
       when stop in ~w(offline_exhausted environment provider),
       do: last["status"] == "failed"

  defp valid_terminal?(_terminal, _last, _state, _retries), do: false

  # The class-specific half of the terminal check: a paid stop or pending paid
  # failure is bounded by `verification_retries`, an offline one by
  # `offline_retries`, and an environment or provider stop names its class.
  defp valid_stop?(terminal, last, state, context) do
    if offline_budget?(context) do
      state["offline_failures"] == last["offline_failures_after"] and
        class_fits?(terminal, last["class"], last["offline_failures_after"], context)
    else
      terminal in ["passed", "exhausted", "pending"]
    end
  end

  defp class_fits?("passed", class, _offline_after, _context), do: is_nil(class)
  defp class_fits?("exhausted", class, _offline_after, _context), do: class == "paid"
  defp class_fits?("environment", class, _offline_after, _context), do: class == "environment"
  defp class_fits?("provider", class, _offline_after, _context), do: class == "provider"

  defp class_fits?("offline_exhausted", class, offline_after, context),
    do: class == "offline" and offline_after == context["offline_retries"] + 1

  defp class_fits?("pending", "paid", _offline_after, _context), do: true

  defp class_fits?("pending", "offline", offline_after, context),
    do: offline_after <= context["offline_retries"]

  defp class_fits?(_terminal, _class, _offline_after, _context), do: false

  defp valid_timestamp?(value) when is_binary(value),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))

  defp valid_timestamp?(_value), do: false

  defp project_root(tracking_path) do
    expanded = Path.expand(tracking_path)
    marker = Path.join([".kogen", "runtime", "scenario-tracking"])

    case String.split(expanded, marker, parts: 2) do
      [prefix, _suffix] when prefix != "" -> String.trim_trailing(prefix, "/")
      _ -> nil
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
