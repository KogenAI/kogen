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

  Offline targets and proof selectors form one gate before any dispatch; an
  offline failure aggregates every offline failure and dispatches nothing (any
  companion job is recorded `not_started`). After the gate and every
  `prepare` pass, all provider-backed targets and the optional companion jobs
  (`env[:companions]`) run concurrently through `Kogen.Build.Fanout` under an
  optional ceiling (`env[:max_concurrency]`; absent means every job runs at once), each with its own log
  and live-evidence root, and every job settles: a failure never cancels a
  sibling. `Kogen.Build.DispatchLedger` records each actual dispatch once and
  classifies failures; the cycle keeps `"failure"` (the primary) and lists
  every failed receipt in `"failures"`.

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
    DispatchLedger,
    Fanout,
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
          candidate,
          roots
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
  defp initialize_in(
         tracking_path,
         token,
         outer_attempt,
         targets,
         retries,
         plan,
         root,
         candidate,
         roots
       ) do
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

    context = put_frozen(context, roots)
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
      "dispatch_ledger" => [],
      "dispatch_ledger_sha256" => DispatchLedger.digest([]),
      "dispatch_count" => 0,
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

  # The frozen context digest names what a previous attempt's receipt must
  # share to be reusable: everything of the attempt's context except the
  # per-attempt token, attempt number, build id, roots and the remaining
  # retry allowances (a continuation carries fewer). `roots[:frozen]`
  # (route, catalog, package and profile digests) is folded in;
  # `roots[:max_concurrency]` is recorded as the fan-out ceiling.
  defp put_frozen(context, roots) do
    extra = if is_map(roots), do: Map.get(roots, :frozen), else: nil

    frozen =
      Jason.encode!(%{
        "targets" => context["targets"],
        "catalog_sha256" => context["catalog_sha256"],
        "plan" => context["plan"],
        "frozen" => extra
      })

    context = Map.put(context, "frozen_context_sha256", sha256(frozen))

    case is_map(roots) && Map.get(roots, :max_concurrency) do
      n when is_integer(n) and n > 0 -> Map.put(context, "max_concurrency", n)
      _ -> context
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
    env = Map.put(env, :timing_file, timing_path(execution, sequence))
    _ = File.rm(env.timing_file)
    execution = Map.merge(execution, %{companions: %{}, dispatches: []})

    {cycle, execution} =
      case timed(env.timing_file, "catalog_check", fn ->
             CatalogChange.check(env.root, env.catalog, env.plan, env.scenarios)
           end) do
        {:ok, catalog} ->
          run_targets(execution, base, catalog, env)

        {:error, reason} ->
          failure = write_failure_log(execution, sequence, "catalog", reason)

          catalog_failure =
            Map.merge(failure, %{"kind" => "catalog", "target" => "catalog", "class" => "offline"})

          {Map.merge(base, %{
             "catalog_sha256" => nil,
             "receipts" => [],
             "proofs" => [],
             "failure" => catalog_failure,
             "failures" => [catalog_failure]
           }), execution}
      end

    status = if cycle["failure"], do: "failed", else: "passed"
    class = if status == "failed", do: failure_class(cycle["failure"], execution.context)
    offline_before = offline_failures(state)
    {after_count, offline_after} = counts(status, class, failures, offline_before)

    ledger = DispatchLedger.append(state["dispatch_ledger"] || [], execution.dispatches)

    cycle =
      cycle
      |> Map.merge(%{
        "status" => status,
        "failures_before" => failures,
        "failures_after" => after_count,
        "dispatch_count" => length(ledger) - length(state["dispatch_ledger"] || []),
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
        "dispatch_ledger" => ledger,
        "dispatch_ledger_sha256" => DispatchLedger.digest(ledger),
        "dispatch_count" => DispatchLedger.count(ledger),
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
  # catalog's dependencies would allow, followed by the proof selectors. All
  # offline failures are collected (an offline failure never stops a sibling
  # offline target). Only when all of them passed for this Candidate do the
  # `prepare` steps of the provider-backed targets that will actually run
  # start, and only when every `prepare` passed is any provider-backed target
  # dispatched: all of them concurrently through `Kogen.Build.Fanout`, every
  # job settled, none cancelling another. No target name is special here.
  defp run_targets(execution, base, catalog, env) do
    base = Map.put(base, "catalog_sha256", catalog.sha256)
    {offline, paid} = Enum.split_with(catalog.order, &(catalog.provider_backed[&1] != true))

    {receipts, failures} = run_sequence(execution, base, offline, catalog, env, [])

    # Proof selectors are focused offline runs, so they belong to the offline
    # gate too: their failure is offline and dispatches nothing paid.
    {proofs, failures, execution} =
      if failures == [] and env.catalog.integrity do
        {proofs, failure, execution} =
          timed(env.timing_file, "proof_selectors", fn ->
            ProofSelectors.run(execution, base, env)
          end)

        {proofs, List.wrap(failure && Map.put_new(failure, "class", "offline")), execution}
      else
        {[], failures, execution}
      end

    partial = Map.merge(base, %{"receipts" => receipts, "proofs" => proofs})

    phase =
      if failures == [],
        do: paid_phase(execution, partial, paid, catalog, env, receipts),
        else: skipped_phase(receipts, failures, env, "an offline check failed before dispatch")

    failure = primary_failure(phase.failures)

    cycle =
      base
      |> Map.merge(%{"receipts" => phase.receipts, "proofs" => proofs, "failure" => failure})
      |> put_present("failures", phase.failures)
      |> put_present("prepare", phase.prepares)
      |> put_present("provider_failures", phase.provider_failures)
      |> put_present("cancelled", phase.cancelled)
      |> put_present("timings", read_timings(env.timing_file))
      |> put_present("flaky", for(r <- phase.receipts, r["flaky"] == true, do: r["target"]))
      |> put_present("companions", companion_summary(phase.companions))
      |> put_present("fanout", phase.fanout)
      |> put_present("pending_evidence", failure && failure["pending_evidence"] == true)

    execution =
      Map.merge(execution, %{
        companions: Map.new(phase.companions, &{&1["id"], &1}),
        dispatches: phase.dispatches
      })

    {cycle, execution}
  end

  defp put_present(map, _key, value) when value in [nil, [], false], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Environment stops outrank provider stops, which outrank the rest; among
  # equals the first in run order is the primary failure.
  defp primary_failure([]), do: nil

  defp primary_failure(failures) do
    Enum.find(failures, &(&1["class"] == "environment")) ||
      Enum.find(failures, &(&1["class"] == "provider")) || List.first(failures)
  end

  defp empty_phase(receipts) do
    %{
      receipts: receipts,
      prepares: [],
      failures: [],
      provider_failures: [],
      cancelled: [],
      companions: [],
      dispatches: [],
      fanout: nil
    }
  end

  # Nothing paid and no companion starts: they are recorded `not_started`.
  defp skipped_phase(receipts, failures, env, reason) do
    %{
      empty_phase(receipts)
      | failures: failures,
        companions: not_started_companions(env[:companions], reason)
    }
  end

  defp not_started_companions(nil, _reason), do: []

  defp not_started_companions(jobs, reason) when is_list(jobs),
    do:
      for(
        job <- jobs,
        do: %{"id" => to_string(job.id), "status" => "not_started", "reason" => reason}
      )

  defp not_started_companions(fun, reason) when is_function(fun, 1),
    do: [%{"id" => "companions", "status" => "not_started", "reason" => reason}]

  defp not_started_companions(_other, _reason), do: []

  defp companion_summary(companions) do
    for entry <- companions do
      summary = Map.take(entry, ["id", "status", "reason"])

      case entry["settlement"] do
        %{"sha256" => sha, "path" => path} ->
          Map.merge(summary, %{"settlement_sha256" => sha, "settlement_path" => path})

        _ ->
          summary
      end
    end
  end

  defp run_sequence(execution, base, targets, catalog, env, receipts) do
    Enum.reduce(targets, {receipts, []}, fn target, {acc, failures} ->
      {receipt, failure} = target_receipt(execution, base, target, catalog, env)
      {acc ++ [receipt], if(failure, do: failures ++ [failure], else: failures)}
    end)
  end

  defp paid_phase(execution, base, paid, catalog, env, receipts) do
    lookups =
      timed(env.timing_file, "paid_reuse_lookups", fn ->
        for target <- paid, do: {target, reuse(execution, target, base, catalog, env)}
      end)

    to_run = for {target, :none} <- lookups, do: target

    prepares =
      timed(env.timing_file, "prepares", fn ->
        run_prepares(execution, base, to_run, catalog, env)
      end)

    case prepare_failures(prepares) do
      [] ->
        fan_out(execution, base, lookups, to_run, catalog, env, receipts, prepares)

      failures ->
        %{
          skipped_phase(receipts, failures, env, "a prepare step failed before dispatch")
          | prepares: prepares
        }
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp fan_out(execution, base, lookups, to_run, catalog, env, receipts, prepares) do
    partial = Map.merge(base, %{"receipts" => receipts, "prepare" => prepares})
    {companion_jobs, companion_errors} = resolve_companions(env[:companions], partial)

    planned = length(to_run) + length(companion_jobs)

    case reserve_initial_dispatches(env, planned) do
      :ok ->
        env = Map.merge(env, %{planned_dispatches: planned, retry_grants: :atomics.new(1, [])})

        launch_fan_out(
          execution,
          base,
          {lookups, to_run, companion_jobs, companion_errors},
          catalog,
          env,
          receipts,
          prepares
        )

      {:stop, failure} ->
        reason = failure["reason"]

        %{
          skipped_phase(receipts, [failure], env, reason)
          | prepares: prepares,
            companions:
              for(job <- companion_jobs, do: not_started(job.id, reason)) ++ companion_errors
        }
    end
  end

  defp not_started("companion-" <> id, reason), do: not_started(id, reason)

  defp not_started(id, reason),
    do: %{"id" => to_string(id), "status" => "not_started", "reason" => reason}

  # The frozen dispatch ceiling is reserved for the whole initial fan-out
  # before anything starts: with less left than planned, nothing starts.
  defp reserve_initial_dispatches(env, planned) do
    case env[:dispatches_left] do
      left when is_integer(left) and planned > left ->
        reason =
          "dispatch budget: #{left} dispatch(es) left, #{planned} needed for the initial fan-out; nothing was started"

        {:stop,
         %{
           "kind" => "budget",
           "budget" => "dispatches",
           "target" => "dispatch-budget",
           "class" => "environment",
           "reason" => reason,
           "log_path" => nil,
           "log_sha256" => nil,
           "output" => reason
         }}

      _ ->
        :ok
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp launch_fan_out(
         execution,
         base,
         {lookups, to_run, companion_jobs, companion_errors},
         catalog,
         env,
         receipts,
         prepares
       ) do
    companion_jobs = Enum.map(companion_jobs, &track_launch(&1, execution, base))

    target_jobs =
      for target <- to_run do
        %{
          id: "target-" <> target,
          run: &run_paid_job(execution, base, target, catalog, env, &1)
        }
      end

    jobs = longest_first(companion_jobs ++ target_jobs, catalog)

    max = ceiling(env, execution, length(jobs))
    summary = if jobs == [], do: nil, else: run_fanout(execution, base, jobs, max, env)
    by_id = Map.new((summary && summary.results) || [], &{&1["id"], &1})

    settled =
      for {target, lookup} <- lookups do
        case lookup do
          {:ok, reused} -> {target, {:reused, reused}}
          :none -> {target, gather_target(execution, base, target, by_id["target-" <> target])}
        end
      end

    cancelled = for {_t, {:cancelled, entry, _d}} <- settled, do: entry
    failures = for {_t, {:receipt, _r, f, _p, _d}} <- settled, f != nil, do: f

    companions_out =
      companion_entries((summary && summary.results) || [], companion_jobs) ++ companion_errors

    dispatches =
      for({_t, outcome} <- settled, entry <- outcome_dispatches(outcome), do: entry) ++
        reviewer_dispatches(companions_out, execution, base)

    %{
      receipts: receipts ++ for({_t, outcome} <- settled, r = outcome_receipt(outcome), do: r),
      prepares: prepares,
      failures: failures ++ cancelled_failure(failures, cancelled, summary),
      provider_failures: for({_t, {:receipt, _r, _f, p, _d}} <- settled, entry <- p, do: entry),
      cancelled: cancelled,
      companions: companions_out,
      dispatches: Enum.sort_by(dispatches, &{&1["started_at"], &1["target"], &1["attempt"]}),
      fanout: summary && fanout_summary(execution, summary, max)
    }
  end

  # The provisional Reviewer is one actual provider dispatch of the cycle. Its
  # launch is persisted the moment the job starts (see `track_launch/3`) and
  # the entry is settled here for every outcome: exited (completed), transport
  # error (settled otherwise or crashed) or cancelled. A job that never
  # started (`not_started`) is not a dispatch. It has no supervised process
  # group, so the entry carries the role and the job's process identity.
  defp reviewer_dispatches(companions, execution, base) do
    starts = read_starts(execution, base)

    for %{"id" => "provisional-review", "status" => status} = entry <- companions,
        outcome = reviewer_outcome(status, entry) do
      launch = Map.get(starts, "companion-provisional-review", %{})

      %{
        "target" => "provisional-review",
        "role" => "reviewer",
        "candidate_id" => base["candidate_id"],
        "cycle" => base["sequence"],
        "attempt" => "initial",
        "pid" => nil,
        "pgid" => nil,
        "process" => launch["process"],
        "process_started_at" => nil,
        "started_at" => launch["started_at"] || base["started_at"],
        "finished_at" => now(),
        "outcome" => outcome
      }
    end
  end

  defp reviewer_outcome("settled", %{"result" => %{"status" => "completed"}}), do: "exited"
  defp reviewer_outcome("settled", _entry), do: "transport_error"
  defp reviewer_outcome("crashed", _entry), do: "transport_error"
  defp reviewer_outcome("cancelled", _entry), do: "cancelled"
  defp reviewer_outcome(_status, _entry), do: nil

  # Durable start records: one JSON line per actual launch, appended before the
  # work runs, so a killed controller still leaves the launch on disk.
  defp starts_path(execution, base),
    do: Path.join([execution.directory, "fanout", "cycle-#{base["sequence"]}", "starts.jsonl"])

  defp persist_start(execution, base, record) do
    path = starts_path(execution, base)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(record) <> "\n", [:append])
  end

  defp read_starts(execution, base) do
    case File.read(starts_path(execution, base)) do
      {:ok, bytes} ->
        for line <- String.split(bytes, "\n", trim: true),
            {:ok, %{"id" => id} = record} <- [Jason.decode(line)],
            into: %{},
            do: {id, record}

      _ ->
        %{}
    end
  end

  defp track_launch(job, execution, base) do
    run = job.run

    %{
      job
      | run: fn ctx ->
          persist_start(execution, base, %{
            "id" => job.id,
            "process" => inspect(self()),
            "started_at" => now()
          })

          run.(ctx)
        end
    }
  end

  defp run_fanout(execution, base, jobs, max, env) do
    settle_root = Path.join([execution.directory, "fanout", "cycle-#{base["sequence"]}"])

    {:ok, handle} =
      Fanout.start(jobs,
        max_concurrency: max,
        settle_root: settle_root,
        control: env.control_root,
        stop_when: stop_predicate(env)
      )

    if is_function(env[:on_fanout], 1), do: env[:on_fanout].(handle)

    Fanout.await(handle)
  end

  defp outcome_receipt({:receipt, receipt, _f, _p, _d}), do: receipt
  defp outcome_receipt({:reused, receipt}), do: receipt
  defp outcome_receipt(_other), do: nil

  defp outcome_dispatches({:receipt, _r, _f, _p, dispatches}), do: dispatches
  defp outcome_dispatches({:cancelled, _entry, dispatches}), do: dispatches
  defp outcome_dispatches(_other), do: []

  # No configured cap: every selected job runs at once. A configured
  # `live_concurrency` is an optional resource cap, never a spend count.
  defp ceiling(env, execution, job_count) do
    case env[:max_concurrency] || execution.context["max_concurrency"] do
      n when is_integer(n) and n > 0 -> n
      _ -> max(job_count, 1)
    end
  end

  # Longest expected job first, so an explicit cap never queues the slowest
  # job behind a short one. A target's catalog rank tracks its cost (higher is
  # longer); a companion (the provisional Review) sits between the top two.
  defp longest_first(jobs, catalog) do
    Enum.sort_by(jobs, &(-job_weight(&1.id, catalog)))
  end

  defp job_weight("target-" <> target, catalog),
    do: get_in(catalog, [:entries, target, "rank"]) || 0

  defp job_weight(_companion, _catalog), do: 450

  # A classified provider or environment stop cancels the remaining work; a
  # caller predicate may add its own reasons.
  defp stop_predicate(env) do
    extra = env[:stop_when]

    fn entry ->
      classified_stop(entry) || if(is_function(extra, 1), do: extra.(entry))
    end
  end

  defp classified_stop(%{"result" => %{"failure" => %{"class" => class} = failure}})
       when class in ["provider", "environment"],
       do: "classified #{class} stop at #{failure["target"]}"

  defp classified_stop(_entry), do: nil

  defp resolve_companions(nil, _partial), do: {[], []}
  defp resolve_companions(list, _partial) when is_list(list), do: {prefix_companions(list), []}

  defp resolve_companions(fun, partial) when is_function(fun, 1) do
    case safe_call(fun, partial) do
      list when is_list(list) -> {prefix_companions(list), []}
      {:error, reason} -> {[], [companion_error(reason)]}
      other -> {[], [companion_error("companions returned #{inspect(other)}")]}
    end
  end

  defp resolve_companions(_other, _partial), do: {[], [companion_error("invalid companions")]}

  defp companion_error(reason) do
    %{
      "id" => "companions",
      "status" => "error",
      "reason" => if(is_binary(reason), do: reason, else: inspect(reason))
    }
  end

  defp safe_call(fun, arg) do
    fun.(arg)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp prefix_companions(jobs),
    do: Enum.map(jobs, &%{id: "companion-" <> to_string(&1.id), run: &1.run})

  defp companion_entries(results, companion_jobs) do
    ids = MapSet.new(companion_jobs, & &1.id)

    for entry <- results, MapSet.member?(ids, entry["id"]) do
      "companion-" <> id = entry["id"]
      entry |> Map.put("id", id) |> Map.put("job_id", entry["id"])
    end
  end

  # A cancel with no other failure still cannot pass the cycle: the
  # cancelled work is neither a pass nor a failure, so the cycle stops as an
  # environment stop naming what was cancelled.
  defp cancelled_failure([], [first | _] = cancelled, summary) do
    reason =
      "verification was cancelled (#{summary && summary.cancelled}); #{length(cancelled)} target(s) neither passed nor failed"

    [
      %{
        "kind" => "cancelled",
        "target" => first["target"],
        "class" => "environment",
        "reason" => reason,
        "log_path" => nil,
        "log_sha256" => nil,
        "output" => reason
      }
    ]
  end

  defp cancelled_failure(_failures, _cancelled, _summary), do: []

  defp fanout_summary(execution, summary, max) do
    control = execution.context["project_root"]

    settlements =
      for %{"settlement" => %{"path" => path, "sha256" => sha}} = entry <- summary.results do
        %{
          "id" => entry["id"],
          "status" => entry["status"],
          "path" => relative(path, control),
          "sha256" => sha
        }
      end

    %{
      "max_concurrency" => max,
      "max_observed" => summary.max_observed,
      "cancelled" => summary.cancelled,
      "settlements" => settlements
    }
  end

  defp gather_target(_execution, _base, _target, %{"status" => "settled", "result" => result}) do
    {:receipt, result["receipt"], result["failure"], result["provider_failures"] || [],
     result["dispatches"] || []}
  end

  defp gather_target(_execution, _base, target, %{"status" => status} = entry)
       when status in ["cancelled", "not_started"] do
    dispatches =
      case entry["result"] do
        %{"dispatches" => list} when is_list(list) -> DispatchLedger.mark_cancelled(list)
        _ -> []
      end

    {:cancelled,
     %{
       "target" => target,
       "status" => status,
       "reason" => entry["reason"],
       "settlement" => entry["settlement"]
     }, dispatches}
  end

  # A job that crashed is a controller-side fault, not a Candidate failure:
  # it becomes a failed receipt bound to a failure log, classed environment.
  defp gather_target(execution, base, target, entry) do
    reason = "verification job for #{target} crashed: #{inspect(entry && entry["reason"])}"
    failure = write_failure_log(execution, base["sequence"], "#{target}-job", reason)

    failure =
      Map.merge(failure, %{
        "kind" => "runner",
        "target" => target,
        "class" => "environment",
        "pending_evidence" => true,
        "reason" => reason
      })

    {:receipt, placeholder(base, target, %{provider_backed: %{target => true}}, failure), failure,
     [], []}
  end

  # The job body: one provider-backed target (with its one provider retry),
  # recording each actual dispatch once and classifying any failure from the
  # dispatch record and typed evidence.
  defp run_paid_job(execution, base, target, catalog, env, ctx) do
    {receipt, failure, providers, dispatches} =
      paid_receipt(execution, base, target, catalog, env, ctx)

    %{
      "target" => target,
      "receipt" => receipt,
      "failure" => classify_paid(failure, receipt, dispatches, base, target),
      "provider_failures" => providers,
      "dispatches" => dispatches
    }
  end

  defp classify_paid(nil, _receipt, _dispatches, _base, _target), do: nil

  defp classify_paid(failure, receipt, dispatches, base, target) do
    evidence = %{
      "kind" => failure["kind"],
      "provider_backed" => true,
      "marker" => failure["provider"],
      "exit_code" => receipt && receipt["exit_code"],
      "timed_out" => receipt && receipt["timed_out"],
      "cleanup" => receipt && receipt["cleanup"],
      "credential_scope_refusal" => ProviderMarker.scope_refusal?(receipt && receipt["output"]),
      "target" => target,
      "cycle" => base["sequence"]
    }

    %{"class" => class, "pending_evidence" => pending, "reason" => reason} =
      DispatchLedger.classify(dispatches, evidence)

    failure = Map.put(failure, "class", class)
    failure = if pending, do: Map.put(failure, "pending_evidence", true), else: failure
    Map.put_new(failure, "reason", reason)
  end

  # A provider-backed failure whose output carries an explicit provider
  # marker spends nothing. Overload, capacity and 5xx get one rerun of the
  # same target on the same Candidate (never after a cancellation); a usage
  # limit gets none, and a second provider failure stops the Build as
  # `provider`. A timeout is never a provider failure. Each actual dispatch
  # is returned as a ledger entry.
  defp paid_receipt(execution, base, target, catalog, env, job) do
    {receipt, failure, first_dispatch} =
      run_target_in(execution, base, target, catalog, env, nil, job)

    case provider_marker(receipt, failure) do
      %{"retry" => true} = marker ->
        retry_once(
          execution,
          base,
          target,
          catalog,
          env,
          job,
          {receipt, failure, marker, first_dispatch}
        )

      nil ->
        same_tree_retry(
          execution,
          base,
          target,
          catalog,
          env,
          job,
          {receipt, failure, first_dispatch}
        )

      marker ->
        {receipt, marker_failure(failure, marker, target), [], first_dispatch}
    end
  end

  # One same-tree rerun of a failed live target whose catalog entry declares
  # `same_tree_retry: 1`. Only a plain target failure of a dispatched run
  # qualifies (class `paid`: never a timeout, a cancellation, a provider or
  # environment failure), on an unchanged Candidate, once per target per
  # cycle and per Build, and only while the frozen dispatch budget still has a
  # dispatch left after the cycle's own planned dispatches. It costs one
  # dispatch and no round. No sibling is cancelled. Both attempts are kept on
  # the receipt (`attempts`); a pass on the rerun is marked `flaky`.
  defp same_tree_retry(_execution, _base, _target, _catalog, _env, _job, {receipt, nil, first}),
    do: {receipt, nil, [], first}

  defp same_tree_retry(execution, base, target, catalog, env, job, {receipt, failure, first}) do
    if same_tree_retry?(execution, base, target, catalog, env, job, {receipt, failure, first}) do
      first_attempt = attempt_record(receipt, failure, "initial")

      {retried, retry_failure, second} =
        run_target_in(execution, base, target, catalog, env, "same-tree-retry", job)

      # The rerun is classified like a first attempt: a provider or login
      # marker makes it a provider/environment failure, not a paid one.
      retry_failure =
        case provider_marker(retried, retry_failure) do
          nil -> retry_failure
          marker -> marker_failure(retry_failure, marker, target)
        end

      second_attempt = attempt_record(retried, retry_failure, "same-tree-retry")
      attempts = [first_attempt, second_attempt]

      retried = Map.put(retried, "attempts", attempts)
      retried = if retry_failure == nil, do: Map.put(retried, "flaky", true), else: retried

      retry_failure =
        retry_failure &&
          Map.merge(retry_failure, %{"attempts" => attempts, "same_tree_retry" => true})

      {retried, retry_failure, [], first ++ second}
    else
      {receipt, failure, [], first}
    end
  end

  defp attempt_record(receipt, failure, attempt) do
    receipt
    |> Map.take(
      ~w(target log_path log_sha256 exit_code started_at finished_at elapsed_ms timed_out)
    )
    |> Map.merge(%{"attempt" => attempt, "status" => if(failure, do: "failed", else: "passed")})
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp same_tree_retry?(execution, base, target, catalog, env, job, {receipt, failure, first}) do
    entry = get_in(catalog, [:entries, target]) || %{}

    entry["same_tree_retry"] == 1 and failure["kind"] == "target" and
      is_map(receipt) and receipt["timed_out"] != true and first != [] and
      not job.cancelled?.() and
      paid_class?(failure, receipt, first, base, target) and
      retry_unspent?(execution, base, target) and
      dispatch_available?(env) and
      unchanged_candidate?(base, env)
  end

  defp paid_class?(failure, receipt, dispatches, base, target),
    do: classify_paid(failure, receipt, dispatches, base, target)["class"] == "paid"

  # At most one same-tree retry per target per Build: the persisted ledger
  # holds every earlier one.
  defp retry_unspent?(execution, base, target) do
    ledger = (execution.state && execution.state["dispatch_ledger"]) || []

    not Enum.any?(ledger, &(&1["target"] == target and &1["attempt"] == "same-tree-retry")) and
      base["sequence"] != nil
  end

  # `env[:dispatches_left]` is the frozen dispatch budget remaining when the
  # cycle starts (absent: unbounded). The cycle's planned first dispatches are
  # reserved, and each granted retry takes one more.
  defp dispatch_available?(env) do
    granted = if env[:retry_grants], do: :atomics.add_get(env.retry_grants, 1, 1), else: 1

    case env[:dispatches_left] do
      left when is_integer(left) ->
        available = left - (env[:planned_dispatches] || 0) - granted >= 0
        unless available, do: :atomics.sub(env.retry_grants, 1, 1)
        available

      _ ->
        true
    end
  end

  defp unchanged_candidate?(base, env) do
    expected = base["candidate_id"]
    match?({:ok, ^expected}, candidate_id(env))
  end

  defp retry_once(
         execution,
         base,
         target,
         catalog,
         env,
         job,
         {receipt, failure, marker, first_dispatch}
       ) do
    if job.cancelled?.() do
      {receipt, provider_failure(failure, marker), [], first_dispatch}
    else
      first = provider_record(receipt, marker)

      {retried, failure, second_dispatch} =
        run_target_in(execution, base, target, catalog, env, "provider-retry", job)

      dispatches = first_dispatch ++ second_dispatch

      case provider_marker(retried, failure) do
        nil -> {retried, failure, [first], dispatches}
        again -> {retried, provider_failure(failure, again), [first], dispatches}
      end
    end
  end

  defp marker_failure(failure, marker, target) do
    if marker["kind"] == "login_rejected" do
      harness = marker["harness"] || "claude"

      reason =
        "make #{target}: #{harness} login rejected (401) (class environment); run `mix kogen.#{harness}.login`"

      Map.merge(failure, %{"class" => "environment", "provider" => marker, "reason" => reason})
    else
      provider_failure(failure, marker)
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

    case VerificationRunner.run(argv, env.root, log,
           env: provider_denied(execution) ++ prepare_route(env[:route])
         ) do
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
  # precedence as the primary failure, so a logged-out scope never reads as a
  # Candidate failure.
  defp prepare_failures(prepares) do
    for receipt <- Enum.filter(prepares, &(&1["status"] == "failed")) do
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

  # A `prepare` runs the setup of a live target, which runs on the Build's
  # selected route, so it gets that route as `KOGEN_ROUTE`: never the
  # Candidate's `default_route` or a stray `KOGEN_ROUTE` in the controller's
  # environment.
  defp prepare_route(route) when is_binary(route) and route != "", do: [{"KOGEN_ROUTE", route}]
  defp prepare_route(_route), do: [{"KOGEN_ROUTE", nil}]

  defp target_receipt(execution, base, target, catalog, env) do
    case reuse(execution, target, base, catalog, env) do
      {:ok, receipt} -> {receipt, nil}
      :none -> run_target(execution, base, target, catalog, env, nil)
    end
  end

  # Reuse is by exact binding only: an earlier passed receipt of this
  # attempt (provider-backed targets), or a digest-verified passed receipt of
  # a previous attempt (`env[:prior_receipts]`, see `reusable_prior/2`).
  defp reuse(execution, target, base, catalog, env) do
    timed(env[:timing_file], "reuse:" <> target, fn ->
      reuse_lookup(execution, target, base, catalog, env)
    end)
  end

  defp reuse_lookup(execution, target, base, catalog, env) do
    case reusable(execution.state["cycles"], target, base, catalog) do
      {:ok, _receipt} = hit -> hit
      :none -> prior_reuse(execution, target, base, catalog, env)
    end
  end

  # A previous attempt's passed receipt is reused only when the target, the
  # exact Candidate tree, the catalog digest and the frozen context (which
  # excludes the per-attempt token) all match, and its log and evidence
  # digests still verify. Offline targets (the `check` gate) are reused this
  # way only in the attempt's first cycle: inside an attempt they rerun.
  defp prior_reuse(execution, target, base, catalog, env) do
    provider_backed = catalog.provider_backed[target] == true

    if env[:prior_receipts] in [nil, []] or (not provider_backed and base["sequence"] != 1) do
      :none
    else
      Enum.find_value(env.prior_receipts, :none, fn
        %{"receipt" => receipt, "origin" => origin} when is_map(receipt) and is_map(origin) ->
          prior_hit(execution, target, base, provider_backed, receipt, origin)

        _ ->
          nil
      end)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp prior_hit(execution, target, base, provider_backed, receipt, origin) do
    frozen = execution.context["frozen_context_sha256"]

    if receipt["target"] == target and receipt["status"] == "passed" and
         receipt["provider_backed"] == provider_backed and
         is_nil(receipt["target_evidence_error"]) and is_nil(receipt["reused_from"]) and
         receipt["candidate_id"] == base["candidate_id"] and
         receipt["catalog_sha256"] == base["catalog_sha256"] and
         is_binary(frozen) and origin["frozen_context_sha256"] == frozen and
         is_binary(origin["attempt_token"]) and origin["attempt_token"] != base["attempt_token"] and
         is_binary(origin["state_sha256"]) and
         VerificationRunner.status(receipt_facts(receipt)) == "passed" and
         log_unchanged(receipt, execution.context["project_root"]) == :ok and
         prior_evidence?(receipt, origin, execution) do
      {:ok,
       Map.merge(receipt, %{
         "attempt_token" => base["attempt_token"],
         "context_sha256" => base["context_sha256"],
         "developer_session_id" => base["developer_session_id"],
         "cycle_sequence" => base["sequence"],
         "reused_from" => %{
           "prior" => true,
           "state_path" => origin["state_path"],
           "state_sha256" => origin["state_sha256"],
           "attempt_token" => origin["attempt_token"],
           "cycle_sequence" => origin["cycle"],
           "log_sha256" => receipt["log_sha256"],
           "candidate_id" => receipt["candidate_id"],
           "frozen_context_sha256" => frozen
         }
       })}
    end
  end

  defp receipt_facts(receipt),
    do: Map.take(receipt, ["exit_code", "timed_out", "cleanup"])

  defp prior_evidence?(%{"target_evidence" => evidence} = receipt, origin, execution),
    do:
      is_map(evidence) and evidence["attempt_token"] == origin["attempt_token"] and
        evidence["target"] == receipt["target"] and
        TargetEvidence.verify(evidence, candidate_root(execution)) == :ok

  defp prior_evidence?(_receipt, _origin, _execution), do: true

  @doc """
  Loads a previous attempt's verification state for reuse. `expected_state_sha256`
  is the digest the caller recorded for the state bytes; the file, its
  context and every log must still match (the same integrity checks as
  `settle/3`). Returns `{:ok, [%{"receipt" => map, "origin" => map}]}` with
  every PASSED, non-reused receipt of the state (latest first) and
  `origin = %{"state_path", "state_sha256", "attempt_token", "cycle",
  "frozen_context_sha256"}`, ready for `env[:prior_receipts]`; or
  `{:error, reason}` when anything fails to verify (nothing is reused).
  Failed, cancelled and not-started work is never returned.
  """
  @spec reusable_prior(Path.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def reusable_prior(state_path, expected_state_sha256) do
    directory = Path.dirname(state_path)

    with {:ok, state_bytes} <- File.read(state_path),
         true <- sha256(state_bytes) == expected_state_sha256,
         {:ok, context_bytes} <- File.read(Path.join(directory, "context.json")),
         {:ok, %{} = context} <- Jason.decode(context_bytes),
         {:ok, %{} = state} <- Jason.decode(state_bytes),
         true <- state["context_sha256"] == sha256(context_bytes),
         execution = %{context: context, context_sha256: sha256(context_bytes)},
         :ok <- validate_state(state, execution) do
      {:ok, passed_receipts(state, context, state_path, expected_state_sha256)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "prior verification state failed integrity checks: #{state_path}"}
    end
  end

  defp passed_receipts(state, context, state_path, state_sha256) do
    state["cycles"]
    |> Enum.reverse()
    |> Enum.flat_map(fn cycle ->
      for receipt <- cycle["receipts"] || [],
          receipt["status"] == "passed",
          is_nil(receipt["reused_from"]),
          is_nil(receipt["target_evidence_error"]) do
        %{
          "receipt" => receipt,
          "origin" => %{
            "state_path" => state_path,
            "state_sha256" => state_sha256,
            "attempt_token" => context["attempt_token"],
            "cycle" => cycle["sequence"],
            "frozen_context_sha256" => context["frozen_context_sha256"]
          }
        }
      end
    end)
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

  defp run_target(execution, base, target, catalog, env, attempt) do
    {receipt, failure, _dispatches} =
      run_target_in(execution, base, target, catalog, env, attempt, nil)

    {receipt, failure}
  end

  @dispatch_key :kogen_dispatch_entry

  # Runs one `make <target>`. In a fan-out `job` (the Fanout context) the
  # target gets its own log and live-evidence roots, its process group is
  # registered for cancellation, and the actual dispatch is returned as one
  # ledger entry.
  defp run_target_in(execution, base, target, catalog, env, attempt, job) do
    name = if attempt, do: "#{target}-#{attempt}", else: target
    class = if catalog.provider_backed[target] == true, do: "paid", else: "offline"
    log = target_log(execution, base, target, name, job)
    Process.delete(@dispatch_key)

    result =
      with {:ok, argv} <- target_argv(catalog, target, env.root) do
        VerificationRunner.run_target(
          env.root,
          target,
          log,
          [
            argv: argv,
            control_root: env.control_root,
            route: env[:route],
            provider_backed: class == "paid"
          ] ++
            job_options(job, execution, base, target, attempt, env)
        )
      end

    mark(env[:timing_file], "runner_done:" <> name)

    dispatches =
      case Process.delete(@dispatch_key) do
        nil -> []
        entry -> [DispatchLedger.finish(entry, result)]
      end

    outcome =
      case result do
        {:ok, facts} ->
          receipt = receipt(execution, base, target, catalog, facts, env)
          {receipt, receipt_failure(receipt, base, env)}

        {:error, reason} ->
          failure = write_failure_log(execution, base["sequence"], "#{name}-supervisor", reason)
          failure = Map.merge(failure, %{"kind" => "runner", "target" => target})
          {placeholder(base, target, catalog, failure), failure}
      end

    case outcome do
      {receipt, nil} -> {receipt, nil, dispatches}
      {receipt, failure} -> {receipt, Map.put(failure, "class", class), dispatches}
    end
  end

  defp target_argv(%{project_root: _root} = catalog, target, root),
    do: VerificationPlan.command(catalog, target, root)

  defp target_argv(_catalog, target, root), do: {:ok, ["make", "-C", Path.expand(root), target]}

  defp target_log(execution, base, _target, name, nil),
    do: Path.join(execution.log_root, "cycle-#{base["sequence"]}-#{name}.log")

  defp target_log(execution, base, target, name, _job),
    do: Path.join([execution.log_root, "cycle-#{base["sequence"]}", target, "#{name}.log"])

  defp job_options(nil, _execution, _base, _target, _attempt, _env), do: []

  defp job_options(job, execution, base, target, attempt, env) do
    binding = %{
      target: target,
      candidate_id: base["candidate_id"],
      cycle: base["sequence"],
      attempt: attempt
    }

    [
      live_log_dir: live_target_root(env, base, target, attempt),
      on_start: fn group ->
        mark(
          env[:timing_file],
          "dispatch_start:" <> target <> if(attempt, do: "-#{attempt}", else: "")
        )

        entry = DispatchLedger.begin(binding, group)
        Process.put(@dispatch_key, entry)

        persist_start(execution, base, %{
          "id" => "start:" <> target <> ":" <> entry["attempt"],
          "entry" => entry
        })

        job.on_start.(group)
      end
    ]
  end

  # Concurrent targets never share an evidence root: each target gets
  # `<live-evidence>/cycle-N/<target>` under the caller's own
  # KOGEN_LIVE_LOG_DIR when set, else control's live-evidence directory.
  defp live_target_root(env, base, target, attempt) do
    root =
      case System.get_env("KOGEN_LIVE_LOG_DIR") do
        caller when caller not in [nil, ""] -> caller
        _ -> VerificationRunner.live_evidence_dir(env.control_root)
      end

    Path.join([root, "cycle-#{base["sequence"]}", target] ++ List.wrap(attempt))
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

    receipt =
      if is_binary(facts["route"]),
        do: Map.put(receipt, "route", facts["route"]),
        else: receipt

    capture =
      timed(env[:timing_file], "target_evidence:" <> target, fn ->
        TargetEvidence.capture(output, target, execution.context["attempt_token"], env.root)
      end)

    case capture do
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

    case timed(env[:timing_file], "candidate_id:" <> receipt["target"], fn ->
           candidate_id(env)
         end) do
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

  # Concurrent fan-out jobs each re-check the Candidate after their target.
  # Git's private-index tree write is not safe to run several times at once
  # over the same object store, so identity checks of one Candidate are
  # serialised.
  defp candidate_id(env) do
    lock = {{__MODULE__, :candidate_id, Path.expand(env.root)}, self()}

    :global.trans(lock, fn ->
      case Map.get(env, :candidate_id) do
        fun when is_function(fun, 0) -> fun.()
        _ -> Kogen.Git.candidate_id(env.root)
      end
    end)
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

    next_execution = %{
      execution
      | state: state,
        state_bytes: bytes,
        history_bytes: execution.history_bytes <> bytes
    }

    sink = timing_path(execution, cycle["sequence"])
    step = fn name, fun -> timed(sink, "persist:" <> name, fun) end

    with :ok <- step.("write_receipts", fn -> write_receipts(execution, cycle) end),
         :ok <- step.("write_state", fn -> atomic_write(execution.state_path, bytes) end),
         :ok <-
           step.("write_history", fn ->
             atomic_write(execution.history_path, next_execution.history_bytes)
           end),
         :ok <-
           step.("local_record", fn ->
             local_record(execution, session_id, candidate_id, cycle)
           end) do
      {:ok, next_execution, state}
    else
      {:error, reason} ->
        {:error, "could not persist controller verification: #{inspect(reason)}"}
    end
  end

  defp write_receipts(execution, cycle) do
    Enum.reduce_while(receipt_entries(execution, cycle), :ok, fn {path, bytes}, :ok ->
      case exclusive_write(path, bytes) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp receipt_entries(execution, cycle) do
    receipts =
      Enum.map(cycle["receipts"], &{&1["target"], &1}) ++
        Enum.map(List.wrap(cycle["prepare"]), &{"prepare-" <> &1["target"], &1})

    Enum.map(receipts, fn {name, receipt} ->
      {receipt_path(execution, cycle["sequence"], name), Jason.encode!(receipt) <> "\n"}
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
         :ok <- validate_ledger(state, cycles, execution),
         :ok <- validate_terminal(state, context),
         :ok <- logs_unchanged(state, execution) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, "controller verification settlement has stale or contradictory binding"}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_cycles(cycles, execution) do
    cycles
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, {0, 0}}, fn {cycle, sequence}, {:ok, {failures, offline}} ->
      class = if cycle["status"] == "failed", do: cycle["class"] || "paid"
      {after_count, offline_after} = counts(cycle["status"], class, failures, offline)

      if valid_cycle?(cycle, sequence, failures, after_count, execution) and
           valid_class?(cycle, class, offline, offline_after, execution.context) and
           Enum.all?(cycle["receipts"], &valid_receipt?(&1, cycle, cycles, execution)) and
           Enum.all?(List.wrap(cycle["prepare"]), &valid_prepare?(&1, cycle, execution)) and
           valid_fanout?(cycle, execution),
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
          planned_targets_have_exact_receipts?(receipts, context) and
          Enum.all?(receipts, &(&1["status"] == "passed"))) or
         (not passed and is_map(failure)))
  end

  # The top-level targets are the frozen unique plan passed to initialize/7.
  # A passed cycle must retain one target receipt for every planned target and
  # no extra or duplicate target receipts. Prepare and proof-selector evidence
  # is stored in separate cycle fields and is intentionally excluded here.
  defp planned_targets_have_exact_receipts?(receipts, context) do
    expected = context["targets"]

    actual =
      Enum.map(receipts, fn
        %{"target" => target} when is_binary(target) -> target
        _ -> nil
      end)

    is_list(expected) and Enum.all?(expected, &is_binary/1) and
      length(expected) == length(Enum.uniq(expected)) and
      Enum.all?(actual, &is_binary/1) and length(actual) == length(Enum.uniq(actual)) and
      Enum.sort(actual) == Enum.sort(expected)
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
      valid_reuse?(receipt, cycle, cycles, execution)
  end

  # Target evidence is Candidate-relative: it is verified against the
  # Candidate root the context names, never the process working directory.
  defp valid_evidence?(%{"target_evidence" => evidence} = receipt, root),
    do:
      evidence["attempt_token"] == evidence_token(receipt) and
        evidence["target"] == receipt["target"] and TargetEvidence.verify(evidence, root) == :ok

  defp valid_evidence?(_receipt, _root), do: true

  # Evidence captured by a previous attempt stays bound to that attempt's
  # token; the reused receipt itself is rebound to the current attempt.
  defp evidence_token(%{"reused_from" => %{"prior" => true, "attempt_token" => token}}), do: token
  defp evidence_token(receipt), do: receipt["attempt_token"]

  @doc "The Candidate root an execution's context names."
  def candidate_root(execution),
    do: execution.context["candidate_root"] || execution.context["project_root"]

  # One conjunction binds a reused receipt to the earlier passed run it names,
  # so no partial validator can accept a forged or stale reuse.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_reuse?(
         %{"reused_from" => %{"prior" => true} = origin} = receipt,
         cycle,
         _cycles,
         execution
       ) do
    frozen = execution.context["frozen_context_sha256"]
    control = execution.context["project_root"]

    is_binary(frozen) and origin["frozen_context_sha256"] == frozen and
      origin["candidate_id"] == receipt["candidate_id"] and
      origin["log_sha256"] == receipt["log_sha256"] and
      is_binary(origin["attempt_token"]) and origin["attempt_token"] != cycle["attempt_token"] and
      is_binary(origin["state_path"]) and is_binary(origin["state_sha256"]) and
      receipt["status"] == "passed" and is_nil(receipt["target_evidence_error"]) and
      (receipt["provider_backed"] == true or cycle["sequence"] == 1) and
      prior_state_unchanged?(origin, control)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_reuse?(%{"reused_from" => origin} = receipt, cycle, cycles, _execution) do
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

  defp valid_reuse?(_receipt, _cycle, _cycles, _execution), do: true

  # The previous attempt's state must still hold the bytes the reuse named.
  defp prior_state_unchanged?(origin, control) do
    case File.read(Path.expand(origin["state_path"], control)) do
      {:ok, bytes} -> sha256(bytes) == origin["state_sha256"]
      _ -> false
    end
  end

  defp logs_unchanged(state, execution) do
    root = execution.context["project_root"]

    state["cycles"]
    |> Enum.flat_map(
      &((&1["receipts"] || []) ++
          List.wrap(&1["proofs"]) ++
          List.wrap(&1["prepare"]) ++ List.wrap(&1["provider_failures"]))
    )
    |> Enum.reject(&reused_in_attempt?/1)
    |> Enum.reduce_while(:ok, fn receipt, :ok ->
      case log_unchanged(receipt, root) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A receipt reused inside the attempt was verified where it ran; one reused
  # from a previous attempt is verified here, against its own log.
  defp reused_in_attempt?(%{"reused_from" => %{"prior" => true}}), do: false
  defp reused_in_attempt?(receipt), do: Map.has_key?(receipt, "reused_from")

  defp log_unchanged(%{"log_path" => nil}, _root), do: :ok

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

  # The dispatch ledger: well-formed, exactly-once, bound to its cycles, with
  # the state's count and digest and each cycle's own count agreeing.
  defp validate_ledger(state, cycles, _execution) do
    if Map.has_key?(state, "dispatch_ledger") do
      ledger = state["dispatch_ledger"]

      with :ok <- DispatchLedger.validate(ledger, cycles),
           true <- state["dispatch_ledger_sha256"] == DispatchLedger.digest(ledger),
           true <- state["dispatch_count"] == length(ledger),
           true <- Enum.all?(cycles, &valid_dispatch_count?(&1, ledger)) do
        :ok
      else
        {:error, _reason} = error -> error
        _ -> {:error, "controller verification dispatch ledger is inconsistent"}
      end
    else
      if Enum.any?(cycles, &Map.has_key?(&1, "dispatch_count")),
        do: {:error, "controller verification dispatch ledger is missing"},
        else: :ok
    end
  end

  defp valid_dispatch_count?(cycle, ledger) do
    entries = DispatchLedger.for_cycle(ledger, cycle["sequence"])
    retries = Enum.count(entries, &(&1["attempt"] == "provider-retry"))

    cycle["dispatch_count"] == length(entries) and
      retries == length(List.wrap(cycle["provider_failures"])) and
      Enum.all?(entries, &(&1["role"] == "reviewer" or &1["target"] in cycle_targets(cycle)))
  end

  defp cycle_targets(cycle) do
    Enum.map(cycle["receipts"] || [], & &1["target"]) ++
      Enum.map(List.wrap(cycle["cancelled"]), & &1["target"])
  end

  # The fan-out fields of a cycle. A passed cycle carries no failure and no
  # cancelled work; a failed one names its primary failure among `failures`,
  # each classed; every job settlement file still holds the digest recorded.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_fanout?(cycle, execution) do
    failures = cycle["failures"]
    cancelled = List.wrap(cycle["cancelled"])
    failure = cycle["failure"]

    (is_nil(failures) or
       (is_list(failures) and Enum.all?(failures, &(is_map(&1) and class_ok?(&1))) and
          (is_nil(failure) or failure in failures) and
          (cycle["status"] == "failed" or failures == []))) and
      (cycle["status"] == "failed" or (cancelled == [] and is_nil(cycle["companions_error"]))) and
      Enum.all?(cancelled, &(is_map(&1) and &1["status"] in ["cancelled", "not_started"])) and
      valid_companions?(cycle["companions"]) and
      valid_settlements?(cycle["fanout"], execution)
  end

  defp class_ok?(failure), do: is_nil(failure["class"]) or failure["class"] in @classes

  defp valid_companions?(nil), do: true

  defp valid_companions?(list) when is_list(list),
    do:
      Enum.all?(
        list,
        &(is_map(&1) and is_binary(&1["id"]) and
            &1["status"] in ~w(settled cancelled not_started crashed error))
      )

  defp valid_companions?(_other), do: false

  defp valid_settlements?(nil, _execution), do: true

  defp valid_settlements?(%{"settlements" => settlements} = fanout, execution)
       when is_list(settlements) do
    control = execution.context["project_root"]

    is_integer(fanout["max_concurrency"]) and fanout["max_concurrency"] > 0 and
      Enum.all?(settlements, fn settlement ->
        entry = %{
          "settlement" => %{
            "path" => Path.expand(to_string(settlement["path"]), control),
            "sha256" => settlement["sha256"]
          }
        }

        Fanout.verify_settlement(entry) == :ok
      end)
  end

  defp valid_settlements?(_other, _execution), do: false

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

  # -- step timing ---------------------------------------------------------
  # Every controller step between a check's receipt and the next dispatch is
  # timed with wall-clock start and finish stamps and a monotonic duration.
  # Entries are appended (one JSON line each) to
  # `<log_root>/../cycle-N-timings.jsonl` and folded into the cycle as
  # `"timings"`. Diagnostic only: nothing accepts or rejects on a timing.
  defp timing_path(execution, sequence),
    do: Path.join(Path.dirname(execution.log_root), "cycle-#{sequence}-timings.jsonl")

  defp timed(sink, step, fun) do
    started = now_us()
    t0 = System.monotonic_time(:microsecond)
    result = fun.()

    emit_timing(sink, %{
      "step" => step,
      "started_at" => started,
      "finished_at" => now_us(),
      "elapsed_ms" => Float.round((System.monotonic_time(:microsecond) - t0) / 1000, 1)
    })

    result
  end

  defp mark(sink, step),
    do: emit_timing(sink, %{"step" => step, "at" => now_us()})

  defp emit_timing(path, entry) when is_binary(path) do
    _ = File.mkdir_p(Path.dirname(path))
    _ = File.write(path, Jason.encode!(entry) <> "\n", [:append])
    :ok
  rescue
    _ -> :ok
  end

  defp emit_timing(_sink, _entry), do: :ok

  defp read_timings(path) do
    case File.read(path) do
      {:ok, bytes} ->
        for line <- String.split(bytes, "\n", trim: true),
            {:ok, entry} <- [Jason.decode(line)],
            do: entry

      _ ->
        []
    end
  end

  defp now_us, do: DateTime.utc_now() |> DateTime.to_iso8601()

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
