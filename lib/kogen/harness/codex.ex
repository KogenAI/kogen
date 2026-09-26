defmodule Kogen.Harness.Codex do
  @moduledoc """
  The Codex adapter behind `Kogen.Harness`: interactive shaping, Developer
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
      &notes_turn(developer_args(model, effort), prompt, policy_environment, &1)
    )
  end

  @doc "Resumes the exact Build Developer thread; its final agent message is returned as notes."
  def resume_build_developer(session_id, text, model, effort, policy_environment, context) do
    with_context(
      context,
      &notes_turn(developer_args(model, effort, session_id), text, policy_environment, &1)
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
    with_context(context, &review(prompt, model, effort, &1))
  end

  defp review(prompt, model, effort, context) do
    # Codex writes the last message itself, so inside a Build it lives in the
    # Build temp dir the boundary grants.
    dir = temporary_directory("review", Map.get(context, :tmp_dir))
    schema_path = Path.join(dir, "verdict.schema.json")
    message_path = Path.join(dir, "verdict.json")
    ledger_paths = Map.get(context, :ledger_paths, [])
    File.write!(schema_path, Verdict.schema(ledger_paths))

    try do
      args =
        reviewer_args(model, effort) ++
          ["--output-schema", schema_path, "--output-last-message", message_path, "-"]

      {output, exit_code} =
        run_with_stdin(
          context,
          context.args ++ args,
          prompt,
          merge_environment(context.env, [{"KOGEN_ROLE", "reviewer"}])
        )

      case parse_turn(decode_events(output), exit_code, output) do
        {:ok, turn} -> reviewer_response(turn, message_path, ledger_paths != [])
        {:error, _reason} = error -> error
      end
    after
      File.rm_rf(dir)
    end
  end

  defp reviewer_response(turn, message_path, ledger?) do
    message = reviewer_message(message_path, turn.events)

    case Verdict.parse(message, ledger?) do
      {:ok, verdict} ->
        Verdict.persist(message, turn.session_id)
        {:ok, Map.put(verdict, :session_id, turn.session_id)}

      _ ->
        {:error,
         {:malformed_verdict, 0,
          %{"reviewer_session_id" => turn.session_id, "message" => message}}}
    end
  end

  @doc false
  def reviewer_args(model, effort), do: ["exec"] ++ exec_flags(model, effort)

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

  @doc "Launches the interactive Codex Shaping Controller with the caller's real terminal."
  def exec_shaper(model, effort, prompt_file, context) do
    with_context(context, fn selected ->
      selected = %{selected | env: merge_environment(selected.env, [{"KOGEN_ROLE", "shaper"}])}
      Kogen.Codex.terminal(selected, shaper_args(model, effort, prompt_file))
    end)
  end

  @doc false
  def shaper_args(model, effort, prompt_file) do
    model_flags(model, effort) ++ @common_flags ++ ["--", File.read!(prompt_file)]
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
  defp notes_turn(args, stdin_text, policy_environment, context) do
    {output, exit_code} =
      run_with_stdin(
        context,
        context.args ++ args,
        stdin_text,
        merge_environment(context.env, [{"KOGEN_ROLE", "developer"} | policy_environment])
      )

    case parse_turn(decode_events(output), exit_code, output) do
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
          %{harness: "codex", outcome: :provider_failure, diagnostics: output}}}
    end
  end

  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

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
    do: {:error, {:provider_exit, exit_code, String.slice(output, 0, 4000)}}

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

    with :ok <- no_provider_failure(failure),
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

  defp no_provider_failure(nil), do: :ok
  defp no_provider_failure(failure), do: {:error, {:provider_error, failure}}

  defp reconnect_notification?(%{"message" => "Reconnecting..." <> _}, %{
         "type" => "turn.completed"
       }),
       do: true

  defp reconnect_notification?(_event, _last), do: false

  defp session_id(nil, exit_code, output),
    do: {:error, {:no_init_event, exit_code, String.slice(output, 0, 4000)}}

  defp session_id(%{"thread_id" => session_id}, _exit_code, _output)
       when is_binary(session_id) and session_id != "",
       do: {:ok, session_id}

  defp session_id(_init, _exit_code, _output), do: {:error, :missing_session_id}

  defp turn_completed(%{"type" => "turn.completed"}, _exit_code, _output), do: :ok

  defp turn_completed(_last, exit_code, output),
    do: {:error, {:no_result_event, exit_code, String.slice(output, 0, 4000)}}

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
  defp run_with_stdin(context, args, stdin_text, extra_env) do
    dir = temporary_directory("stdin")
    tmp = Path.join(dir, "prompt")
    File.write!(tmp, stdin_text)

    try do
      argv = Map.get(context, :prefix, []) ++ [context.executable | args]
      cmd = Enum.map_join(argv, " ", &shell_quote/1) <> " < " <> shell_quote(tmp)
      options = [stderr_to_stdout: false, env: extra_env] ++ cwd_option(context)
      result = System.cmd("sh", ["-c", cmd], options)
      persist_raw_stream(result)
      result
    after
      File.rm_rf(dir)
    end
  end

  defp cwd_option(%{cwd: cwd}) when is_binary(cwd), do: [cd: cwd]
  defp cwd_option(_context), do: []

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

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
