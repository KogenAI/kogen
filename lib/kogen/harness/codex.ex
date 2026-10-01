defmodule Kogen.Harness.Codex do
  @moduledoc """
  The Codex adapter behind `Kogen.Harness`: headless Shaping Controller turns, Developer
  turns, and independent reviews on managed native Codex.
  `KOGEN_HARNESS` can select an alternate executable for offline testing.
  Codex thread IDs are exposed as `session_id` to the build state machine.
  """
  alias Kogen.Harness.Verdict

  @common_flags [
    "--enable",
    "hooks",
    "--dangerously-bypass-hook-trust",
    "--dangerously-bypass-approvals-and-sandbox"
  ]
  # Provider stop, exit and failure evidence keeps the last
  # `@output_tail_bytes` bytes of the stream, not its head, so a classifying
  # line (a rate-limit or overload marker near the end of a long capture,
  # itself up to ~10 KB for a Claude `result` event) survives whole for
  # `Kogen.Harness.ProviderMarker.classify/1`.
  @output_tail_bytes 16_384

  @doc "Launches a fresh Developer turn with the prompt on stdin."
  def launch_developer(prompt, model, effort, policy_environment, context) do
    with_context(
      context,
      &run_turn(developer_args(model, effort), prompt, policy_environment, &1)
    )
  end

  @doc "Resumes the exact Developer thread with the prompt on stdin."
  def resume_developer(session_id, text, model, effort, policy_environment, context) do
    with_context(
      context,
      &run_turn(developer_args(model, effort, session_id), text, policy_environment, &1)
    )
  end

  @doc "Launches a fresh Build Developer turn; its final agent message is returned as notes."
  def launch_build_developer(prompt, model, effort, policy_environment, context) do
    with_context(
      context,
      &notes_turn(developer_args(model, effort), prompt, policy_environment, nil, &1)
    )
  end

  @doc "Resumes the exact Build Developer thread; its final agent message is returned as notes."
  def resume_build_developer(session_id, text, model, effort, policy_environment, context) do
    with_context(
      context,
      &notes_turn(
        developer_args(model, effort, session_id),
        text,
        policy_environment,
        session_id,
        &1
      )
    )
  end

  @doc false
  def developer_args(model, effort, resume_session_id \\ nil) do
    prefix = if resume_session_id, do: ["exec", "resume"], else: ["exec"]
    suffix = if resume_session_id, do: [resume_session_id, "-"], else: ["-"]
    prefix ++ exec_flags(model, effort) ++ suffix
  end

  @doc "Launches an independent Reviewer and requires a schema-valid Verdict."
  def launch_reviewer(prompt, model, effort, context) do
    with_context(context, &review(nil, prompt, model, effort, &1))
  end

  @doc """
  Resumes the exact Reviewer thread once (`exec resume`) with the
  schema-error re-ask on stdin, and requires a schema-valid verdict against
  the same per-launch schema (the context's `:ledger_paths` and
  `:scenario_ids`).
  """
  def resume_reviewer(session_id, prompt, model, effort, context) do
    with_context(context, &review({:resume, session_id}, prompt, model, effort, &1))
  end

  defp review(session, prompt, model, effort, context) do
    # Codex writes the last message itself, so inside a Build it lives in the
    # Build temp dir the boundary grants.
    dir = temporary_directory("review", Map.get(context, :tmp_dir))
    schema_path = Path.join(dir, "verdict.schema.json")
    message_path = Path.join(dir, "verdict.json")
    ledger_paths = Map.get(context, :ledger_paths, [])
    scenario_ids = Map.get(context, :scenario_ids, [])
    File.write!(schema_path, Verdict.schema(ledger_paths, scenario_ids))

    try do
      args =
        reviewer_args(session, model, effort) ++
          ["--output-schema", schema_path, "--output-last-message", message_path, "-"]

      {output, exit_code} =
        run_with_stdin(
          context,
          context.args ++ args,
          prompt,
          merge_environment(context.env, [{"KOGEN_ROLE", "reviewer"}])
        )

      case parse_turn(decode_events(output), exit_code, output) do
        {:ok, turn} ->
          reviewer_response(turn, message_path, verdict_opts(ledger_paths, scenario_ids), output)

        {:error, _reason} = error ->
          error
      end
    after
      File.rm_rf(dir)
    end
  end

  # A context with no per-launch scenario ids keeps the legacy validation
  # shape (a bare boolean), which never requires the per-launch evidence
  # `receipt` field or lookaround-free `path` pattern. Threading
  # `Kogen.Harness.with_scenarios/2` opts into the per-launch schema and its
  # `{:error, [errors]}` validation.
  defp verdict_opts(ledger_paths, []), do: ledger_paths != []

  defp verdict_opts(ledger_paths, scenario_ids),
    do: %{ledger?: ledger_paths != [], ledger_paths: ledger_paths, scenario_ids: scenario_ids}

  defp reviewer_response(turn, message_path, verdict_opts, output) do
    message = reviewer_message(message_path, turn.events)

    case Verdict.parse(message, verdict_opts) do
      {:ok, verdict} ->
        Verdict.persist(message, turn.session_id)
        {:ok, Map.put(verdict, :session_id, turn.session_id)}

      {:error, errors} ->
        {:error,
         {:malformed_verdict, 0,
          %{
            "reviewer_session_id" => turn.session_id,
            "message" => message,
            "output_tail" => output_tail(output),
            "errors" => errors
          }}}
    end
  end

  @doc false
  def reviewer_args(model, effort), do: ["exec"] ++ exec_flags(model, effort)

  @doc false
  def reviewer_args(nil, model, effort), do: reviewer_args(model, effort)

  def reviewer_args({:resume, session_id}, model, effort),
    do: ["exec", "resume", session_id] ++ exec_flags(model, effort)

  defp exec_flags(model, effort) do
    model_flags(model, effort) ++ @common_flags ++ ["--json"]
  end

  defp model_flags(model, effort) do
    ["--model", model, "-c", "model_reasoning_effort=" <> Jason.encode!(effort)]
  end

  defp reviewer_message(path, events) do
    case File.read(path) do
      {:ok, text} ->
        text

      _ ->
        events
        |> Enum.filter(
          &(&1["type"] == "item.completed" && get_in(&1, ["item", "type"]) == "agent_message")
        )
        |> List.last()
        |> case do
          nil -> ""
          event -> get_in(event, ["item", "text"]) || ""
        end
    end
  end

  @doc """
  Launches a fresh Expert thread for one question on stdin with the same
  unattended flags as every Codex role; its final agent message is returned.
  """
  def launch_expert(prompt, model, effort, context),
    do: launch_reader("expert", prompt, model, effort, context)

  @doc "Launches one fresh blind auditor session with its findings schema."
  def launch_auditor(prompt, model, effort, context) do
    with_context(context, fn selected ->
      dir = temporary_directory("auditor", Map.get(context, :tmp_dir))
      schema_path = Path.join(dir, "auditor.schema.json")
      File.write!(schema_path, Jason.encode!(Map.fetch!(context, :output_schema)))

      try do
        args = auditor_args(model, effort) ++ ["--output-schema", schema_path, "-"]

        removed =
          ~w(KOGEN_VERIFICATION_CONTEXT KOGEN_VERIFICATION_RETRY_LIMIT KOGEN_VERIFICATION_TARGETS KOGEN_EXPERT KOGEN_CODEX_CONTEXT_RECEIPT KOGEN_HARNESS_HOME)
          |> Enum.map(&{&1, nil})

        extra_env =
          merge_environment(selected.env, [
            {"KOGEN_ROLE", "auditor"},
            {"GIT_OPTIONAL_LOCKS", "0"} | removed
          ])

        {output, exit_code} =
          run_with_stdin(selected, selected.args ++ args, prompt, extra_env)

        with {:ok, turn} <- parse_turn(decode_events(output), exit_code, output),
             do: {:ok, %{session_id: turn.session_id, message: turn.message}}
      after
        File.rm_rf(dir)
      end
    end)
  end

  @doc false
  def auditor_args(model, effort) do
    ["exec"] ++
      exec_flags(model, effort) ++
      [
        "--disable",
        "multi_agent",
        "--disable",
        "apps",
        "--disable",
        "plugins",
        "--disable",
        "shell_snapshot"
      ]
  end

  defp launch_reader(role, prompt, model, effort, context) do
    with_context(context, fn selected ->
      removed =
        Enum.map(
          ~w(KOGEN_VERIFICATION_CONTEXT KOGEN_VERIFICATION_RETRY_LIMIT KOGEN_VERIFICATION_TARGETS KOGEN_EXPERT),
          &{&1, nil}
        )

      {output, exit_code} =
        run_with_stdin(
          selected,
          selected.args ++ expert_args(model, effort),
          prompt,
          merge_environment(selected.env, [{"KOGEN_ROLE", role} | removed])
        )

      with {:ok, turn} <- parse_turn(decode_events(output), exit_code, output) do
        {:ok, %{session_id: turn.session_id, message: turn.message}}
      end
    end)
  end

  @doc false
  def expert_args(model, effort), do: ["exec"] ++ exec_flags(model, effort) ++ ["-"]

  @doc """
  Runs one headless Shaping Controller turn (`codex exec [resume ID] ... --json -`)
  with the prompt on stdin. `kind` is `{:fresh, _}` or `{:resume, thread_id}`;
  the raw provider stream is written live to the context's `:log_path`. See
  `Kogen.Harness.shaping_turn/5` for the return shapes.
  """
  def shaping_turn(kind, prompt, model, effort, context) do
    with_context(context, fn selected ->
      resume_id =
        case kind do
          {:resume, id} when is_binary(id) and id != "" -> id
          {:fresh, _id} -> nil
          other -> raise ArgumentError, "unsupported shaping turn kind: #{inspect(other)}"
        end

      args = shaping_args(model, effort, resume_id)

      stdin =
        case Map.get(selected, :channel) do
          channel when is_binary(channel) and channel != "" -> channel <> "\n\n" <> prompt
          _ -> prompt
        end

      {output, exit_code, timed_out} = run_shaping(selected, args, stdin)
      shaping_result(resume_id, output, exit_code, timed_out)
    end)
  end

  defp shaping_result(resume_id, output, exit_code, timed_out) do
    events = decode_events(output)
    observed = observed_thread(output)

    cond do
      timed_out ->
        {:error, {:timeout, %{provider_session_id: observed || resume_id}}}

      resume_id != nil and String.contains?(output, "no rollout found") ->
        {:error, {:provider_session_unavailable, output_tail(output)}}

      resume_id != nil and observed != nil and observed != resume_id ->
        {:error, {:provider_session_mismatch, %{expected: resume_id, actual: observed}}}

      true ->
        parsed_shaping_result(events, exit_code, output, observed)
    end
  end

  defp parsed_shaping_result(events, exit_code, output, observed) do
    case parse_turn(events, exit_code, output) do
      {:ok, turn} ->
        {:ok,
         %{
           provider_session_id: turn.session_id,
           exit_code: exit_code,
           usage: last_turn_usage(events),
           timed_out: false
         }}

      {:error, reason} ->
        {:error, {:provider_failure, reason, %{provider_session_id: observed}}}
    end
  end

  defp last_turn_usage(events) do
    events
    |> Enum.filter(&(&1["type"] == "turn.completed"))
    |> List.last()
    |> case do
      nil -> nil
      event -> event["usage"]
    end
  end

  defp run_shaping(context, args, stdin_text) do
    dir = temporary_directory("stdin")
    tmp = Path.join(dir, "prompt")
    File.write!(tmp, stdin_text)

    argv = Map.get(context, :prefix, []) ++ [context.executable | context.args ++ args]
    extra_env = merge_environment(context.env, [{"KOGEN_ROLE", "shaping"}])

    custody_opts =
      [
        stdin_path: tmp,
        tmp_dir: dir,
        env: extra_env,
        log_path: Map.fetch!(context, :log_path)
      ] ++
        custody_registration(context, extra_env) ++
        hard_timeout(context) ++
        on_start_option(context)

    case Kogen.ProcessCustody.run(argv, context[:cwd] || File.cwd!(), custody_opts) do
      {:ok, facts} ->
        output = facts["log_bytes"] || facts["output"] || ""
        {output, facts["exit_code"], facts["timed_out"] == true}

      {:error, reason} ->
        {to_string(reason), 1, false}
    end
  end

  defp hard_timeout(%{timeout_ms: ms}) when is_integer(ms) and ms > 0, do: [timeout_ms: ms]
  defp hard_timeout(_context), do: []

  @doc false
  def shaping_args(model, effort, resume_id \\ nil) do
    %{command: stop, timeout: stop_timeout} = Kogen.Harness.shaping_stop_hook()
    %{command: steer, timeout: steer_timeout} = Kogen.Harness.shaping_steer_hook()

    ["exec"] ++
      if(resume_id, do: ["resume", resume_id], else: []) ++
      model_flags(model, effort) ++
      @common_flags ++
      [
        "-c",
        hook_setting("Stop", stop, stop_timeout),
        "-c",
        hook_setting("PostToolUse", steer, steer_timeout),
        "-c",
        ~s(web_search="live"),
        "--json",
        "-"
      ]
  end

  defp hook_setting(event, command, timeout) do
    "hooks.#{event}=[{hooks=[{type=\"command\",command=#{Jason.encode!(command)},timeout=#{timeout}}]}]"
  end

  # Every launch receives the session's Codex launch context; there is no
  # contextless path that re-reads configuration or opens a runtime here.
  defp with_context(%{harness: "codex"} = context, function), do: function.(context)

  defp with_context(context, _function) do
    raise ArgumentError,
          "Codex launch requires a Codex launch context, got: #{inspect(Map.get(context || %{}, :harness))}"
  end

  defp merge_environment(base, overrides),
    do: Map.merge(Map.new(base), Map.new(overrides)) |> Map.to_list()

  defp run_turn(args, stdin_text, policy_environment, context) do
    {output, exit_code} =
      run_with_stdin(
        context,
        context.args ++ args,
        stdin_text,
        merge_environment(context.env, [{"KOGEN_ROLE", "developer"} | policy_environment])
      )

    parse_turn(decode_events(output), exit_code, output)
  end

  # A Build Developer turn carries no handoff schema and owns no output file.
  # The final completed agent message (possibly empty) is the unverified notes;
  # provider, transport and session failures stay failures.
  defp notes_turn(args, stdin_text, policy_environment, resumed_id, context) do
    context = if resumed_id, do: context, else: Map.put(context, :await_session, true)

    {output, exit_code, timed_out} =
      run_with_stdin_facts(
        context,
        context.args ++ args,
        stdin_text,
        merge_environment(context.env, [{"KOGEN_ROLE", "developer"} | policy_environment])
      )

    # A turn that completed inside the TERM grace is a settled turn, not a
    # timeout.
    parsed =
      case {timed_out, parse_turn(decode_events(output), exit_code, output)} do
        {true, {:ok, _turn} = settled} -> settled
        {true, _incomplete} -> :timed_out
        {false, parsed} -> parsed
      end

    case parsed do
      :timed_out ->
        {:error,
         {:developer_turn_timeout,
          %{
            harness: "codex",
            outcome: :turn_timeout,
            diagnostics: output,
            session_id: observed_thread(output) || resumed_id,
            output_tail: output_tail(output)
          }}}

      {:ok, turn} ->
        evidence = %{
          harness: "codex",
          outcome: :settled,
          diagnostics: output,
          session_id: turn.session_id,
          message: turn.message,
          message_sha256: digest(turn.message)
        }

        {:ok,
         %{session_id: turn.session_id, message: turn.message, invocation_evidence: evidence}}

      {:error, reason} ->
        {:error,
         {:developer_transport_failure, reason,
          %{
            harness: "codex",
            outcome: :provider_failure,
            diagnostics: output,
            # The thread a failed turn started (or resumed), so a provider
            # overload can resume that same session once.
            session_id: observed_thread(output),
            output_tail: output_tail(output)
          }}}
    end
  end

  defp observed_thread(output) do
    output
    |> decode_events()
    |> Enum.find_value(fn
      %{"type" => "thread.started", "thread_id" => id} when is_binary(id) and id != "" -> id
      _event -> nil
    end)
  end

  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  # The last `@output_tail_bytes` bytes of the raw stream, byte-accurate
  # (never splitting a multi-byte codepoint), carried on transport and
  # Reviewer failure evidence for `Kogen.Harness.ProviderMarker.classify/1`.
  defp output_tail(bytes) when byte_size(bytes) <= @output_tail_bytes, do: valid_utf8(bytes)

  defp output_tail(bytes),
    do: valid_utf8(binary_part(bytes, byte_size(bytes) - @output_tail_bytes, @output_tail_bytes))

  defp valid_utf8(bytes) do
    if String.valid?(bytes), do: bytes, else: String.replace_invalid(bytes)
  end

  defp decode_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, json} when is_map(json) -> [json]
        _ -> []
      end
    end)
  end

  defp parse_turn(_events, exit_code, output) when exit_code != 0,
    do: {:error, {:provider_exit, exit_code, output_tail(output)}}

  defp parse_turn(events, exit_code, output) do
    init = Enum.find(events, &(&1["type"] == "thread.started"))
    last = List.last(events)
    # Native Codex may emit recoverable reconnect notifications as `error`
    # events before a successful terminal completion. Only a terminal failure
    # overrides a completed turn.
    failure =
      Enum.find(events, fn event ->
        event["type"] == "turn.failed" or
          (event["type"] == "error" and not reconnect_notification?(event, last))
      end)

    with :ok <- no_provider_failure(failure, output),
         {:ok, session_id} <- session_id(init, exit_code, output),
         :ok <- turn_completed(last, exit_code, output),
         :ok <- consistent_session_id(events, session_id) do
      {:ok,
       %{
         session_id: session_id,
         result: last,
         message: final_agent_message(events),
         events: events
       }}
    end
  end

  # `turn.completed` proves that the provider settled, but its payload is not
  # the Developer's notes. The final completed agent message is. Absence is
  # represented as empty notes while retaining the validated session.
  defp final_agent_message(events) do
    events
    |> Enum.filter(
      &(&1["type"] == "item.completed" && get_in(&1, ["item", "type"]) == "agent_message")
    )
    |> List.last()
    |> case do
      nil -> ""
      event -> get_in(event, ["item", "text"]) || ""
    end
  end

  defp no_provider_failure(nil, _output), do: :ok

  defp no_provider_failure(failure, output),
    do: {:error, {:provider_error, Map.put(failure, "output_tail", output_tail(output))}}

  defp reconnect_notification?(%{"message" => "Reconnecting..." <> _}, %{
         "type" => "turn.completed"
       }),
       do: true

  defp reconnect_notification?(_event, _last), do: false

  defp session_id(nil, exit_code, output),
    do: {:error, {:no_init_event, exit_code, output_tail(output)}}

  defp session_id(%{"thread_id" => session_id}, _exit_code, _output)
       when is_binary(session_id) and session_id != "",
       do: {:ok, session_id}

  defp session_id(_init, _exit_code, _output), do: {:error, :missing_session_id}

  defp turn_completed(%{"type" => "turn.completed"}, _exit_code, _output), do: :ok

  defp turn_completed(_last, exit_code, output),
    do: {:error, {:no_result_event, exit_code, output_tail(output)}}

  defp consistent_session_id(events, session_id) do
    if Enum.any?(events, &different_thread?(&1, session_id)) do
      {:error, :session_id_mismatch}
    else
      :ok
    end
  end

  defp different_thread?(%{"type" => "thread.started", "thread_id" => thread_id}, session_id),
    do: thread_id != session_id

  defp different_thread?(%{"thread_id" => thread_id}, session_id)
       when is_binary(thread_id),
       do: thread_id != session_id

  defp different_thread?(_event, _session_id), do: false

  defp temporary_directory(label, base \\ nil) do
    dir =
      Path.join(
        base || System.tmp_dir!(),
        "kogen-#{label}-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  # A Build launch runs in its Candidate (`:cwd`) under the write boundary's
  # argv `:prefix` (`sandbox-exec -p <profile>`), so the harness process and
  # everything it spawns are confined by the kernel.
  # Runs the role process through `Kogen.ProcessCustody`, in its own process
  # group: a stray grandchild the CLI forks cannot outlive this turn, and the
  # controller's death (Ctrl-C, SIGHUP, SIGTERM, `kill -9`, a crash) reaps it
  # too, through the supervisor's own parent-death watchdog.
  defp run_with_stdin_facts(context, args, stdin_text, extra_env) do
    dir = temporary_directory("stdin")
    tmp = Path.join(dir, "prompt")
    File.write!(tmp, stdin_text)

    argv = Map.get(context, :prefix, []) ++ [context.executable | args]

    custody_opts =
      [stdin_path: tmp, tmp_dir: dir, env: extra_env] ++
        custody_registration(context, extra_env) ++
        turn_time_box(context, extra_env) ++
        on_start_option(context)

    {output, exit_code, timed_out} =
      case Kogen.ProcessCustody.run(argv, context[:cwd] || File.cwd!(), custody_opts) do
        {:ok, facts} -> {facts["output"] || "", facts["exit_code"], facts["timed_out"] == true}
        {:error, reason} -> {reason, 1, false}
      end

    persist_raw_stream({output, exit_code})
    {output, exit_code, timed_out}
  end

  defp run_with_stdin(context, args, stdin_text, extra_env) do
    {output, exit_code, _timed_out} = run_with_stdin_facts(context, args, stdin_text, extra_env)
    {output, exit_code}
  end

  # The Developer turn time-box: the Build sets `:turn_timeout_ms` on the
  # Developer launch context only, so Reviewer, Expert and Shaping Controller launches
  # (and verification targets) never carry a soft timeout.
  defp turn_time_box(%{turn_timeout_ms: ms} = context, extra_env)
       when is_integer(ms) and ms > 0 do
    if role_label(extra_env) == "developer",
      do:
        [timeout_ms: ms, soft_timeout: true, grace_ms: Map.get(context, :turn_grace_ms, 45_000)] ++
          session_ready(context),
      else: []
  end

  defp turn_time_box(_context, _extra_env), do: []

  # A fresh turn (no thread id yet) is never interrupted before its thread
  # identity appears in the stream, so the nudge can always resume it; a
  # resumed turn already has one.
  defp session_ready(%{await_session: true}),
    do: [soft_ready_pattern: ~S("type"\s*:\s*"thread\.started")]

  defp session_ready(_context), do: []

  # Inside a Build the launch context carries `:control` (the control
  # checkout); the launched group is then recorded on the Build's lock, so a
  # later Build (or this one's own sweep) can find and reap it. Outside a
  # Build (Shaping's readiness probes, tests with no launch) there is no
  # control root, and no registration is possible or needed.
  defp custody_registration(%{control: control}, extra_env) when is_binary(control),
    do: [control: control, role: role_label(extra_env)]

  defp custody_registration(_context, _extra_env), do: []

  defp on_start_option(%{on_start: on_start}) when is_function(on_start, 1),
    do: [on_start: on_start]

  defp on_start_option(_context), do: []

  defp role_label(extra_env) do
    case List.keyfind(extra_env, "KOGEN_ROLE", 0) do
      {_key, role} when is_binary(role) -> role
      _ -> "process"
    end
  end

  defp persist_raw_stream({output, _exit_code}) do
    case System.get_env("KOGEN_RAW_LOG_DIR") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)

        name =
          "raw-stream-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}.jsonl"

        File.write!(Path.join(dir, name), output)
    end
  end
end
