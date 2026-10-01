defmodule Kogen.Shaping do
  @moduledoc """
  Headless Shaping: the only way to shape. `mix kogen.shape` is a thin client
  of `main/2`; every invocation answers exactly one JSON object.

  | Invocation | Effect |
  |---|---|
  | `--brief FILE [--route R] [--interface N] [--request-id RID]` | start |
  | `ID` | status (read-only, never locks, never recovers) |
  | `ID --brief FILE [--interface N] [--request-id RID]` | continue with a message |
  | `ID --approve PRESENTATION [--interface N] [--request-id RID]` | approve |
  | `ID --cancel [--request-id RID]` | cancel |

  Sessions are addressed only by their Intent ID (a UUIDv7). Start and
  continue store the exact input bytes before replying and detach a runner
  (`mix kogen.shape.runner ID`, see `Kogen.Shaping.Runner`) when none is
  live. Only `--approve` approves (see `Kogen.Shaping.Approval`); a message
  never does, whatever it says. Callers with `KOGEN_ROLE` set (every managed
  Kogen launch) are refused `managed_role`: this is accidental-call
  prevention, not an authorization boundary. Inputs and approvals record
  the interface's attestation (`authority: interface-attested`), never a
  Git or process identity.

  Exit codes: `0` accepted, replayed or status; `2` refusal; `1` internal
  failure.
  """
  use Boundary,
    deps: [
      Kogen.Intent,
      Kogen.Harness,
      Kogen.ShapingAudit,
      Kogen.ProcessCustody,
      Kogen.Git,
      Kogen.ExecutionPolicy
    ],
    exports: [Runner, Approval, Store]

  alias Kogen.Shaping.{Approval, Draft, Runner, Store}
  alias Kogen.ShapingAudit.Report

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  @rid ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
  @interface ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
  @presentation ~r/^p-[0-9]+-[0-9a-f]{12}$/
  @max_input 1_048_576
  @build_lock ".kogen/build.lock"
  @config_path ".kogen/config.yaml"
  @states ~w(running awaiting_answers ready blocked interrupted cancelled failed approved)
  # A retry of a request still running (an approval's audit can take
  # minutes) refuses `busy` after this wait; the commit lock is held only
  # for file writes and an approval's final check and rename.
  @request_wait_ms 5_000
  @commit_wait_ms 10_000

  @usage "usage: mix kogen.shape --brief FILE [--route ROUTE] [--interface NAME] [--request-id RID] | " <>
           "mix kogen.shape ID | mix kogen.shape ID --brief FILE [--interface NAME] [--request-id RID] | " <>
           "mix kogen.shape ID --approve PRESENTATION [--interface NAME] [--request-id RID] | " <>
           "mix kogen.shape ID --cancel [--request-id RID]"

  @doc "The usage line."
  def usage, do: @usage

  @doc "The session states."
  def states, do: @states

  @doc """
  Runs one invocation and returns `{json_map, exit_code}`. `opts`: `:root`
  (default `File.cwd!()`), `:env` (default `System.get_env()`).
  """
  def main(args, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    env = Keyword.get(opts, :env, System.get_env())

    try do
      with :ok <- unmanaged(env),
           {:ok, command} <- parse(args) do
        dispatch(root, env, command)
      end
      |> case do
        {:ok, json} -> {json, 0}
        {:refuse, code, message, id} -> {refusal(root, id, code, message), 2}
        {:refuse, code, message} -> {refusal(root, nil, code, message), 2}
        {:replay, json, exit} -> {json, exit}
      end
    rescue
      error ->
        {%{
           "session" => nil,
           "state" => nil,
           "error" => %{"code" => "internal", "message" => Exception.message(error)}
         }, 1}
    end
  end

  defp unmanaged(env) do
    case Map.get(env, "KOGEN_ROLE") do
      role when role in [nil, ""] ->
        :ok

      role ->
        {:refuse, "managed_role",
         "mix kogen.shape refuses a managed Kogen role (KOGEN_ROLE=#{role}); only external drivers shape"}
    end
  end

  # --- parsing ----------------------------------------------------------------

  @switches [
    brief: :string,
    route: :string,
    interface: :string,
    request_id: :string,
    approve: :string,
    cancel: :boolean
  ]

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} when length(positional) <= 1 ->
        if Enum.uniq_by(opts, &elem(&1, 0)) == opts,
          do: command(Map.new(opts), positional),
          else: usage_error("a flag was given twice")

      {_opts, _positional, invalid} when invalid != [] ->
        usage_error("unknown or malformed option #{inspect(elem(hd(invalid), 0))}")

      _other ->
        usage_error("at most one session ID")
    end
  end

  defp command(opts, positional) do
    with :ok <- valid(opts, :request_id, @rid, "--request-id"),
         :ok <- valid(opts, :interface, @interface, "--interface"),
         :ok <- valid(opts, :approve, @presentation, "--approve") do
      shape(opts, positional)
    end
  end

  defp shape(opts, []) do
    case Map.keys(opts) -- [:route, :interface, :request_id] do
      [:brief] -> {:ok, {:start, opts}}
      _other -> usage_error("start needs exactly --brief FILE")
    end
  end

  defp shape(opts, [id]) do
    case Enum.sort(Map.keys(opts) -- [:interface, :request_id]) do
      [] ->
        if map_size(opts) == 0,
          do: {:ok, {:status, id}},
          else: usage_error("status takes no flags")

      [:brief] ->
        {:ok, {:message, id, opts}}

      [:approve] ->
        {:ok, {:approve, id, opts}}

      [:cancel] ->
        if Map.has_key?(opts, :interface) or opts.cancel != true,
          do: usage_error("--cancel takes only --request-id"),
          else: {:ok, {:cancel, id, opts}}

      _other ->
        usage_error(
          "choose one of --brief, --approve or --cancel (--route only starts a session)"
        )
    end
  end

  defp valid(opts, key, pattern, flag) do
    case Map.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} ->
        if Regex.match?(pattern, value),
          do: :ok,
          else: usage_error("invalid #{flag} #{inspect(value)}")
    end
  end

  defp usage_error(detail), do: {:refuse, "usage", "#{detail}; #{@usage}"}

  # --- dispatch ---------------------------------------------------------------

  defp dispatch(root, env, {:start, opts}), do: start(root, env, opts)

  defp dispatch(root, env, {kind, id, opts}) do
    with {:ok, dir, _session} <- existing(root, id) do
      dispatch_existing(kind, root, env, id, dir, opts)
    end
  end

  defp dispatch(root, _env, {:status, id}) do
    with {:ok, _dir, _session} <- existing(root, id), do: {:ok, status(root, id)}
  end

  defp dispatch_existing(:message, root, env, id, dir, opts),
    do: message(root, env, id, dir, opts)

  defp dispatch_existing(:approve, root, _env, id, dir, opts) do
    with_request(
      root,
      dir,
      id,
      "approve",
      opts,
      %{"presentation" => opts.approve},
      &Approval.approve(root, id, dir, opts, &1)
    )
  end

  defp dispatch_existing(:cancel, root, _env, id, dir, opts) do
    with_request(root, dir, id, "cancel", opts, %{"cancel" => true}, fn request ->
      cancel(root, id, dir, request)
    end)
  end

  defp existing(root, id) do
    dir = Store.session_dir(root, id)

    if Regex.match?(@uuid, id) do
      existing_session(root, id, dir)
    else
      legacy_or_missing(root, id, Path.join([root, ".kogen/intents/drafts", id]))
    end
  end

  defp existing_session(root, id, dir) do
    case Store.read_session(dir) do
      {:ok, session} ->
        {:ok, dir, session}

      {:error, :schema} ->
        {:refuse, "session_not_found",
         "session #{id} has an unsupported state schema; it is left untouched", id}

      {:error, :missing} ->
        case Draft.locate(root, id) do
          {:ok, %{package_rel: rel, location: :drafts}} ->
            legacy_or_missing(root, id, Path.join(root, rel))

          _other ->
            {:refuse, "session_not_found", "no headless Shaping session #{id}", id}
        end
    end
  end

  defp legacy_or_missing(root, id, draft) do
    if File.dir?(draft) do
      {:refuse, "legacy_draft_unsupported",
       "#{Path.relative_to(draft, root)} was shaped before headless Shaping; it is left byte-for-byte " <>
         "untouched and cannot be continued by this engine. Start a new session with " <>
         "mix kogen.shape --brief FILE."}
    else
      {:refuse, "session_not_found",
       "no headless Shaping session #{inspect(id)}; sessions are addressed only by ID"}
    end
  end

  # --- idempotency ----------------------------------------------------------

  @doc false
  def digest(command, session, args) do
    canonical =
      %{"command" => command, "args" => args}
      |> then(&if session, do: Map.put(&1, "session", session), else: &1)
      |> canonical()

    Store.sha256(canonical)
  end

  defp canonical(map) when is_map(map) do
    "{" <>
      (map
       |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
       |> Enum.map_join(",", fn {key, value} ->
         Jason.encode!(to_string(key)) <> ":" <> canonical(value)
       end)) <>
      "}"
  end

  defp canonical(value), do: Jason.encode!(value)

  # Runs `fun` under a request record: a recorded outcome with the same
  # digest replays; a different digest refuses; no outcome (a crash
  # mid-command) runs again. Every attempt of one request ID runs under that
  # request's lock, so concurrent retries never both execute: the later one
  # waits and replays the recorded outcome, or refuses `busy` while the
  # first is still running.
  defp with_request(root, dir, id, command, opts, args, fun) do
    rid = Map.get(opts, :request_id) || Kogen.Intent.mint_uuid7()
    path = Store.request_path(root, dir, rid)

    locked_request(path, rid, id, fn -> run_request(path, id, command, rid, opts, args, fun) end)
  end

  defp locked_request(path, rid, id, fun) do
    case Store.with_lock(Store.request_lock(path), @request_wait_ms, fun) do
      {:ok, result} ->
        result

      {:error, :busy} ->
        {:refuse, "busy", "request ID #{rid} is still running; retry it when it ends", id}
    end
  end

  defp run_request(path, id, command, rid, opts, args, fun) do
    interface = Map.get(opts, :interface, "cli")
    args = Map.put(args, "interface", interface)
    digest = digest(command, id, args)

    record = %{
      "request_id" => rid,
      "command" => command,
      "digest" => digest,
      "received_at" => Store.now(),
      "interface" => interface,
      "input_sha256" => args["brief"],
      "outcome" => nil,
      "exit" => nil
    }

    case Store.open_request(path, record) do
      {:existing, %{"digest" => ^digest, "outcome" => outcome, "exit" => exit}}
      when is_map(outcome) ->
        {:replay, outcome, exit}

      {:existing, %{"digest" => ^digest} = existing} ->
        finish_request(path, existing, fun.(existing))

      {:existing, _other} ->
        {:refuse, "request_conflict",
         "request ID #{rid} was already used with different arguments", id}

      {:new, record} ->
        finish_request(path, record, fun.(record))
    end
  end

  defp finish_request(path, record, result) do
    {outcome, exit} =
      case result do
        {:ok, json} -> {json, 0}
        {:refuse, code, message, id} -> {refusal_json(id, nil, code, message), 2}
        {:refuse, code, message} -> {refusal_json(nil, nil, code, message), 2}
      end

    # A busy session is a transient refusal: the same request may be retried.
    # The stored record may carry the input number bound during the command.
    unless match?(%{"error" => %{"code" => "busy"}}, outcome) do
      rid = record["request_id"]

      stored =
        case Store.read_json(path) do
          {:ok, %{"request_id" => ^rid} = stored} -> stored
          _other -> record
        end

      Store.write_request!(path, %{stored | "outcome" => outcome, "exit" => exit})
    end

    {:replay, outcome, exit}
  end

  # --- start ------------------------------------------------------------------

  defp start(root, env, opts) do
    with {:ok, bytes} <- read_input(opts.brief) do
      rid = Map.get(opts, :request_id) || Kogen.Intent.mint_uuid7()
      interface = Map.get(opts, :interface, "cli")

      args = %{
        "brief" => Store.sha256(bytes),
        "route" => Map.get(opts, :route),
        "interface" => interface
      }

      path = Store.request_path(root, nil, rid)
      digest = digest("start", nil, args)

      with :none <- recorded_outcome(path, digest, nil),
           :ok <- no_build(root),
           {:ok, config} <- config(root, Map.get(opts, :route)),
           :ok <- ready(config) do
        start_locked(root, env, config, {rid, path, digest, interface, args}, bytes)
      end
    end
  end

  defp start_locked(root, env, config, {rid, path, digest, interface, args}, bytes) do
    record = %{
      "request_id" => rid,
      "command" => "start",
      "digest" => digest,
      "session" => Kogen.Intent.mint_uuid7(),
      "received_at" => Store.now(),
      "interface" => interface,
      "input_sha256" => args["brief"],
      "outcome" => nil,
      "exit" => nil
    }

    locked_request(path, rid, nil, fn ->
      start_request(root, env, config, path, record, bytes)
    end)
  end

  # A request already completed with the same arguments replays its recorded
  # outcome before any launch precondition (Build lock, login) is checked:
  # those gate only work that still has to run.
  defp recorded_outcome(path, digest, id) do
    case Store.read_json(path) do
      {:ok, %{"digest" => ^digest, "outcome" => outcome, "exit" => exit}} when is_map(outcome) ->
        {:replay, outcome, exit}

      {:ok, %{"digest" => other, "request_id" => rid}} when other != digest ->
        {:refuse, "request_conflict",
         "request ID #{rid} was already used with different arguments", id}

      _other ->
        :none
    end
  end

  defp start_request(root, env, config, path, %{"digest" => digest} = record, bytes) do
    case Store.open_request(path, record) do
      {:existing, %{"digest" => ^digest, "outcome" => outcome, "exit" => exit}}
      when is_map(outcome) ->
        {:replay, outcome, exit}

      {:existing, %{"digest" => ^digest} = existing} ->
        finish_request(path, existing, create(root, env, config, existing, bytes))

      {:existing, _other} ->
        {:refuse, "request_conflict",
         "request ID #{record["request_id"]} was already used with different arguments"}

      {:new, record} ->
        finish_request(path, record, create(root, env, config, record, bytes))
    end
  end

  defp create(root, env, config, request, bytes) do
    id = request["session"]
    dir = Store.session_dir(root, id)
    File.mkdir_p!(dir)

    if Store.read_session(dir) == {:error, :missing} do
      Store.write_session!(dir, %{
        "schema" => Store.schema(),
        "intent_id" => id,
        "route" => config.route,
        "config_fingerprint" => config_fingerprint(config),
        "harness" => Kogen.Intent.role_harness(config, :shaping),
        "model" => config.shaping.model,
        "effort" => config.shaping.effort,
        "provider_session_id" => nil,
        "nonce" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        "state" => "running",
        "error" => nil,
        "presented" => nil,
        "presentation_seq" => 0,
        "preexisting_slugs" => Draft.slugs(root),
        "baseline" => baseline(root),
        "created_at" => Store.now(),
        "turn_seq" => 0,
        "notified_questions" => [],
        "unrouted_questions" => [],
        "background_report" => nil,
        "report" => nil
      })
    end

    input =
      if Store.brief(dir) == nil do
        request_path = Store.request_path(root, nil, request["request_id"])

        Store.accept_input!(
          dir,
          bytes,
          input_meta("brief", request, []),
          request["request_id"],
          fn n ->
            current = Store.read_json(request_path) |> elem(1)
            Store.write_request!(request_path, Map.put(current, "input", n))
          end
        )
      else
        Store.brief(dir)
      end

    launch_runner(root, id, env)
    {:ok, receipt(status(root, id), request, "start", input)}
  end

  defp baseline(root) do
    branch =
      case Kogen.Git.current_branch(root) do
        {:ok, branch} -> branch
        _ -> nil
      end

    head =
      case Kogen.Git.head_sha(root) do
        {:ok, head} -> head
        _ -> nil
      end

    %{"branch" => branch, "head" => head}
  end

  defp input_meta(kind, request, open_questions) do
    %{
      "kind" => kind,
      "interface" => request["interface"],
      "request_id" => request["request_id"],
      "received_at" => request["received_at"],
      "caller" => %{
        "interface" => request["interface"],
        "request_id" => request["request_id"],
        "received_at" => request["received_at"],
        "authority" => "interface-attested"
      },
      "open_questions" => open_questions
    }
  end

  # --- continue ------------------------------------------------------------------

  defp message(root, env, id, dir, opts) do
    with {:ok, bytes} <- read_input(opts.brief),
         :none <- recorded_message(root, dir, id, opts, bytes),
         :ok <- no_pending_cancellation(dir),
         :ok <- no_build(root),
         {:ok, session} <- readable(dir),
         {:ok, config} <- session_config(root, session),
         :ok <- ready(config) do
      with_request(
        root,
        dir,
        id,
        "message",
        opts,
        %{"brief" => Store.sha256(bytes)},
        fn request ->
          accept_message(root, env, id, dir, session, request, bytes)
        end
      )
    end
    |> case do
      {:refuse, code, message} -> {:refuse, code, message, id}
      other -> other
    end
  end

  defp recorded_message(root, dir, id, opts, bytes) do
    case Map.get(opts, :request_id) do
      nil ->
        :none

      rid ->
        args = %{"brief" => Store.sha256(bytes), "interface" => Map.get(opts, :interface, "cli")}
        recorded_outcome(Store.request_path(root, dir, rid), digest("message", id, args), id)
    end
  end

  defp readable(dir) do
    case Store.read_session(dir) do
      {:ok, session} -> {:ok, session}
      _ -> {:refuse, "session_not_found", "session state is unreadable"}
    end
  end

  # The input is stored under the session's commit lock, which an approval
  # holds for its final check and rename: an input lands either before that
  # check (the approval refuses) or after the approval committed (refused
  # here), never unseen in between.
  defp accept_message(root, env, id, dir, session, request, bytes) do
    request_path = Store.request_path(root, dir, request["request_id"])

    meta = input_meta("message", request, open_at_receipt(root, session))

    stored =
      Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
        store_message(dir, id, {request, request_path}, meta, bytes)
      end)

    case stored do
      {:ok, {:stored, input}} ->
        launch_runner(root, id, env)
        {:ok, receipt(status(root, id), request, "message", input)}

      {:ok, refusal} ->
        refusal

      {:error, :busy} ->
        {:refuse, "busy", "an approval of session #{id} is committing; retry the message", id}
    end
  end

  defp store_message(dir, id, {request, request_path}, meta, bytes) do
    cond do
      Store.cancellation_busy?(dir) ->
        {:refuse, "busy", "a cancellation of session #{id} is unsettled; retry after it settles",
         id}

      Approval.committed?(dir) ->
        {:refuse, "not_ready",
         "session #{id} is approved; its Draft moved to approved/ and takes no further input", id}

      true ->
        input =
          Store.accept_input!(dir, bytes, meta, request["request_id"], fn n ->
            Store.write_request!(request_path, Map.put(request, "input", n))
          end)

        Store.update_session!(dir, fn session ->
          Map.merge(session, %{"presented" => nil, "state" => "running", "error" => nil})
        end)

        {:stored, input}
    end
  end

  defp open_at_receipt(root, session) do
    case Draft.locate(root, session["intent_id"]) do
      {:ok, package} ->
        package
        |> then(&Draft.questions_text(root, &1))
        |> Draft.open_questions()
        |> Enum.map(&Map.take(&1, ["number", "question"]))

      :none ->
        []
    end
  end

  # --- cancel ------------------------------------------------------------------

  defp cancel(root, id, dir, request) do
    path = Store.request_path(root, dir, request["request_id"])

    reserved =
      Store.with_lock(Store.commit_lock(dir), @commit_wait_ms, fn ->
        reserve_cancellation(id, dir, path, request)
      end)

    case reserved do
      {:error, :busy} ->
        {:refuse, "busy", "session #{id} is committing another short operation; retry cancel", id}

      {:ok, {:refuse, code, message, ^id}} ->
        {:refuse, code, message, id}

      {:ok, {:accepted, effect, action}} ->
        execute_cancellation(root, id, dir, path, request, effect, action)
    end
  end

  defp reserve_cancellation(id, dir, path, request) do
    {:ok, session} = Store.read_session(dir)
    lock = custody_lock(dir)

    cond do
      Approval.committed?(dir) ->
        effect = %{
          "status" => "settled",
          "reserved_at" => Store.now(),
          "owner" => nil,
          "cutoff" => cutoff(dir, session),
          "signal_status" => "not_required",
          "settled_at" => Store.now(),
          "settlement" => %{"observed_outcome" => "approved"}
        }

        persist_effect(path, request, effect)
        action = committed_cancellation_action(dir)
        {:accepted, effect, action}

      Store.cancellation_busy?(dir) ->
        existing = Store.unsettled_cancellations(dir) |> List.first()

        effect =
          (existing["effect"] || %{})
          |> Map.put("status", existing["effect"]["status"])
          |> Map.put("signal_status", "coalesced")
          |> Map.put("coalesced_with", existing["request_id"])

        persist_effect(path, request, effect)
        {:accepted, effect, :coalesced}

      session["state"] == "cancelled" ->
        effect = %{
          "status" => "settled",
          "reserved_at" => Store.now(),
          "owner" => nil,
          "cutoff" => cutoff(dir, session),
          "signal_status" => "not_required",
          "settled_at" => Store.now(),
          "settlement" => %{"observed_outcome" => "cancelled"}
        }

        persist_effect(path, request, effect)
        {:accepted, effect, :none}

      live_lock?(lock) and not runner_lock?(dir, lock) ->
        {:refuse, "busy", "another Kogen process holds session #{id}; retry cancel", id}

      true ->
        owner = owner_identity(lock)

        effect = %{
          "status" => "pending",
          "reserved_at" => Store.now(),
          "owner" => owner,
          "cutoff" => cutoff(dir, session),
          "signal_status" => reserved_signal_status(dir, lock)
        }

        persist_effect(path, request, effect)
        action = active_cancellation_action(dir, lock)
        {:accepted, effect, action}
    end
  end

  defp committed_cancellation_action(dir),
    do: if(Approval.recovery_pending?(dir), do: :recover, else: :none)

  defp reserved_signal_status(dir, lock),
    do: if(runner_lock?(dir, lock), do: "reserved", else: "not_sent")

  defp active_cancellation_action(dir, lock),
    do: if(runner_lock?(dir, lock), do: :signal, else: :recover)

  defp persist_effect(path, request, effect) do
    request_id = request["request_id"]

    current =
      case Store.read_json(path) do
        {:ok, %{"request_id" => ^request_id} = stored} -> stored
        _ -> request
      end

    Store.write_request!(path, Map.put(current, "effect", effect))
  end

  defp execute_cancellation(root, id, dir, path, request, effect, action) do
    {effect, recover?} =
      case action do
        :signal ->
          signal_cancellation(dir, effect)

        :recover ->
          {Map.merge(effect, %{"signal_status" => "not_sent"}), true}

        :coalesced ->
          {effect, not owner_live?(effect["owner"])}

        :none ->
          {effect, false}
      end

    # The command still owns this request's idempotency lock. Persisting the
    # signal observation here means the runner's settlement update must wait
    # and then merge it with the original acknowledgement outcome.
    current = Store.read_json(path) |> elem(1)
    Store.write_request!(path, Map.put(current, "effect", effect))
    if recover?, do: launch_runner(root, id, %{})

    ack = status(root, id) |> Map.put("receipt", command_receipt(request, "cancel", "pending"))
    {:ok, ack}
  end

  defp signal_cancellation(dir, effect) do
    if cancellation_target_current?(dir, effect) do
      owner = effect["owner"]

      {output, exit} =
        System.cmd("kill", ["-TERM", to_string(owner["pid"])], stderr_to_stdout: true)

      if exit == 0 do
        effect =
          Map.merge(effect, %{"signal_status" => "sent", "signaled_at" => Store.now()})

        {effect, false}
      else
        effect =
          Map.merge(effect, %{
            "status" => "uncertain",
            "signal_status" => "failed",
            "signal_error" => String.trim(output),
            "signal_failed_at" => Store.now()
          })

        {effect, true}
      end
    else
      effect =
        Map.merge(effect, %{
          "signal_status" => "identity_changed",
          "signal_skipped_at" => Store.now()
        })

      {effect, true}
    end
  end

  defp cancellation_target_current?(dir, effect) do
    owner = effect["owner"]
    cutoff = effect["cutoff"] || %{}
    lock = custody_lock(dir)

    owner_live?(owner) and runner_lock?(dir, lock) and
      owner_identity(lock) == owner and
      case Store.read_session(dir) do
        {:ok, session} ->
          session["turn_seq"] == cutoff["turn_through"] and
            session["turn_active"] == cutoff["turn_active"] and
            input_through(dir) == cutoff["input_through"]

        _ ->
          false
      end
  end

  defp input_through(dir) do
    Store.inputs(dir)
    |> Enum.map(& &1["number"])
    |> Enum.max(fn -> 0 end)
  end

  defp owner_live?(%{"pid" => pid, "started_at" => started})
       when is_integer(pid) and is_binary(started) and started != "",
       do: Kogen.ProcessCustody.process_start(pid) == started

  defp owner_live?(_), do: false

  defp owner_identity(%{"pid" => pid, "started_at" => started})
       when is_integer(pid) and is_binary(started),
       do: %{"pid" => pid, "started_at" => started}

  defp owner_identity(_), do: nil

  defp custody_lock(dir) do
    case Kogen.ProcessCustody.read_lock(dir) do
      {:ok, lock} -> lock
      _ -> nil
    end
  end

  defp live_lock?(%{"pid" => pid, "started_at" => started})
       when is_integer(pid) and is_binary(started) and started != "",
       do: Kogen.ProcessCustody.process_start(pid) == started

  defp live_lock?(_), do: false

  defp runner_lock?(dir, lock) when is_map(lock) do
    lock["build_id"] == "kogen-shaping-runner" and
      case live_runner(dir) do
        {:ok, pid} -> lock["pid"] == pid
        _ -> false
      end
  end

  defp runner_lock?(_dir, _lock), do: false

  defp cutoff(dir, session) do
    input_through =
      Store.inputs(dir)
      |> Enum.map(& &1["number"])
      |> Enum.max(fn -> 0 end)

    %{
      "input_through" => input_through,
      "turn_through" => session["turn_seq"] || 0,
      "turn_active" => session["turn_active"] == true
    }
  end

  defp command_receipt(request, command, effect_status) do
    %{
      "request_id" => request["request_id"],
      "command" => command,
      "received_at" => request["received_at"],
      "effect_status" => effect_status
    }
  end

  defp receipt(json, request, command, input) do
    json
    |> Map.put("receipt", command_receipt(request, command, "received"))
    |> Map.put("received_input", %{
      "id" => input["id"],
      "number" => input["number"],
      "request_id" => request["request_id"],
      "status" => "received"
    })
  end

  # --- runner launch -------------------------------------------------------------

  @doc "The live runner's OS pid, from the session's custody lock, or `:none`."
  def live_runner(dir) do
    case Kogen.ProcessCustody.read_lock(dir) do
      {:ok,
       %{
         "pid" => pid,
         "started_at" => started,
         "build_id" => "kogen-shaping-runner"
       }}
      when is_integer(pid) and started != "" ->
        if Kogen.ProcessCustody.process_start(pid) == started, do: {:ok, pid}, else: :none

      _other ->
        :none
    end
  end

  defp launch_runner(root, id, _env) do
    dir = Store.session_dir(root, id)

    if live_runner(dir) == :none do
      detach = Path.join(root, "priv/kogen/shaping/detach.py")
      log = Path.join(dir, "runner.log")
      mix = System.find_executable("mix") || "mix"
      python = System.find_executable("python3") || "python3"

      {output, status} =
        System.cmd(python, [detach, log, mix, "kogen.shape.runner", id],
          cd: root,
          stderr_to_stdout: true
        )

      Store.event!(dir, "runner_launched", %{"exit" => status, "pid" => String.trim(output)})
    end

    :ok
  end

  @doc false
  def wake_pending(root, id, dir) do
    with {:ok, %{"state" => "running"} = session} <- Store.read_session(dir),
         [_ | _] <- Runner.pending(root, dir, session) do
      launch_runner(root, id, %{})
    else
      _ -> :ok
    end
  end

  # --- checks ----------------------------------------------------------------------

  defp read_input(path) do
    case File.read(path) do
      {:ok, ""} ->
        {:refuse, "invalid_input", "#{path} is empty"}

      {:ok, bytes} when byte_size(bytes) > @max_input ->
        {:refuse, "invalid_input", "#{path} is larger than 1 MiB"}

      {:ok, bytes} ->
        if String.valid?(bytes),
          do: {:ok, bytes},
          else: {:refuse, "invalid_input", "#{path} is not valid UTF-8"}

      {:error, reason} ->
        {:refuse, "invalid_input", "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp no_build(root) do
    if File.exists?(Path.join(root, @build_lock)),
      do:
        {:refuse, "build_running",
         "a Build holds #{@build_lock}; the Shaping audit is skipped while it runs"},
      else: :ok
  end

  defp no_pending_cancellation(dir) do
    if Store.cancellation_busy?(dir),
      do: {:refuse, "busy", "an accepted cancellation is unsettled; retry after it settles"},
      else: :ok
  end

  defp config(root, route) do
    case Kogen.Intent.read_config(Path.join(root, @config_path), route) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:refuse, "usage", reason}
    end
  end

  @doc false
  def config_fingerprint(config) do
    Kogen.Intent.config_fingerprint(config)
  end

  @doc false
  def session_config(root, session) do
    with {:ok, config} <- config(root, session["route"]) do
      expected = session["config_fingerprint"]

      same? =
        if is_binary(expected),
          do: expected == config_fingerprint(config),
          else:
            session["harness"] == Kogen.Intent.role_harness(config, :shaping) and
              session["model"] == config.shaping.model and
              session["effort"] == config.shaping.effort

      if same?,
        do: {:ok, config},
        else:
          {:refuse, "configuration_changed",
           "the admitted role configuration changed; start a new Shaping session"}
    end
  end

  @doc false
  def configuration_current?(root, session), do: match?({:ok, _}, session_config(root, session))

  defp ready(config) do
    case quietly(fn -> Kogen.Harness.open_roles(config, [:shaping, :expert]) end) do
      {:ok, runtime} ->
        quietly(fn -> Kogen.Harness.close(runtime) end)
        :ok

      {:error, reason} ->
        {:refuse, "harness_not_ready", reason}
    end
  end

  @doc """
  Runs `fun` with this process's group leader set to standard error, so
  anything it prints (ProcessCustody's "Reclaimed…" lines, harness
  readiness chatter) never reaches the one-line JSON stdout.
  """
  def quietly(fun) do
    leader = Process.group_leader()
    Process.group_leader(self(), Process.whereis(:standard_error))

    try do
      fun.()
    after
      Process.group_leader(self(), leader)
    end
  end

  # --- status -----------------------------------------------------------------------

  defp refusal(root, id, code, message) do
    state =
      with id when is_binary(id) <- id,
           {:ok, session} <- Store.read_session(Store.session_dir(root, id)) do
        session["state"]
      else
        _ -> nil
      end

    refusal_json(id, state, code, message)
  end

  defp package_field({:ok, found}, fun), do: fun.(found)
  defp package_field(_package, _fun), do: nil

  defp refusal_json(id, state, code, message) do
    %{"session" => id, "state" => state, "error" => %{"code" => code, "message" => message}}
  end

  @doc "The read-only status map of session `id`. Never locks, never recovers."
  def status(root, id) do
    dir = Store.session_dir(root, id)
    {:ok, session} = Store.read_session(dir)
    package = Draft.locate(root, id)
    text = package_field(package, &Draft.questions_text(root, &1))
    recorded = Store.recorded(dir, text)
    pending = Enum.reject(Store.messages(dir), &Map.has_key?(recorded, &1["id"]))
    approval = Approval.journal_status(dir)
    presented = current_presentation(session, dir)
    open_work? = pending != [] or Draft.open_questions(text) != []
    stale = stale_presentation(root, {session, package, open_work?}, presented, approval)
    presented = if stale, do: nil, else: presented
    runner = live_runner(dir)
    execution = runner_health(dir, session, runner)
    approval_running? = approval && approval["status"] == "approval_in_progress"

    state = observed_state(approval_running?, execution, session, presented, runner, stale)
    observed_error = status_error(execution, stale, session)

    %{
      "session" => id,
      "state" => state,
      "stored_state" => session["state"],
      "state_source" => state_source(approval_running?, state, session),
      "execution" => execution,
      "slug" => package_field(package, & &1.slug),
      "package" => package_field(package, & &1.package_rel),
      "route" => session["route"],
      "turn" => session["turn_seq"],
      "turn_active" => session["turn_active"] == true,
      "provider" => %{
        "harness" => session["harness"],
        "session_id" => session["provider_session_id"]
      },
      "questions" => Draft.open_questions(text),
      "presented" => presented_json(root, id, presented),
      "background_report" => session["background_report"],
      "report" => session["report"],
      "pending_inputs" => Enum.map(pending, & &1["id"]),
      "inputs" => input_progress(dir, text),
      "cancellation" => cancellation_status(dir),
      "unrouted_questions" => session["unrouted_questions"] || [],
      "approval" => approval,
      "authority" => "interface-attested",
      "runner" => match?({:ok, _}, runner),
      "log" => Path.join(dir, "runner.log"),
      "updated_at" => session["updated_at"],
      "error" => observed_error
    }
  end

  defp observed_state(approval_running?, execution, session, presented, runner, stale) do
    cond do
      approval_running? -> "running"
      execution["status"] == "interrupted" -> "interrupted"
      true -> display_state(session, presented, runner, stale, execution)
    end
  end

  defp status_error(execution, stale, session) do
    cond do
      execution["status"] == "interrupted" ->
        %{
          "code" => "runner_interrupted",
          "message" => execution["cause"],
          "ownership" => Map.drop(execution, ["status", "cause"])
        }

      stale ->
        stale

      get_in(session, ["error", "code"]) == "cancellation_uncertain" ->
        session["error"]

      execution["status"] == "uncertain" ->
        %{
          "code" => "runner_custody_uncertain",
          "message" => execution["cause"],
          "ownership" => Map.drop(execution, ["status", "cause"])
        }

      true ->
        session["error"]
    end
  end

  defp state_source(approval_running?, state, session) do
    cond do
      approval_running? -> "approval_journal"
      state == session["state"] -> "session"
      true -> "runner_custody"
    end
  end

  defp runner_health(dir, _session, {:ok, pid}) do
    lock = custody_lock(dir)

    %{
      "status" => "running",
      "pid" => pid,
      "started_at" => lock && lock["started_at"],
      "build_id" => lock && lock["build_id"]
    }
  end

  defp runner_health(dir, session, :none) do
    case custody_lock(dir) do
      nil ->
        if session["turn_active"] == true,
          do: %{"status" => "interrupted", "cause" => "runner custody lock is absent"},
          else: %{"status" => "idle"}

      lock ->
        owned_runner_health(session, lock)
    end
  end

  defp owned_runner_health(session, lock) do
    owner = owner_identity(lock)
    recorded_runner? = lock["build_id"] == "kogen-shaping-runner" and is_map(owner)
    dead? = not live_lock?(lock)
    groups = lock["groups"] || []

    cond do
      interrupted_owner?(dead?, recorded_runner?, session) ->
        %{
          "status" => "interrupted",
          "cause" => "runner custody owner is absent or its PID start time changed",
          "owner" => owner,
          "build_id" => lock["build_id"],
          "groups" => groups
        }

      dead? and session["turn_active"] == true ->
        %{
          "status" => "uncertain",
          "cause" => "the active turn has no verified shaping runner custody owner",
          "owner" => owner,
          "build_id" => lock["build_id"],
          "groups" => groups
        }

      dead? ->
        %{"status" => "idle"}

      true ->
        %{
          "status" => "uncertain",
          "cause" => "a live custody owner does not identify itself as the shaping runner",
          "owner" => owner,
          "build_id" => lock["build_id"],
          "groups" => groups
        }
    end
  end

  defp interrupted_owner?(dead?, recorded_runner?, session),
    do: dead? and recorded_runner? and active_session?(session)

  defp active_session?(session),
    do: session["turn_active"] == true or session["state"] == "running"

  defp input_progress(dir, questions_text) do
    recorded = Store.recorded(dir, questions_text)

    for input <- Store.inputs(dir) do
      offers = Store.offers(dir, input["number"])
      recorded_once = Map.get(recorded, input["id"]) == 1

      %{
        "id" => input["id"],
        "number" => input["number"],
        "kind" => input["kind"],
        "request_id" => input["request_id"],
        "received_at" => input["received_at"],
        "progress" =>
          cond do
            recorded_once -> "recorded"
            offers != [] -> "offered"
            true -> "received"
          end,
        "recorded_exactly_once" => recorded_once,
        "offers" => Enum.map(offers, &Map.take(&1, ["launch_id", "turn", "via", "at"]))
      }
    end
  end

  defp cancellation_status(dir) do
    cancellations =
      Enum.filter(Store.requests(dir), fn request ->
        request["command"] == "cancel" and is_map(request["effect"])
      end)

    selected =
      Enum.find(Enum.reverse(cancellations), fn request ->
        get_in(request, ["effect", "status"]) in ["pending", "uncertain"]
      end) || List.last(cancellations)

    case selected do
      nil ->
        nil

      request ->
        cancellation_observation(dir, request)
    end
  end

  defp cancellation_observation(dir, request) do
    effect = request["effect"]
    owner = effect["owner"]
    lock = custody_lock(dir)
    owner_present = owner_live?(owner)
    active_resolver = runner_lock?(dir, lock)

    reported_status = cancellation_state(effect["status"], owner, owner_present, active_resolver)

    %{
      "request_id" => request["request_id"],
      "status" => reported_status,
      "owner" => owner,
      "owner_present" => owner_present,
      "custody_present" => live_lock?(lock),
      "cutoff" => effect["cutoff"],
      "signal_status" => effect["signal_status"],
      "settled_at" => effect["settled_at"],
      "settlement" => effect["settlement"],
      "error" => cancellation_error(effect, reported_status)
    }
  end

  defp cancellation_state(status, owner, owner_present, active_resolver) do
    case status do
      "pending" when is_nil(owner) -> "pending"
      "pending" when owner_present or active_resolver -> "pending"
      "pending" -> "uncertain"
      other -> other
    end
  end

  defp cancellation_error(effect, reported_status) do
    effect["signal_error"] || effect["cleanup_error"] ||
      if(reported_status == "uncertain" and effect["status"] == "pending",
        do: "the bound cancellation owner is absent and settlement is unverified",
        else: nil
      )
  end

  @doc """
  The session's presentation while it is still current: any input accepted
  after it was presented clears it.
  """
  def current_presentation(session, dir) do
    case session["presented"] do
      %{"inputs_through" => through} = presented ->
        if Enum.any?(Store.messages(dir), &(&1["number"] > through)), do: nil, else: presented

      _other ->
        nil
    end
  end

  # Status never mutates: a ready session whose presentation no longer
  # matches the Draft, HEAD, route or report is shown blocked (running while
  # a runner re-audits it) until `--approve` or a message re-audits it.
  defp display_state(%{"state" => "ready"}, nil, _runner, stale, %{"status" => "uncertain"})
       when is_map(stale),
       do: "running"

  defp display_state(%{"state" => "ready"}, nil, {:ok, _pid}, _stale, _execution), do: "running"

  defp display_state(%{"state" => "ready"}, nil, _runner, stale, _execution)
       when is_map(stale),
       do: "blocked"

  defp display_state(%{"state" => "ready"}, nil, _runner, _stale, _execution), do: "running"
  defp display_state(%{"state" => state}, _presented, _runner, _stale, _execution), do: state

  # nil while the presentation still matches the current Draft revision,
  # HEAD, route and its current full report; otherwise the reason. An
  # approval in progress for this presentation changes the Draft bytes by
  # design (approval.md), so it is reported through `approval` instead.
  defp stale_presentation(_root, _context, nil, _approval), do: nil

  defp stale_presentation(_root, _context, %{"id" => pid}, %{
         "presentation" => pid,
         "status" => status
       })
       when status in ["approval_in_progress", "approved"],
       do: nil

  defp stale_presentation(root, {session, package, open_work?}, presented, _approval) do
    %{"revision" => revision, "head" => head, "route" => route} = presented

    current? =
      configuration_current?(root, session) and not open_work? and
        match?({:ok, %{location: :drafts}}, package) and
        Draft.revision(root, elem(package, 1)) == revision and
        current_head(root) == head and session["route"] == route and
        Report.status(root, presented["slug"], revision, head, route) == :current and
        match?(
          {:ok, %{"scope" => "full", "readiness" => "ready"}},
          Report.read(root, presented["slug"], revision)
        )

    if current?,
      do: nil,
      else: %{
        "code" => "presentation_superseded",
        "message" =>
          "#{presented["id"]} no longer matches the Draft, HEAD, route, open work or its ready report; " <>
            "--approve re-audits it"
      }
  end

  defp current_head(root) do
    case Kogen.Git.head_sha(root) do
      {:ok, head} -> head
      _ -> nil
    end
  end

  defp presented_json(_root, _id, nil), do: nil

  defp presented_json(root, id, presented) do
    proposal = Path.join(root, presented["proposal_dir"])

    presented
    |> Map.take(["id", "revision", "head", "route", "presented_at", "report_json", "report_md"])
    |> Map.merge(%{
      "proposal_dir" => proposal,
      "intent_md" => Path.join(proposal, "INTENT.md"),
      "scenarios_yaml" => Path.join(proposal, "scenarios.yaml"),
      "questions_md" => Path.join(proposal, "questions.md"),
      "approve_command" => "mix kogen.shape #{id} --approve #{presented["id"]}"
    })
  end
end
