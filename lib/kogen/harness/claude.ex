defmodule Kogen.Harness.Claude do
  @moduledoc """
  The Claude Code adapter behind `Kogen.Harness`.

  Every launch runs the managed `claude` with `--dangerously-skip-permissions`,
  the exact configured model and `--effort` (never a fallback model), only
  project settings plus Kogen's hook settings file, no MCP servers, Kogen's
  role-scoped helper agents, and Claude Code's built-in agents denied.

  Developer turns use `-p` with stream-json and carry no handoff schema: no
  `--json-schema` and no pasted schema block. Build turns return the settled
  session and its final assistant message, which may be empty, as the
  Developer's unverified notes; Kogen code never parses them. The Reviewer,
  which is never verified, uses `--json-schema`, chosen per launch.

  Executed identity comes from stream metadata: the model of each assistant
  message, and helper messages linked to their parent `Agent` tool use. A root
  response from another model fails the turn with a typed error.
  """
  alias Kogen.Harness.HookInterpreter
  alias Kogen.Harness.Verdict

  @builtin_agents ~w(general-purpose Explore Plan claude statusline-setup)
  @editing_tools ~w(Edit Write NotebookEdit)
  @read_tools ~w(Read Grep Glob)
  @synthetic_model "<synthetic>"
  @settings_path Path.expand("../../../priv/kogen/claude_code/settings.json", __DIR__)
  # Provider stop, exit and failure evidence keeps the last
  # `@output_tail_bytes` bytes of the stream, not its head, so a classifying
  # line (a rate-limit or overload marker near the end of a long capture,
  # itself up to ~10 KB for a Claude `result` event) survives whole for
  # `Kogen.Harness.ProviderMarker` to classify.
  @output_tail_bytes 16_384

  @doc "Launches a fresh Developer turn with the prompt on stdin."
  def launch_developer(prompt, model, effort, policy_environment, context) do
    with_context(context, fn resolved ->
      session_id = uuid4()
      args = developer_args(model, effort, resolved, {:fresh, session_id})
      run_turn(resolved, args, prompt, "developer", policy_environment, session_id, model)
    end)
  end

  @doc "Resumes the exact Developer session with the prompt on stdin."
  def resume_developer(session_id, text, model, effort, policy_environment, context) do
    with_context(context, fn resolved ->
      args = developer_args(model, effort, resolved, {:resume, session_id})
      run_turn(resolved, args, text, "developer", policy_environment, session_id, model)
    end)
  end

  @doc "Launches a fresh Build Developer turn; its final message is returned as notes."
  def launch_build_developer(prompt, model, effort, policy_environment, context) do
    with_context(context, fn resolved ->
      session_id = uuid4()
      args = developer_args(model, effort, resolved, {:fresh, session_id})
      notes_turn(resolved, args, prompt, policy_environment, session_id, model)
    end)
  end

  @doc "Resumes the exact Build Developer session; its final message is returned as notes."
  def resume_build_developer(session_id, text, model, effort, policy_environment, context) do
    with_context(context, fn resolved ->
      args = developer_args(model, effort, resolved, {:resume, session_id})
      notes_turn(resolved, args, text, policy_environment, session_id, model)
    end)
  end

  @doc "Launches a fresh independent Reviewer and requires a schema-valid verdict."
  def launch_reviewer(prompt, model, effort, context) do
    with_context(context, fn resolved ->
      session_id = uuid4()
      args = reviewer_args(model, effort, resolved, session_id)

      {output, exit_code} =
        run_with_stdin(resolved, args, prompt, [{"KOGEN_ROLE", "reviewer"}])

      case parse_stream(output, exit_code, session_id, model) do
        {:ok, turn} -> reviewer_response(turn, verdict_opts(resolved), output)
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Resumes the exact Reviewer session once (`--resume`) with the schema-error
  re-ask on stdin, and requires a schema-valid verdict against the same
  per-launch schema (the context's `:ledger_paths` and `:scenario_ids`).
  """
  def resume_reviewer(session_id, prompt, model, effort, context) do
    with_context(context, fn resolved ->
      args = resume_reviewer_args(model, effort, resolved, session_id)

      {output, exit_code} =
        run_with_stdin(resolved, args, prompt, [{"KOGEN_ROLE", "reviewer"}])

      case parse_stream(output, exit_code, session_id, model) do
        {:ok, turn} -> reviewer_response(turn, verdict_opts(resolved), output)
        {:error, _reason} = error -> error
      end
    end)
  end

  # A context with no per-launch scenario ids keeps the legacy validation
  # shape (a bare boolean), which never requires the per-launch evidence
  # `receipt` field or lookaround-free `path` pattern. Threading
  # `Kogen.Harness.with_scenarios/2` opts into the per-launch schema and its
  # `{:error, [errors]}` validation.
  defp verdict_opts(context) do
    ledger_paths = Map.get(context, :ledger_paths, [])
    scenario_ids = Map.get(context, :scenario_ids, [])

    if scenario_ids == [] do
      ledger_paths != []
    else
      %{ledger?: ledger_paths != [], ledger_paths: ledger_paths, scenario_ids: scenario_ids}
    end
  end

  @doc """
  Launches a fresh read-only Expert for one question on stdin. Its root must
  respond from the configured model; its final message is returned.
  """
  def launch_expert(prompt, model, effort, context),
    do: launch_reader("expert", prompt, model, effort, context)

  @doc "Launches one fresh blind auditor session with its findings schema."
  def launch_auditor(prompt, model, effort, context) do
    with_context(context, fn resolved ->
      session_id = uuid4()

      args =
        ["-p", "--output-format", "stream-json", "--verbose", "--disallowedTools"] ++
          disallowed_tools("auditor") ++
          [
            "--model",
            model,
            "--effort",
            effort,
            "--dangerously-skip-permissions",
            "--setting-sources",
            "project",
            "--strict-mcp-config",
            "--settings",
            launch_settings(),
            "--json-schema",
            Jason.encode!(Map.fetch!(resolved, :output_schema))
          ] ++ session_args({:fresh, session_id})

      role_environment = [
        {"KOGEN_ROLE", "auditor"},
        {"GIT_OPTIONAL_LOCKS", "0"},
        {"KOGEN_CODEX_CONTEXT_RECEIPT", nil},
        {"KOGEN_HARNESS_HOME", nil} | expert_removed_environment()
      ]

      {output, exit_code} = run_with_stdin(resolved, args, prompt, role_environment)

      with {:ok, turn} <- parse_stream(output, exit_code, session_id, model),
           do: {:ok, expert_response(turn)}
    end)
  end

  defp launch_reader(role, prompt, model, effort, context) do
    with_context(context, fn resolved ->
      session_id = uuid4()
      args = reader_args(role, model, effort, resolved, session_id)
      role_environment = [{"KOGEN_ROLE", role} | expert_removed_environment()]
      {output, exit_code} = run_with_stdin(resolved, args, prompt, role_environment)

      with {:ok, turn} <- parse_stream(output, exit_code, session_id, model),
           do: {:ok, expert_response(turn)}
    end)
  end

  defp expert_response(turn) do
    message = if is_binary(turn.result["result"]), do: turn.result["result"], else: ""
    %{session_id: turn.session_id, message: message, executed_models: turn.executed_models}
  end

  # A consulted Expert never inherits the launching role's
  # verification context or Expert assignment.
  @doc false
  def expert_removed_environment do
    Enum.map(
      ~w(KOGEN_VERIFICATION_CONTEXT KOGEN_VERIFICATION_RETRY_LIMIT KOGEN_VERIFICATION_TARGETS KOGEN_EXPERT),
      &{&1, nil}
    )
  end

  @doc "Launches the interactive Claude Code Shaper on the caller's terminal."
  def exec_shaper(model, effort, prompt_file, context) do
    with_context(context, fn resolved ->
      terminal(
        %{resolved | env: merge_environment(resolved.env, [{"KOGEN_ROLE", "shaper"}])},
        shaper_args(model, effort, resolved, prompt_file)
      )
    end)
  end

  @doc false
  def developer_args(model, effort, context, session) do
    ["-p", "--output-format", "stream-json", "--verbose"] ++
      common_args(model, effort, context, "developer") ++ session_args(session)
  end

  @doc false
  def reviewer_args(model, effort, context, session_id) do
    ["-p", "--output-format", "stream-json", "--verbose"] ++
      common_args(model, effort, context, "reviewer") ++
      ["--json-schema", verdict_schema(context)] ++ session_args({:fresh, session_id})
  end

  @doc false
  def resume_reviewer_args(model, effort, context, session_id) do
    ["-p", "--output-format", "stream-json", "--verbose"] ++
      common_args(model, effort, context, "reviewer") ++
      ["--json-schema", verdict_schema(context)] ++ session_args({:resume, session_id})
  end

  defp verdict_schema(context) do
    Verdict.schema(Map.get(context, :ledger_paths, []), Map.get(context, :scenario_ids, []))
  end

  @doc false
  def expert_args(model, effort, context, session_id),
    do: reader_args("expert", model, effort, context, session_id)

  defp reader_args(role, model, effort, context, session_id) do
    ["-p", "--output-format", "stream-json", "--verbose"] ++
      common_args(model, effort, context, role) ++ session_args({:fresh, session_id})
  end

  @doc false
  def shaper_args(model, effort, context, prompt_file) do
    common_args(model, effort, context, "shaper") ++ ["--", File.read!(prompt_file)]
  end

  defp session_args({:fresh, session_id}), do: ["--session-id", session_id]
  defp session_args({:resume, session_id}), do: ["--resume", session_id]

  # `--disallowedTools` is variadic, so it is always followed by another flag.
  defp common_args(model, effort, context, role) do
    ["--disallowedTools" | disallowed_tools(role)] ++
      [
        "--model",
        model,
        "--effort",
        effort,
        "--dangerously-skip-permissions",
        "--setting-sources",
        "project",
        "--strict-mcp-config",
        "--settings",
        launch_settings(),
        "--agents",
        Jason.encode!(agents(role, context.config.helpers))
      ]
  end

  @doc "Tools denied to a role: every built-in agent, and editing for the Reviewer and Expert."
  def disallowed_tools(role) when role in ["reviewer", "expert", "auditor"],
    do: builtin_agent_rules() ++ @editing_tools

  def disallowed_tools(_role), do: builtin_agent_rules()

  defp builtin_agent_rules, do: Enum.map(@builtin_agents, &"Agent(#{&1})")

  @doc "Kogen's hook settings: the unchanged tracked Stop and Bash PreToolUse hooks."
  def settings_path, do: @settings_path

  @doc """
  The per-launch `--settings` value: Kogen's hook settings with every hook
  command bound to the absolute interpreter resolved in the controller's own
  environment (see `Kogen.Harness.HookInterpreter`), passed as inline JSON.
  """
  def launch_settings do
    @settings_path
    |> File.read!()
    |> Jason.decode!()
    |> HookInterpreter.settings!()
    |> Jason.encode!()
  end

  @doc """
  The configured native helper agents, restricted to the root role's
  authority. `kogen-expert` exists only when the route assigns the Expert to
  Claude Code; it is never substituted for an Expert on another harness.
  """
  def agents(role, helpers) do
    [:scout, :worker, :expert]
    |> Enum.filter(&Map.has_key?(helpers, &1))
    |> Map.new(fn label ->
      profile = Map.fetch!(helpers, label)
      {description, prompt, tools} = helper(role, label)

      {"kogen-#{label}",
       %{
         "description" => description,
         "prompt" => prompt <> " " <> helper_obligations(),
         "tools" => tools,
         "model" => profile.model,
         "effort" => profile.effort
       }}
    end)
  end

  defp helper(_role, :scout) do
    {"Read-only discovery helper for bounded questions about this repository.",
     "You are a Kogen scout. Perform read-only discovery only.", @read_tools}
  end

  defp helper("developer", :worker) do
    {"Implementation helper for an explicitly assigned, non-overlapping set of guarded paths.",
     "You are a Kogen worker. Edit only the paths your packet explicitly assigns, " <>
       "within the Intent's guarded paths; never edit the Approved package or Verification Records. " <>
       "Finish the assigned change and actually run its assigned focused check: a command that " <>
       "never started or a syntax-only check is not completion. Report partial work as partial " <>
       "and a blocker as a blocker. After the assigned checks pass, return without unrelated " <>
       "files and without launching reviewer helpers.", @read_tools ++ ["Bash", "Edit", "Write"]}
  end

  defp helper(role, :worker) do
    {"Read-only investigation helper for a bounded independent task.",
     "You are a Kogen worker for the #{role}. Everything you do is read-only: " <>
       "never create, edit or delete files.", @read_tools ++ ["Bash"]}
  end

  defp helper(role, :expert) do
    {"Read-only expert for one named difficult uncertainty that could change architecture or correctness.",
     "You are a Kogen expert for the #{role}. Address the one named uncertainty " <>
       "in your packet, read-only: never create, edit or delete files.", @read_tools ++ ["Bash"]}
  end

  defp helper_obligations do
    "Never run or delegate a Kogen verification gate (make check, make live targets, " <>
      ".codex/hooks/check.sh or any wrapper). Preserve work you did not make. Return concise " <>
      "conclusions with source locators, observed evidence, uncertainty and failures."
  end

  # A settled turn's final assistant message (possibly empty) is the notes.
  # Provider, transport, session and executed-model failures stay failures.
  defp notes_turn(context, args, text, policy_environment, session_id, model) do
    {output, exit_code, timed_out} =
      run_with_stdin_facts(context, args, text, [
        {"KOGEN_ROLE", "developer"} | policy_environment
      ])

    evidence_base = %{harness: "claude", diagnostics: output}

    # A turn that completed inside the TERM grace is a settled turn, not a
    # timeout.
    parsed =
      case {timed_out, parse_stream(output, exit_code, session_id, model)} do
        {true, {:ok, _turn} = settled} -> settled
        {true, _incomplete} -> :timed_out
        {false, parsed} -> parsed
      end

    case parsed do
      :timed_out ->
        {:error,
         {:developer_turn_timeout,
          evidence_base
          |> Map.put(:outcome, :turn_timeout)
          |> Map.put(:session_id, observed_session(output) || session_id)
          |> Map.put(:output_tail, output_tail(output))}}

      {:ok, turn} ->
        message = if is_binary(turn.result["result"]), do: turn.result["result"], else: ""

        evidence =
          Map.merge(evidence_base, %{
            outcome: :settled,
            session_id: turn.session_id,
            executed_models: turn.executed_models,
            message: message,
            message_sha256: digest(message)
          })

        {:ok,
         %{
           session_id: turn.session_id,
           message: message,
           invocation_evidence: evidence,
           executed_models: turn.executed_models
         }}

      {:error, reason} ->
        {:error,
         {:developer_transport_failure, reason,
          evidence_base
          |> Map.put(:outcome, :provider_failure)
          |> Map.put(:session_id, observed_session(output))
          |> Map.put(:output_tail, output_tail(output))}}
    end
  end

  # As documented for structured outputs, a success result without
  # structured_output is a failure; so is a turn a hook stopped.
  defp reviewer_response(%{result: result} = turn, verdict_opts, output) do
    structured = result["structured_output"]
    stopped = result["terminal_reason"] == "hook_stopped"

    validation =
      if stopped,
        do: {:error, [%{"pointer" => "", "rule" => "terminal_reason: a hook stopped the turn"}]},
        else: Verdict.validate(structured, verdict_opts)

    case validation do
      {:ok, verdict} ->
        message = Jason.encode!(structured)

        Verdict.persist(message, turn.session_id, %{
          "executed_models" => turn.executed_models
        })

        {:ok,
         verdict
         |> Map.put(:session_id, turn.session_id)
         |> Map.put(:executed_models, turn.executed_models)}

      {:error, errors} ->
        {:error,
         {:malformed_verdict, 0,
          %{
            "reviewer_session_id" => turn.session_id,
            "message" => if(is_nil(structured), do: "", else: Jason.encode!(structured)),
            "terminal_reason" => result["terminal_reason"],
            "output_tail" => output_tail(output),
            "errors" => errors
          }}}
    end
  end

  defp run_turn(context, args, text, role, policy_environment, session_id, model) do
    {output, exit_code} =
      run_with_stdin(context, args, text, [{"KOGEN_ROLE", role} | policy_environment])

    with {:ok, turn} <- parse_stream(output, exit_code, session_id, model) do
      {:ok, Map.put(turn, :message, turn.result["result"] || "")}
    end
  end

  @doc """
  Validates one `-p` stream-json capture: exit status, the init session (which
  must equal the requested fresh or resumed id), one successful result, and
  root responses from the configured model. Returns the executed models.
  """
  def parse_stream(output, exit_code, expected_session, model) do
    events = decode_events(output)

    with :ok <- exit_status(exit_code, output),
         {:ok, session_id} <- init_session(events, exit_code, output),
         :ok <- expected_session(session_id, expected_session),
         :ok <- consistent_session(events, session_id),
         {:ok, result} <- result_event(events, exit_code, output),
         executed = executed_models(events),
         :ok <- root_model(executed, model) do
      {:ok, %{session_id: session_id, result: result, events: events, executed_models: executed}}
    end
  end

  defp exit_status(0, _output), do: :ok

  defp exit_status(exit_code, output),
    do: {:error, {:provider_exit, exit_code, output_tail(output)}}

  defp init_session(events, exit_code, output) do
    case Enum.find(events, &(&1["type"] == "system" and &1["subtype"] == "init")) do
      %{"session_id" => id} when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, {:no_init_event, exit_code, output_tail(output)}}
      _init -> {:error, :missing_session_id}
    end
  end

  defp expected_session(session_id, session_id), do: :ok

  defp expected_session(actual, expected),
    do: {:error, {:session_id_mismatch, %{expected: expected, actual: actual}}}

  defp consistent_session(events, session_id) do
    if Enum.any?(events, &(is_binary(&1["session_id"]) and &1["session_id"] != session_id)),
      do: {:error, :session_id_mismatch},
      else: :ok
  end

  defp result_event(events, exit_code, output) do
    case Enum.filter(events, &(&1["type"] == "result")) do
      [] ->
        {:error, {:no_result_event, exit_code, output_tail(output)}}

      results ->
        result = List.last(results)

        cond do
          incomplete_kind(result) ->
            {:error, {:incomplete_turn, incomplete_kind(result), output_tail(output)}}

          result["subtype"] == "success" and result["is_error"] != true ->
            {:ok, result}

          true ->
            {:error,
             {:provider_error,
              result
              |> Map.take([
                "subtype",
                "is_error",
                "result",
                "terminal_reason",
                "api_error_status"
              ])
              |> Map.put("output_tail", output_tail(output))}}
        end
    end
  end

  # A result that stopped on its output limit or turn limit is an incomplete
  # turn, never a completed one, whatever its final text says.
  defp incomplete_kind(%{"stop_reason" => "max_tokens"}), do: "truncated"
  defp incomplete_kind(%{"subtype" => "error_max_turns"}), do: "max_turns"
  defp incomplete_kind(_result), do: nil

  defp root_model(%{"root" => models}, expected) do
    case Enum.reject(models, &(&1 == expected)) do
      [] -> :ok
      [actual | _] -> {:error, {:root_model_mismatch, %{expected: expected, actual: actual}}}
    end
  end

  @doc """
  Executed models from stream metadata, never model text: root assistant
  messages, and helper messages linked by `parent_tool_use_id` to the root's
  `Agent` tool use that started them.
  """
  def executed_models(events) do
    assistants = Enum.filter(events, &(&1["type"] == "assistant"))
    {root, linked} = Enum.split_with(assistants, &is_nil(&1["parent_tool_use_id"]))

    agent_uses =
      for event <- root,
          %{"type" => "tool_use", "name" => "Agent", "id" => id} = use <-
            List.wrap(get_in(event, ["message", "content"])),
          do: {id, get_in(use, ["input", "subagent_type"])}

    helpers =
      Enum.map(agent_uses, fn {id, agent} ->
        messages = Enum.filter(linked, &(&1["parent_tool_use_id"] == id))

        %{
          "tool_use_id" => id,
          "agent" => agent || Enum.find_value(messages, & &1["subagent_type"]),
          "models" => models(messages)
        }
      end)

    %{"root" => models(root), "helpers" => helpers}
  end

  defp models(messages) do
    messages
    |> Enum.map(&get_in(&1, ["message", "model"]))
    |> Enum.filter(&(is_binary(&1) and &1 != @synthetic_model))
    |> Enum.uniq()
  end

  defp observed_session(output) do
    output
    |> decode_events()
    |> Enum.find_value(&if(&1["type"] == "system", do: &1["session_id"]))
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

  # Every launch receives the session's Claude Code launch context; there is
  # no contextless path that re-reads configuration or opens a runtime here.
  defp with_context(%{harness: "claude"} = context, function), do: function.(context)

  defp with_context(context, _function) do
    raise ArgumentError,
          "Claude Code launch requires a Claude Code launch context, got: #{inspect(Map.get(context || %{}, :harness))}"
  end

  defp merge_environment(base, overrides),
    do: Map.merge(Map.new(base), Map.new(overrides)) |> Map.to_list()

  # A Build launch runs in its Candidate (`:cwd`) under the write boundary's
  # argv `:prefix` (`sandbox-exec -p <profile>`), so the harness process and
  # everything it spawns are confined by the kernel.
  # Runs the role process through `Kogen.ProcessCustody`, in its own process
  # group: a stray grandchild the CLI forks cannot outlive this turn, and the
  # controller's death (Ctrl-C, SIGHUP, SIGTERM, `kill -9`, a crash) reaps it
  # too, through the supervisor's own parent-death watchdog.
  defp run_with_stdin_facts(context, args, stdin_text, role_environment) do
    dir = temporary_directory("stdin")
    tmp = Path.join(dir, "prompt")
    File.write!(tmp, stdin_text)

    argv = Map.get(context, :prefix, []) ++ [context.executable | context.args ++ args]

    custody_opts =
      [stdin_path: tmp, tmp_dir: dir, env: merge_environment(context.env, role_environment)] ++
        custody_registration(context, role_environment) ++
        turn_time_box(context, role_environment) ++
        on_start_option(context)

    {output, exit_code, timed_out} =
      case Kogen.ProcessCustody.run(argv, context[:cwd] || File.cwd!(), custody_opts) do
        {:ok, facts} -> {facts["output"] || "", facts["exit_code"], facts["timed_out"] == true}
        {:error, reason} -> {reason, 1, false}
      end

    persist_raw_stream({output, exit_code})
    {output, exit_code, timed_out}
  end

  defp run_with_stdin(context, args, stdin_text, role_environment) do
    {output, exit_code, _timed_out} =
      run_with_stdin_facts(context, args, stdin_text, role_environment)

    {output, exit_code}
  end

  # The Developer turn time-box: the Build sets `:turn_timeout_ms` on the
  # Developer launch context only, so Reviewer, Expert and Shaper launches
  # (and verification targets) never carry a soft timeout.
  defp turn_time_box(%{turn_timeout_ms: ms} = context, role_environment)
       when is_integer(ms) and ms > 0 do
    if role_label(role_environment) == "developer",
      do: [timeout_ms: ms, soft_timeout: true, grace_ms: Map.get(context, :turn_grace_ms, 45_000)],
      else: []
  end

  defp turn_time_box(_context, _role_environment), do: []

  # Inside a Build the launch context carries `:control` (the control
  # checkout); the launched group is then recorded on the Build's lock, so a
  # later Build (or this one's own sweep) can find and reap it. Outside a
  # Build (Shaping's readiness probes, tests with no launch) there is no
  # control root, and no registration is possible or needed.
  defp custody_registration(%{control: control}, role_environment) when is_binary(control),
    do: [control: control, role: role_label(role_environment)]

  defp custody_registration(_context, _role_environment), do: []

  defp on_start_option(%{on_start: on_start}) when is_function(on_start, 1),
    do: [on_start: on_start]

  defp on_start_option(_context), do: []

  defp role_label(role_environment) do
    case List.keyfind(role_environment, "KOGEN_ROLE", 0) do
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

  defp terminal(context, args) do
    port =
      Port.open({:spawn_executable, context.executable}, [
        :nouse_stdio,
        :exit_status,
        args: context.args ++ args,
        env:
          Enum.map(context.env, fn {key, value} ->
            {String.to_charlist(key),
             if(is_nil(value), do: false, else: String.to_charlist(value))}
          end)
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  defp temporary_directory(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-#{label}-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc false
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      Enum.join(
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ],
        "-"
      )
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
end
