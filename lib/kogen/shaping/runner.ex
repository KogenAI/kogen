defmodule Kogen.Shaping.Runner do
  @moduledoc """
  The detached runner of one headless Shaping session (`mix kogen.shape.runner
  ID`, started by `priv/kogen/shaping/detach.py` in a new session).

  It holds the session directory's `Kogen.ProcessCustody` lock for as long as
  it works; a second runner exits at once. Each loop chooses a turn: a fresh
  turn with the brief while there is no provider session, a resume of the
  same provider session carrying every accepted, unrecorded message, or
  nothing (the runner exits, so a waiting session costs no model calls).
  A turn runs through `Kogen.Harness.shaping_turn/5` with a 45-minute limit
  while the runner polls: new open question numbers notify exactly once,
  a quiet revision gets one checkpoint audit whose blocking findings reach
  the root session as a `KOGEN AUDIT` notice while still current, and the
  Codex thread id is saved as soon as it streams. The turn outcome comes
  from the audit report of the package's current revision.

  SIGTERM (`--cancel`) tears the provider groups down, keeps every file and
  settles the cancellation request after custody has released every child.
  """

  alias Kogen.Harness.Claude
  alias Kogen.Shaping.{Approval, Custody, Draft, Notifier, Prompt, Store}
  alias Kogen.ShapingAudit.{Finding, HeadlessInput, Report}

  @max_prompt_offers 3
  @commit_wait_ms 10_000
  @terminal_states ~w(approved cancelled failed)

  @doc "Runs the runner for session `id` in checkout `root`."
  def run(root, id) do
    dir = Store.session_dir(root, id)

    case Store.read_session(dir) do
      {:ok, _session} -> cycle(root, id, dir)
      _other -> IO.puts(:stderr, "no headless Shaping session #{id}")
    end

    :ok
  end

  defp cycle(root, id, dir) do
    case Kogen.Shaping.quietly(fn -> Custody.acquire(dir) end) do
      {:error, reason} ->
        IO.puts(:stderr, "another runner holds session #{id}: #{reason}")

      {:ok, _acquired} ->
        :ok = Kogen.ProcessCustody.claim(dir, "kogen-shaping-runner")
        trap(root, id, dir)

        try do
          # A fresh owner can be the recovery process scheduled by cancellation
          # after approval's filesystem rename committed but before its journal
          # reached `done`. The same journal recovery is safe after every
          # exclusive acquisition and prevents later turn dispatch on a
          # committed package.
          Approval.recover_approval(dir)

          case interrupted_check(root, dir) do
            :continue ->
              turns(root, id, dir)
              if Store.cancellation_busy?(dir), do: cancel_owner(dir)

            :cancel ->
              cancel_owner(dir)

            :stop ->
              :ok
          end
        after
          Kogen.Shaping.quietly(fn -> Custody.release(dir) end)
        end

        if fresh_arrivals?(root, dir), do: cycle(root, id, dir)
    end
  end

  defp trap(_root, _id, dir) do
    System.trap_signal(:sigterm, :kogen_shaping_cancel, fn ->
      cancel_owner(dir)
    end)
  end

  defp cancelling?, do: :persistent_term.get({__MODULE__, :cancelling}, false)

  defp cancel_owner(dir) do
    :persistent_term.put({__MODULE__, :cancelling}, true)

    case Kogen.Shaping.quietly(fn -> Custody.teardown(dir) end) do
      {:error, reason} ->
        cancellation_uncertain(dir, "custody teardown failed: #{reason}")

      _reaped ->
        release_cancel_owner(dir)
    end
  end

  defp release_cancel_owner(dir) do
    case Kogen.Shaping.quietly(fn -> Custody.release(dir) end) do
      :ok -> settle_cancellation(dir)
      {:error, reason} -> cancellation_uncertain(dir, "custody release failed: #{reason}")
    end
  end

  defp settle_cancellation(dir) do
    settled =
      Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
        settle_cancellation_locked(dir)
      end)

    case settled do
      {:ok, :settled} ->
        System.halt(0)

      {:ok, {:uncertain, reason}} ->
        cancellation_uncertain(dir, reason)

      {:error, :busy} ->
        cancellation_uncertain(dir, "session commit lock was busy after custody cleanup")
    end
  end

  defp settle_cancellation_locked(dir) do
    outcome = if Approval.committed?(dir), do: "approved", else: "cancelled"

    case Store.settle_cancellations!(dir, %{
           "owner" => Kogen.ProcessCustody.self_identity(),
           "custody_teardown" => "complete",
           "children_absent" => true,
           "observed_outcome" => outcome
         }) do
      :ok ->
        write_cancellation_state(dir, outcome)
        event = if outcome == "approved", do: "cancel_observed_approved", else: "cancelled"
        Store.event!(dir, event, %{"runner" => true, "observed_outcome" => outcome})
        :settled

      {:error, reason} ->
        {:uncertain, "could not settle request effects: #{inspect(reason)}"}
    end
  end

  defp write_cancellation_state(dir, outcome) do
    Store.update_session!(dir, fn session ->
      Map.merge(session, %{
        "state" => outcome,
        "turn_active" => false,
        "error" => nil,
        "presented" => if(outcome == "approved", do: session["presented"], else: nil)
      })
    end)
  end

  defp cancellation_uncertain(dir, reason) do
    evidence =
      case Kogen.ProcessCustody.read_lock(dir) do
        {:ok, lock} -> lock
        _ -> nil
      end

    for request <- Store.unsettled_cancellations(dir) do
      Store.update_cancellation!(dir, request["request_id"], fn effect ->
        Map.merge(effect, %{
          "status" => "uncertain",
          "cleanup_error" => reason,
          "cleanup_failed_at" => Store.now(),
          "custody_evidence" => evidence
        })
      end)
    end

    Store.update_session!(dir, fn session ->
      Map.merge(session, %{
        "state" => "interrupted",
        "error" => %{
          "code" => "cancellation_uncertain",
          "message" => reason,
          "custody" => evidence
        }
      })
    end)

    Store.event!(dir, "cancellation_uncertain", %{"reason" => reason, "custody" => evidence})
    System.halt(1)
  end

  # A turn marked active on disk means the runner that ran it died.
  defp interrupted_check(root, dir) do
    result =
      Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
        {:ok, session} = Store.read_session(dir)

        cond do
          Store.cancellation_busy?(dir) ->
            :cancel

          terminal_state?(session) ->
            :stop

          session["turn_active"] != true ->
            :continue

          true ->
            session =
              Store.write_session!(
                dir,
                Map.merge(session, %{
                  "state" => "interrupted",
                  "turn_active" => false,
                  "error" => %{
                    "code" => "runner_died",
                    "message" => "the previous runner died during turn #{session["turn_seq"]}"
                  }
                })
              )

            adopt_thread(dir, session)
            Store.event!(dir, "interrupted", %{"turn" => session["turn_seq"]})
            {:interrupted, session}
        end
      end)

    case result do
      {:ok, {:interrupted, session}} ->
        Notifier.notify(dir, session, "interrupted", body(root, session, "was interrupted"))
        :continue

      {:ok, outcome} ->
        outcome

      {:error, :busy} ->
        :stop
    end
  end

  # --- choosing a turn --------------------------------------------------------

  defp turns(root, id, dir) do
    if Store.cancellation_busy?(dir), do: cancel_owner(dir)

    {:ok, session} = Store.read_session(dir)
    pending = pending(root, dir, session)

    case next_turn(dir, session, pending) do
      :stop ->
        :stop

      :give_up ->
        give_up(root, dir, session, pending)

      mode ->
        turn(root, id, dir, session, mode, pending)
        turns(root, id, dir)
    end
  end

  defp next_turn(dir, session, pending) do
    cond do
      cancelling?() -> :stop
      Store.cancellation_busy?(dir) -> :stop
      terminal_state?(session) -> :stop
      session["provider_session_id"] == nil -> next_fresh_turn(session, pending)
      pending != [] -> next_resume_turn(dir, pending)
      true -> :stop
    end
  end

  defp next_fresh_turn(session, pending) do
    if session["turn_seq"] == 0 or pending != [], do: :fresh, else: :stop
  end

  defp next_resume_turn(dir, pending) do
    if Enum.any?(pending, &(prompt_offers(dir, &1) >= @max_prompt_offers)),
      do: :give_up,
      else: :resume
  end

  defp prompt_offers(dir, input),
    do: Enum.count(Store.offers(dir, input["number"]), &(&1["via"] == "turn-prompt"))

  defp give_up(root, dir, session, pending) do
    session =
      Store.write_session!(
        dir,
        Map.merge(session, %{
          "state" => "blocked",
          "error" => %{
            "code" => "input_not_recorded",
            "message" =>
              "#{Enum.map_join(pending, ", ", & &1["id"])} was re-sent #{@max_prompt_offers} times and never recorded"
          }
        })
      )

    Notifier.notify(dir, session, "blocked", body(root, session, "is blocked"))
    :stop
  end

  @doc "Accepted `message` inputs not recorded under `## Shaper answers`."
  def pending(root, dir, session) do
    recorded =
      case Draft.locate(root, session["intent_id"]) do
        {:ok, package} -> Store.recorded(dir, Draft.questions_text(root, package))
        :none -> %{}
      end

    Enum.reject(Store.messages(dir), &Map.has_key?(recorded, &1["id"]))
  end

  # Inputs accepted while the lock was being released, never offered at all.
  defp fresh_arrivals?(root, dir) do
    case Store.read_session(dir) do
      {:ok, session} ->
        not cancelling?() and not terminal_state?(session) and
          Enum.any?(pending(root, dir, session), &(Store.offers(dir, &1["number"]) == []))

      _ ->
        false
    end
  end

  # --- one turn ------------------------------------------------------------------

  defp turn(root, id, dir, _session, kind, pending) do
    entered =
      Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
        enter_turn(root, dir, kind, pending)
      end)

    case entered do
      {:ok, :cancel} ->
        cancel_owner(dir)

      {:ok, :stop} ->
        :ok

      {:ok, {:blocked, session}} ->
        Notifier.notify(dir, session, "blocked", body(root, session, "is blocked"))

      {:error, :busy} ->
        :ok

      {:ok, {:turn, config, n, launch_id, log, provider_kind, prompt, channel, session}} ->
        run_turn(
          root,
          id,
          dir,
          config,
          {n, launch_id, log},
          {provider_kind, prompt, channel, session},
          kind
        )
    end
  end

  defp enter_turn(root, dir, kind, pending) do
    {:ok, session} = Store.read_session(dir)

    cond do
      Store.cancellation_busy?(dir) ->
        :cancel

      terminal_state?(session) ->
        :stop

      true ->
        configured_turn(root, dir, session, kind, pending)
    end
  end

  defp configured_turn(root, dir, session, kind, pending) do
    case Kogen.Shaping.session_config(root, session) do
      {:ok, config} ->
        start_turn(root, dir, session, config, kind, pending)

      {:refuse, code, message} ->
        block_changed_configuration(dir, session, code, message)
    end
  end

  defp start_turn(root, dir, session, config, kind, pending) do
    n = (session["turn_seq"] || 0) + 1
    launch_id = Kogen.Intent.mint_uuid7()
    log = Path.join([dir, "turns", Store.pad(n) <> ".jsonl"])
    File.mkdir_p!(Path.dirname(log))

    {provider_kind, prompt, channel, session} =
      prepare(root, dir, session, config, kind, pending, launch_id, n)

    session =
      Store.write_session!(
        dir,
        Map.merge(session, %{
          "turn_seq" => n,
          "turn_active" => true,
          "state" => "running",
          "error" => nil,
          "presented" => nil,
          "notices" => []
        })
      )

    Store.event!(dir, "turn_started", %{
      "turn" => n,
      "kind" => Atom.to_string(kind),
      "launch_id" => launch_id,
      "provider_session_id" => session["provider_session_id"],
      "route" => session["route"]
    })

    {:turn, config, n, launch_id, log, provider_kind, prompt, channel, session}
  end

  defp block_changed_configuration(dir, session, code, message) do
    session =
      Store.write_session!(
        dir,
        Map.merge(session, %{
          "state" => "blocked",
          "turn_active" => false,
          "error" => %{"code" => code, "message" => message}
        })
      )

    Store.event!(dir, "configuration_changed", %{"code" => code})
    {:blocked, session}
  end

  defp terminal_state?(%{"state" => "blocked", "error" => %{"code" => code}})
       when code in ["configuration_changed", "usage"],
       do: true

  defp terminal_state?(session), do: session["state"] in @terminal_states

  defp run_turn(
         root,
         id,
         dir,
         config,
         {n, launch_id, log},
         {provider_kind, prompt, channel, session},
         kind
       ) do
    result =
      case Kogen.Shaping.quietly(fn ->
             Kogen.Harness.open_roles(config, [:shaping, :expert], root)
           end) do
        {:ok, runtime} ->
          try do
            context =
              runtime
              |> Kogen.Harness.role_context(:shaping)
              |> Map.merge(%{
                control: dir,
                log_path: log,
                timeout_ms: turn_timeout_ms(),
                channel: channel
              })

            context = %{
              context
              | env: context.env ++ environment(root, dir, id, config, launch_id)
            }

            task =
              Task.async(fn ->
                Kogen.Shaping.quietly(fn ->
                  Kogen.Harness.shaping_turn(
                    provider_kind,
                    prompt,
                    session["model"],
                    session["effort"],
                    context
                  )
                end)
              end)

            watch(root, dir, task, log, %{
              previous: nil,
              revision: nil,
              since: nil,
              checkpoint: nil,
              checked: MapSet.new()
            })
          after
            Kogen.Shaping.quietly(fn -> Kogen.Harness.close(runtime) end)
          end

        {:error, reason} ->
          {:error, {:harness_not_ready, reason}}
      end

    unless cancelling?(), do: settle(root, dir, n, kind, log, result)
  end

  defp prepare(root, dir, session, config, :fresh, _pending, _launch_id, _n) do
    brief = Store.brief(dir)
    prompt = Prompt.fresh(root, config, session, session["baseline"] || %{}, brief)

    {provider, session} =
      case session["harness"] do
        "claude" ->
          uuid = Claude.uuid4()
          # The fresh Claude session id is saved before the launch, so a
          # killed runner can still resume it.
          {uuid, Store.write_session!(dir, Map.put(session, "provider_session_id", uuid))}

        _codex ->
          {nil, session}
      end

    {{:fresh, provider}, prompt, Prompt.channel(session["nonce"]), session}
  end

  defp prepare(_root, dir, session, _config, :resume, pending, launch_id, n) do
    Enum.each(pending, fn input ->
      Store.offer!(dir, input["number"], %{
        "launch_id" => launch_id,
        "via" => "turn-prompt",
        "turn" => n,
        "id" => input["id"]
      })
    end)

    notices = Enum.map(session["notices"] || [], fn "unrouted" -> :unrouted end)
    prompt = Prompt.resume(session["nonce"], pending, notices)
    {{:resume, session["provider_session_id"]}, prompt, nil, session}
  end

  defp environment(root, dir, id, config, launch_id) do
    [
      {"KOGEN_SHAPING_INTENT_ID", id},
      {"KOGEN_SHAPING_ROUTE", config.route},
      {"KOGEN_SHAPING_LAUNCH_ID", launch_id},
      {"KOGEN_SHAPING_SESSION_DIR", dir},
      {"KOGEN_SHAPING_TOOLCHAIN_PATH", toolchain_path()},
      {"KOGEN_SHAPING_ROOT", root}
    ]
  end

  defp toolchain_path do
    ["python3", "elixir", "mix"]
    |> Enum.map(&System.find_executable/1)
    |> Enum.filter(& &1)
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.join(":")
  end

  # --- watching a running turn -----------------------------------------------------

  defp watch(root, dir, task, log, state) do
    case Task.yield(task, poll_ms()) do
      {:ok, result} ->
        await_checkpoint(root, dir, state)
        result

      {:exit, reason} ->
        {:error, {:provider_failure, {:exit, reason}, %{provider_session_id: nil}}}

      nil ->
        state = tick(root, dir, log, state)
        watch(root, dir, task, log, state)
    end
  end

  defp tick(root, dir, log, state) do
    {:ok, session} = Store.read_session(dir)
    adopt_thread(dir, session, log)

    case Draft.locate(root, session["intent_id"]) do
      {:ok, %{location: :drafts} = package} ->
        # The brief lands in the package as soon as the package exists, so
        # the revision a checkpoint audits already carries it.
        case copy_brief(root, dir, package) do
          :ok ->
            tick_draft(root, dir, session, package, state)

          {:error, reason} ->
            Store.event!(dir, "brief_admission_failed", %{"reason" => inspect(reason)})
            state
        end

      _other ->
        state
    end
  end

  defp tick_draft(root, dir, session, package, state) do
    questions = Draft.open_questions(Draft.questions_text(root, package))
    numbers = Enum.map(questions, & &1["number"])
    if numbers == state.previous, do: notify_questions(root, dir, package, numbers)

    state
    |> Map.put(:previous, numbers)
    |> checkpoint(root, dir, session, package, questions)
  end

  defp notify_questions(root, dir, package, numbers) do
    {:ok, session} = Store.read_session(dir)
    notified = session["notified_questions"] || []

    case Enum.reject(numbers, &(&1 in notified)) do
      [] ->
        :ok

      new ->
        session =
          Store.write_session!(dir, Map.put(session, "notified_questions", notified ++ new))

        count = length(new)
        noun = if count == 1, do: "question", else: "questions"

        Notifier.notify(
          dir,
          session,
          "question",
          "Kogen: #{count} #{noun} for #{package.slug} — mix kogen.shape #{session["intent_id"]}"
        )

        _ = root
        :ok
    end
  end

  # The mid-turn checkpoint: no open Ask entry, no unrecorded input, the
  # revision unchanged for the quiet period, no report for it, no audit in
  # flight, at most one per revision.
  defp checkpoint(%{checkpoint: %Task{} = task} = state, root, dir, _session, package, _questions) do
    case Task.yield(task, 0) do
      nil -> state
      {:ok, result} -> deliver_then(root, dir, package, result, %{state | checkpoint: nil})
      {:exit, _reason} -> %{state | checkpoint: nil}
    end
  end

  defp checkpoint(state, root, dir, session, package, questions) do
    revision = Draft.revision(root, package)
    now = System.monotonic_time(:millisecond)

    state =
      if revision == state.revision, do: state, else: %{state | revision: revision, since: now}

    quiet? = revision != nil and now - state.since >= quiet_ms()

    due? =
      quiet? and questions == [] and pending(root, dir, session) == [] and
        not MapSet.member?(state.checked, revision) and
        Report.read(root, package.slug, revision) == {:error, :missing} and
        Report.read_checkpoint(root, package.slug, revision) == {:error, :missing}

    if due? do
      Store.event!(dir, "audit_started", %{"trigger" => "checkpoint", "revision" => revision})

      task =
        Task.async(fn ->
          audit(root, session, %{slug: package.slug, scope: :checkpoint})
        end)

      %{state | checkpoint: task, checked: MapSet.put(state.checked, revision)}
    else
      state
    end
  end

  defp await_checkpoint(root, dir, %{checkpoint: %Task{} = task}) do
    {:ok, session} = Store.read_session(dir)

    case {Task.yield(task, 600_000) || Task.shutdown(task),
          Draft.locate(root, session["intent_id"])} do
      {{:ok, result}, {:ok, package}} -> deliver(root, dir, package, result)
      _other -> :ok
    end
  end

  defp await_checkpoint(_root, _dir, _state), do: :ok

  # A checkpoint result reaches the root session only while its revision is
  # still the package's current one; otherwise it is recorded stale.
  defp deliver_then(root, dir, package, result, state) do
    deliver(root, dir, package, result)
    state
  end

  defp deliver(root, dir, package, {:ok, report, path}) do
    current = Draft.revision(root, package)
    blocking = Enum.filter(report["findings"] || [], &Finding.open_blocking?/1)

    cond do
      report["revision"] != current ->
        Store.event!(dir, "audit_stale", %{
          "trigger" => "checkpoint",
          "revision" => report["revision"],
          "report" => path
        })

      blocking == [] ->
        Store.event!(dir, "audit_clean", %{
          "trigger" => "checkpoint",
          "revision" => report["revision"],
          "report" => path
        })

      true ->
        rev12 = binary_part(report["revision"], 0, 12)

        summary =
          Enum.map_join(blocking, "\n", fn finding ->
            "- #{finding["id"]}: #{finding["message"]}"
          end)

        md = Path.join(Path.dirname(path), "checkpoint.md")

        Store.write_json!(Path.join([dir, "notices", "au-#{rev12}.json"]), %{
          "revision" => report["revision"],
          "report" => Path.relative_to(md, root),
          "summary" => summary
        })

        Store.event!(dir, "audit_notice", %{
          "trigger" => "checkpoint",
          "revision" => report["revision"],
          "report" => path
        })
    end

    :ok
  end

  defp deliver(_root, dir, _package, other) do
    Store.event!(dir, "audit_failed", %{"trigger" => "checkpoint", "result" => inspect(other)})
    :ok
  end

  defp adopt_thread(dir, session), do: adopt_thread(dir, session, latest_log(dir))

  # Codex names its thread only in the stream: save it as soon as it appears.
  defp adopt_thread(dir, %{"provider_session_id" => nil} = session, log) when is_binary(log) do
    case thread_id(log) do
      nil -> session
      thread -> Store.write_session!(dir, Map.put(session, "provider_session_id", thread))
    end
  end

  defp adopt_thread(_dir, session, _log), do: session

  defp latest_log(dir) do
    dir |> Path.join("turns/*.jsonl") |> Path.wildcard() |> Enum.sort() |> List.last()
  end

  defp thread_started_id(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "thread.started", "thread_id" => id}} when is_binary(id) and id != "" ->
        id

      _ ->
        nil
    end
  end

  defp thread_id(log) do
    case File.read(log) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.find_value(&thread_started_id/1)

      _error ->
        nil
    end
  end

  # --- settling a turn ----------------------------------------------------------------

  defp settle(root, dir, n, kind, log, result) do
    {:ok, session} = Store.read_session(dir)
    session = Map.put(session, "turn_active", false)

    {session, provider, exit, usage} = record_result(session, result)
    session = Store.write_session!(dir, session)

    Store.event!(dir, "turn_ended", %{
      "turn" => n,
      "kind" => Atom.to_string(kind),
      "provider_session_id" => provider,
      "route" => session["route"],
      "exit" => exit,
      "usage" => usage,
      "result" => result_label(result)
    })

    package = Draft.locate(root, session["intent_id"])
    notify_draft_questions(root, dir, package)
    session = unrouted(root, dir, n, log)
    conclude(root, dir, session, package, result)
  end

  defp record_result(
         session,
         {:ok, %{provider_session_id: provider, exit_code: exit, usage: usage}}
       ) do
    {Map.put(session, "provider_session_id", session["provider_session_id"] || provider),
     provider, exit, usage}
  end

  defp record_result(session, {:error, {_kind, _reason, %{provider_session_id: provider}}})
       when is_binary(provider) do
    {Map.put(session, "provider_session_id", session["provider_session_id"] || provider),
     provider, nil, nil}
  end

  defp record_result(session, _other), do: {session, session["provider_session_id"], nil, nil}

  defp notify_draft_questions(root, dir, {:ok, %{location: :drafts} = found}) do
    numbers = Enum.map(Draft.open_questions(Draft.questions_text(root, found)), & &1["number"])
    notify_questions(root, dir, found, numbers)
  end

  defp notify_draft_questions(_root, _dir, _package), do: :ok

  defp conclude(root, dir, session, package, result) do
    case result do
      {:ok, _turn} ->
        outcome(root, dir, session, package)

      {:error, {:provider_session_unavailable, detail}} ->
        fail(root, dir, session, "provider_session_unavailable", detail)

      {:error, {:provider_session_mismatch, detail}} ->
        fail(root, dir, session, "provider_session_mismatch", detail)

      {:error, {:timeout, _detail}} ->
        interrupt(root, dir, session, "turn_timeout", "the turn exceeded its time limit")

      {:error, {:harness_not_ready, reason}} ->
        interrupt(root, dir, session, "harness_not_ready", reason)

      {:error, other} ->
        interrupt(root, dir, session, "provider_failure", inspect(other))
    end
  end

  defp result_label({:ok, _}), do: "completed"
  defp result_label({:error, {kind, _}}), do: to_string(kind)
  defp result_label({:error, {kind, _, _}}), do: to_string(kind)
  defp result_label(_other), do: "failed"

  # A Codex `request_user_input*` call never reaches a human: it is shown
  # as an unrouted question, notified, and noticed on the next resume.
  defp unrouted(root, dir, n, log) do
    {:ok, session} = Store.read_session(dir)
    found = if session["harness"] == "codex", do: request_user_input_calls(log), else: []

    if found == [] do
      session
    else
      entries = Enum.map(found, &%{"text" => &1, "turn" => n, "at" => Store.now()})

      session =
        Store.write_session!(
          dir,
          session
          |> Map.update("unrouted_questions", entries, &(&1 ++ entries))
          |> Map.put("notices", ["unrouted"])
        )

      Notifier.notify(
        dir,
        session,
        "unrouted",
        body(root, session, "asked a question that did not reach you")
      )

      session
    end
  end

  @doc false
  def request_user_input_calls(log) do
    case File.read(log) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&line_calls/1)
        |> Enum.uniq()

      _error ->
        []
    end
  end

  defp line_calls(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> calls(event)
      _ -> []
    end
  end

  defp calls(map) when is_map(map) do
    name = Enum.find_value(["name", "tool", "tool_name"], &(is_binary(map[&1]) && map[&1]))

    own =
      if is_binary(name) and String.contains?(name, "request_user_input"),
        do: [question_text(map)],
        else: []

    own ++ Enum.flat_map(Map.values(map), &calls/1)
  end

  defp calls(list) when is_list(list), do: Enum.flat_map(list, &calls/1)
  defp calls(_value), do: []

  defp question_text(map) do
    arguments =
      case map["arguments"] || map["input"] || map["args"] do
        text when is_binary(text) ->
          case Jason.decode(text) do
            {:ok, decoded} -> decoded
            _ -> text
          end

        other ->
          other
      end

    arguments
    |> strings()
    |> Enum.join("\n")
    |> case do
      "" -> Jason.encode!(arguments)
      text -> text
    end
  end

  defp strings(text) when is_binary(text), do: [text]

  defp strings(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.flat_map(fn {_k, v} -> strings(v) end)

  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(_other), do: []

  defp outcome(root, dir, session, :none) do
    block(root, dir, session, %{
      "code" => "no_package",
      "message" => "the turn ended without a Draft for this session"
    })
  end

  defp outcome(root, dir, session, {:ok, %{location: :approved}}) do
    fail(
      root,
      dir,
      session,
      "approval_not_by_engine",
      "the Shaping Controller put the Draft under approved/; only --approve approves"
    )
  end

  defp outcome(root, dir, session, {:ok, package}) do
    if package.slug in (session["preexisting_slugs"] || []) do
      fail(
        root,
        dir,
        session,
        "slug_collision",
        "#{package.slug} existed before this session; the existing package is untouched"
      )
    else
      case copy_brief(root, dir, package) do
        :ok -> audited(root, dir, session, package)
        {:error, reason} -> fail(root, dir, session, "brief_admission_failed", inspect(reason))
      end
    end
  end

  defp copy_brief(root, dir, package) do
    {:ok, session} = Store.read_session(dir)

    case HeadlessInput.admit_brief(root, session["intent_id"], package) do
      {:ok, _binding} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A ready report is used only for the exact current revision, HEAD and
  # route; one made stale while it ran (the Draft, HEAD or route moved) is
  # re-audited, a bounded number of times.
  @stale_audits 2

  defp audited(root, dir, session, package, attempt \\ 0) do
    revision = Draft.revision(root, package)
    head = head(root)

    current =
      with :current <- Report.status(root, package.slug, revision, head, session["route"]),
           {:ok, %{"scope" => "full"} = report} <- Report.read(root, package.slug, revision) do
        {:ok, report, Path.join(Report.dir(root, package.slug, revision), "report.json")}
      else
        _ -> nil
      end

    result =
      current ||
        (
          Store.event!(dir, "audit_started", %{"trigger" => "turn_end", "revision" => revision})
          audit(root, session, %{slug: package.slug, auditor: true, reuse: true})
        )

    case result do
      {:ok, report, path} ->
        session = Store.write_session!(dir, Map.put(session, "report", path))
        decide(root, dir, session, package, {report, path}, attempt)

      other ->
        block(root, dir, session, %{"code" => "audit_failed", "message" => inspect(other)})
    end
  end

  defp decide(root, dir, session, package, {report, path}, attempt) do
    text = Draft.questions_text(root, package)
    pending = pending(root, dir, session)
    questions = Draft.open_questions(text)

    current? =
      Approval.current_report?(
        Draft.revision(root, package),
        head(root),
        session["route"],
        report
      )

    cond do
      pending != [] ->
        # An immediate resume re-sends every unrecorded input.
        Store.write_session!(dir, Map.put(session, "state", "running"))

      questions != [] or report["readiness"] == "asking" ->
        session = Store.write_session!(dir, Map.put(session, "state", "awaiting_answers"))
        waiting(root, dir, session, package)

      ready?(report, questions, pending) and current? ->
        present(root, dir, session, package, {report, path}, attempt)

      ready?(report, questions, pending) ->
        stale(root, dir, session, package, report, attempt)

      true ->
        block(root, dir, session, %{
          "code" => "not_ready",
          "message" =>
            "the audit of #{report["revision"]} is #{report["readiness"]}; report: #{path}"
        })
    end
  end

  defp present(root, dir, session, package, {report, path}, attempt) do
    case Approval.present!(root, dir, session, package, report, path) do
      {:ok, session} ->
        Notifier.notify(dir, session, "ready", Approval.ready_body(session, package))

      {:stale, session} ->
        stale(root, dir, session, package, report, attempt)

      # An input arrived after `decide` looked: resume, which re-sends it.
      {:pending, session} ->
        Store.write_session!(dir, Map.put(session, "state", "running"))
    end
  end

  defp stale(root, dir, session, package, report, attempt) when attempt < @stale_audits do
    Store.event!(dir, "report_stale", %{"revision" => report["revision"]})
    audited(root, dir, session, package, attempt + 1)
  end

  defp stale(root, dir, session, _package, report, _attempt) do
    block(root, dir, session, %{
      "code" => "not_ready",
      "message" =>
        "the Draft, HEAD or route kept changing while #{report["revision"]} was audited; " <>
          "no report is current"
    })
  end

  defp ready?(report, questions, pending) do
    report["readiness"] == "ready" and report["scope"] == "full" and questions == [] and
      pending == [] and
      not Enum.any?(
        report["findings"] || [],
        &(&1["id"] =~ "answer-not-applied" or &1["rule"] == "answer-not-applied")
      )
  end

  # The `waiting` trigger: one deterministic-only checkpoint per awaiting revision.
  defp waiting(root, dir, session, package) do
    revision = Draft.revision(root, package)
    waited = session["waiting_revisions"] || []

    if revision in waited do
      :ok
    else
      Store.event!(dir, "audit_started", %{"trigger" => "waiting", "revision" => revision})

      record_waiting(
        dir,
        waited,
        revision,
        audit(root, session, %{slug: package.slug, scope: :checkpoint})
      )
    end
  end

  defp record_waiting(dir, waited, revision, {:ok, _report, path}) do
    Store.update_session!(dir, fn session ->
      session
      |> Map.put("background_report", path)
      |> Map.put("waiting_revisions", waited ++ [revision])
    end)
  end

  defp record_waiting(dir, _waited, _revision, other) do
    Store.event!(dir, "audit_failed", %{"trigger" => "waiting", "result" => inspect(other)})
  end

  defp block(root, dir, session, error) do
    session =
      Store.write_session!(dir, Map.merge(session, %{"state" => "blocked", "error" => error}))

    Notifier.notify(dir, session, "blocked", body(root, session, "is blocked"))
  end

  defp fail(root, dir, session, code, detail) do
    message = if is_binary(detail), do: detail, else: inspect(detail)

    session =
      Store.write_session!(
        dir,
        Map.merge(session, %{
          "state" => "failed",
          "presented" => nil,
          "error" => %{"code" => code, "message" => message}
        })
      )

    Notifier.notify(dir, session, "failed", body(root, session, "failed (#{code})"))
  end

  defp interrupt(root, dir, session, code, message) do
    Kogen.Shaping.quietly(fn -> Custody.teardown(dir) end)

    session =
      Store.write_session!(
        dir,
        Map.merge(session, %{
          "state" => "interrupted",
          "error" => %{"code" => code, "message" => to_string(message)}
        })
      )

    Notifier.notify(dir, session, "interrupted", body(root, session, "was interrupted"))
  end

  defp body(root, session, what) do
    name =
      case Draft.locate(root, session["intent_id"]) do
        {:ok, package} -> package.slug
        :none -> "Shaping session"
      end

    "Kogen: #{name} #{what} — mix kogen.shape #{session["intent_id"]}"
  end

  defp audit(root, session, params) do
    case Kogen.Shaping.session_config(root, session) do
      {:ok, config} ->
        Kogen.Shaping.quietly(fn ->
          Kogen.ShapingAudit.audit(
            root,
            Map.merge(%{route: session["route"], env: System.get_env(), config: config}, params)
          )
        end)

      {:refuse, _code, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp head(root) do
    case Kogen.Git.head_sha(root) do
      {:ok, head} -> head
      _ -> nil
    end
  end

  defp poll_ms, do: env_ms("KOGEN_SHAPING_POLL_MS", 5_000)
  defp quiet_ms, do: env_ms("KOGEN_SHAPING_QUIET_MS", 120_000)
  defp turn_timeout_ms, do: env_ms("KOGEN_SHAPING_TURN_TIMEOUT_MS", 45 * 60 * 1000)

  defp env_ms(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {ms, ""} when ms > 0 -> ms
      _ -> default
    end
  end
end
