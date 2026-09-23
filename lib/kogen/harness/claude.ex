defmodule Kogen.Harness.Claude do
  @moduledoc """
  The Claude Code adapter behind `Kogen.Harness`.

  Every launch runs the managed `claude` with `--dangerously-skip-permissions`,
  the exact configured model and `--effort` (never a fallback model), only
  project settings plus Kogen's hook settings file, no MCP servers, Kogen's
  role-scoped helper agents, and Claude Code's built-in agents denied.

  Developer turns use `-p` with stream-json and no `--json-schema`: a Stop-hook
  block is ignored once a model calls StructuredOutput, so the handoff is the
  final assistant message, validated by Build exactly like the Codex handoff.
  The Reviewer, which has no Stop verification, uses `--json-schema`.

  Executed identity comes from stream metadata: the model of each assistant
  message, and helper messages linked to their parent `Agent` tool use. A root
  response from another model fails the turn with a typed error.
  """
  alias Kogen.Harness.Verdict

  @builtin_agents ~w(general-purpose Explore Plan claude statusline-setup)
  @editing_tools ~w(Edit Write NotebookEdit)
  @read_tools ~w(Read Grep Glob)
  @synthetic_model "<synthetic>"
  @settings_path Path.expand("../../../priv/kogen/claude_code/settings.json", __DIR__)

  @doc "Launches a fresh Developer turn with the prompt on stdin."
  def launch_developer(prompt, model, effort, policy_environment \\ [], context \\ nil) do
    with_context(context, fn resolved ->
      session_id = uuid4()
      args = developer_args(model, effort, resolved, {:fresh, session_id})
      run_turn(resolved, args, prompt, "developer", policy_environment, session_id, model)
    end)
  end

  @doc "Resumes the exact Developer session with the prompt on stdin."
  def resume_developer(session_id, text, model, effort, policy_environment \\ [], context \\ nil) do
    with_context(context, fn resolved ->
      args = developer_args(model, effort, resolved, {:resume, session_id})
      run_turn(resolved, args, text, "developer", policy_environment, session_id, model)
    end)
  end

  @doc "Launches a fresh Developer turn whose final message is the controller handoff."
  def launch_build_developer(
        prompt,
        model,
        effort,
        schema,
        policy_environment \\ [],
        context \\ nil
      ) do
    with_context(context, fn resolved ->
      session_id = uuid4()
      args = developer_args(model, effort, resolved, {:fresh, session_id})
      structured_turn(resolved, args, prompt, schema, policy_environment, session_id, model)
    end)
  end

  @doc "Resumes the exact Developer session; the final message is the controller handoff."
  def resume_build_developer(
        session_id,
        text,
        model,
        effort,
        schema,
        policy_environment \\ [],
        context \\ nil
      ) do
    with_context(context, fn resolved ->
      args = developer_args(model, effort, resolved, {:resume, session_id})
      structured_turn(resolved, args, text, schema, policy_environment, session_id, model)
    end)
  end

  @doc "Launches a fresh independent Reviewer and requires a schema-valid verdict."
  def launch_reviewer(prompt, model, effort, context \\ nil) do
    with_context(context, fn resolved ->
      session_id = uuid4()
      args = reviewer_args(model, effort, resolved, session_id)

      {output, exit_code} =
        run_with_stdin(resolved, args, prompt, [{"KOGEN_ROLE", "reviewer"}])

      case parse_stream(output, exit_code, session_id, model) do
        {:ok, turn} -> reviewer_response(turn)
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc "Launches the interactive Claude Code Shaper on the caller's terminal."
  def exec_shaper(model, effort, prompt_file, context \\ nil) do
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
      ["--json-schema", Verdict.schema()] ++ session_args({:fresh, session_id})
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
        settings_path(),
        "--agents",
        Jason.encode!(agents(role, context.config.helpers))
      ]
  end

  @doc "Tools denied to a role: every built-in agent, and editing for the Reviewer."
  def disallowed_tools("reviewer"), do: builtin_agent_rules() ++ @editing_tools
  def disallowed_tools(_role), do: builtin_agent_rules()

  defp builtin_agent_rules, do: Enum.map(@builtin_agents, &"Agent(#{&1})")

  @doc "Kogen's hook settings: the unchanged tracked Stop and Bash PreToolUse hooks."
  def settings_path, do: @settings_path

  @doc "The configured helper agents, restricted to the root role's authority."
  def agents(role, helpers) do
    Map.new([:scout, :worker, :expert], fn label ->
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
       "within the Intent's guarded paths; never edit the Approved package or Verification Records.",
     @read_tools ++ ["Bash", "Edit", "Write"]}
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

  defp structured_turn(_context, _args, _text, schema, _policy_environment, _session_id, _model)
       when not is_binary(schema),
       do: {:error, {:invalid_output_schema, "schema must be a binary"}}

  defp structured_turn(context, args, text, schema, policy_environment, session_id, model) do
    {output, exit_code} =
      run_with_stdin(
        context,
        args,
        text <> handoff_instructions(schema),
        [{"KOGEN_ROLE", "developer"} | policy_environment]
      )

    evidence_base = %{
      harness: "claude",
      schema: schema,
      schema_sha256: digest(schema),
      diagnostics: output
    }

    case parse_stream(output, exit_code, session_id, model) do
      {:ok, turn} ->
        evidence =
          Map.merge(evidence_base, %{
            outcome: :settled,
            session_id: turn.session_id,
            executed_models: turn.executed_models
          })

        structured_response(turn, evidence)

      {:error, reason} ->
        {:error,
         {:structured_transport_failure, reason,
          evidence_base
          |> Map.put(:outcome, :provider_failure)
          |> Map.put(:session_id, observed_session(output))}}
    end
  end

  # Claude Code sees the controller schema only through the prompt. Build
  # validates the final message against the same bytes it recorded here.
  defp handoff_instructions(schema) do
    "\n\nController handoff schema (Build validates your final message against it; " <>
      "reply with only this JSON object, no markdown fence or prose):\n" <> schema <> "\n"
  end

  defp structured_response(turn, evidence) do
    case turn.result["result"] do
      message when is_binary(message) ->
        evidence =
          evidence |> Map.put(:message, message) |> Map.put(:message_sha256, digest(message))

        case structured_message_status(message) do
          :ok ->
            {:ok,
             %{
               session_id: turn.session_id,
               message: message,
               invocation_evidence: evidence,
               executed_models: turn.executed_models
             }}

          status ->
            {:error, {status, evidence}}
        end

      _missing ->
        {:error, {:structured_output_missing, Map.put(evidence, :message, nil)}}
    end
  end

  defp structured_message_status(""), do: :structured_output_empty

  defp structured_message_status(message) do
    case Jason.decode(message) do
      {:ok, _json} ->
        :ok

      {:error, _reason} ->
        trimmed = String.trim(message)

        if (String.starts_with?(trimmed, "{") and not String.ends_with?(trimmed, "}")) or
             (String.starts_with?(trimmed, "[") and not String.ends_with?(trimmed, "]")),
           do: :structured_output_truncated,
           else: :structured_output_malformed
    end
  end

  # As documented for structured outputs, a success result without
  # structured_output is a failure; so is a turn a hook stopped.
  defp reviewer_response(%{result: result} = turn) do
    structured = result["structured_output"]
    stopped = result["terminal_reason"] == "hook_stopped"

    case if(stopped, do: :error, else: Verdict.validate(structured)) do
      {:ok, verdict} ->
        message = Jason.encode!(structured)

        Verdict.persist(message, turn.session_id, %{
          "executed_models" => turn.executed_models
        })

        {:ok,
         verdict
         |> Map.put(:session_id, turn.session_id)
         |> Map.put(:executed_models, turn.executed_models)}

      :error ->
        {:error,
         {:malformed_verdict, 0,
          %{
            "reviewer_session_id" => turn.session_id,
            "message" => if(is_nil(structured), do: "", else: Jason.encode!(structured)),
            "terminal_reason" => result["terminal_reason"]
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
    do: {:error, {:provider_exit, exit_code, String.slice(output, 0, 4000)}}

  defp init_session(events, exit_code, output) do
    case Enum.find(events, &(&1["type"] == "system" and &1["subtype"] == "init")) do
      %{"session_id" => id} when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, {:no_init_event, exit_code, String.slice(output, 0, 4000)}}
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
        {:error, {:no_result_event, exit_code, String.slice(output, 0, 4000)}}

      results ->
        result = List.last(results)

        if result["subtype"] == "success" and result["is_error"] != true,
          do: {:ok, result},
          else:
            {:error,
             {:provider_error,
              Map.take(result, [
                "subtype",
                "is_error",
                "result",
                "terminal_reason",
                "api_error_status"
              ])}}
    end
  end

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

  defp with_context(context, function) when is_map(context), do: function.(context)

  defp with_context(nil, function) do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, selection} <- Kogen.ClaudeCode.open(config) do
      function.(Kogen.ClaudeCode.launch_context(selection))
    else
      {:error, reason} -> raise reason
    end
  end

  defp merge_environment(base, overrides),
    do: Map.merge(Map.new(base), Map.new(overrides)) |> Map.to_list()

  defp run_with_stdin(context, args, stdin_text, role_environment) do
    dir = temporary_directory("stdin")
    tmp = Path.join(dir, "prompt")
    File.write!(tmp, stdin_text)

    try do
      cmd =
        Enum.map_join([context.executable | context.args ++ args], " ", &shell_quote/1) <>
          " < " <> shell_quote(tmp)

      result =
        System.cmd("sh", ["-c", cmd],
          stderr_to_stdout: false,
          env: merge_environment(context.env, role_environment)
        )

      persist_raw_stream(result)
      result
    after
      File.rm_rf(dir)
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
  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
