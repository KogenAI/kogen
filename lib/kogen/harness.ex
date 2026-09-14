defmodule Kogen.Harness do
  @moduledoc """
  Runs Codex for interactive shaping, Developer turns, and independent reviews.
  `KOGEN_HARNESS` can select an alternate executable for offline testing.
  Codex thread IDs are exposed as `session_id` to the build state machine.
  """
  use Boundary, deps: [Kogen.Codex, Kogen.Intent]

  @evidence_schema %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "Existing regular repository-relative file. For a missing-file defect cite an existing requirement/test/evidence file; describe the absent file in reason and locator, never here."
        },
        "locator" => %{"type" => "string", "minLength" => 1}
      },
      "required" => ["path", "locator"],
      "additionalProperties" => false
    }
  }

  @verdict_schema Jason.encode!(%{
                    "type" => "object",
                    "properties" => %{
                      "candidate_id" => %{"type" => "string", "minLength" => 1},
                      "attempt_token" => %{"type" => "string", "minLength" => 1},
                      "verdict" => %{"type" => "string", "enum" => ["accept", "rework"]},
                      "scenarios" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "id" => %{"type" => "string", "minLength" => 1},
                            "status" => %{
                              "type" => "string",
                              "enum" => ["satisfied", "needs_rework"]
                            },
                            "reason" => %{"type" => "string", "minLength" => 1},
                            "evidence" => @evidence_schema
                          },
                          "required" => ["id", "status", "reason", "evidence"],
                          "additionalProperties" => false
                        }
                      },
                      "dispositions" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "id" => %{"type" => "string", "minLength" => 1},
                            "status" => %{"type" => "string", "enum" => ["closed", "open"]},
                            "reason" => %{"type" => "string", "minLength" => 1},
                            "evidence" => @evidence_schema
                          },
                          "required" => ["id", "status", "reason", "evidence"],
                          "additionalProperties" => false
                        }
                      },
                      "findings" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "scenario_ids" => %{
                              "type" => "array",
                              "minItems" => 1,
                              "items" => %{"type" => "string", "minLength" => 1}
                            },
                            "reason" => %{"type" => "string", "minLength" => 1},
                            "evidence" => @evidence_schema
                          },
                          "required" => ["scenario_ids", "reason", "evidence"],
                          "additionalProperties" => false
                        }
                      }
                    },
                    "required" => [
                      "candidate_id",
                      "attempt_token",
                      "verdict",
                      "scenarios",
                      "dispositions",
                      "findings"
                    ],
                    "additionalProperties" => false
                  })

  @common_flags [
    "--enable",
    "hooks",
    "--dangerously-bypass-hook-trust",
    "--dangerously-bypass-approvals-and-sandbox"
  ]

  @doc "Launches a fresh Developer turn with the prompt on stdin."
  def launch_developer(prompt, model, effort, policy_environment \\ [], context \\ nil) do
    with_context(
      context,
      &run_turn(developer_args(model, effort), prompt, policy_environment, &1)
    )
  end

  @doc "Resumes the exact Developer thread with the prompt on stdin."
  def resume_developer(session_id, text, model, effort, policy_environment \\ [], context \\ nil) do
    with_context(
      context,
      &run_turn(developer_args(model, effort, session_id), text, policy_environment, &1)
    )
  end

  @doc "Launches a fresh Developer turn using the controller-supplied output schema."
  def launch_build_developer(
        prompt,
        model,
        effort,
        schema,
        policy_environment \\ [],
        context \\ nil
      ) do
    with_context(context, fn resolved ->
      run_structured_turn(
        developer_args(model, effort),
        prompt,
        schema,
        policy_environment,
        resolved
      )
    end)
  end

  @doc "Resumes the exact Developer thread using the controller-supplied output schema."
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
      run_structured_turn(
        developer_args(model, effort, session_id),
        text,
        schema,
        policy_environment,
        resolved
      )
    end)
  end

  @doc false
  def developer_args(model, effort, resume_session_id \\ nil) do
    prefix = if resume_session_id, do: ["exec", "resume"], else: ["exec"]
    suffix = if resume_session_id, do: [resume_session_id, "-"], else: ["-"]
    prefix ++ exec_flags(model, effort) ++ suffix
  end

  @doc "Launches an independent Reviewer and requires a schema-valid Verdict."
  def launch_reviewer(prompt, model, effort, context \\ nil) do
    with_context(context, &review(prompt, model, effort, &1))
  end

  defp review(prompt, model, effort, context) do
    dir = temporary_directory("review")
    schema_path = Path.join(dir, "verdict.schema.json")
    message_path = Path.join(dir, "verdict.json")
    File.write!(schema_path, @verdict_schema)

    try do
      args =
        reviewer_args(model, effort) ++
          ["--output-schema", schema_path, "--output-last-message", message_path, "-"]

      {output, exit_code} =
        run_with_stdin(
          context.executable,
          context.args ++ args,
          prompt,
          merge_environment(context.env, [{"KOGEN_ROLE", "reviewer"}])
        )

      case parse_turn(decode_events(output), exit_code, output) do
        {:ok, turn} -> reviewer_response(turn, message_path)
        {:error, _reason} = error -> error
      end
    after
      File.rm_rf(dir)
    end
  end

  defp reviewer_response(turn, message_path) do
    message = reviewer_message(message_path, turn.events)

    case parse_verdict(message) do
      {:ok, verdict} ->
        persist_reviewer_verdict(message, turn.session_id)
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

  defp parse_verdict(output) do
    with {:ok, json} <- Jason.decode(String.trim(output)),
         true <- valid_verdict?(json) do
      {:ok,
       %{
         verdict: json["verdict"],
         findings: json["findings"],
         response: json
       }}
    else
      _ -> :error
    end
  end

  defp valid_verdict?(json) when is_map(json) do
    Map.keys(json) |> Enum.sort() == verdict_keys() and
      nonblank?(json["candidate_id"]) and
      nonblank?(json["attempt_token"]) and
      json["verdict"] in ["accept", "rework"] and
      valid_scenarios?(json["scenarios"]) and
      valid_dispositions?(json["dispositions"]) and
      valid_findings?(json["findings"])
  end

  defp valid_verdict?(_json), do: false

  defp valid_scenarios?(scenarios) when is_list(scenarios) do
    Enum.all?(scenarios, fn
      %{"id" => id, "status" => status, "reason" => reason, "evidence" => evidence} = scenario ->
        Map.keys(scenario) |> Enum.sort() == ["evidence", "id", "reason", "status"] and
          nonblank?(id) and status in ["satisfied", "needs_rework"] and nonblank?(reason) and
          valid_evidence?(evidence)

      _ ->
        false
    end)
  end

  defp valid_scenarios?(_scenarios), do: false

  defp valid_dispositions?(dispositions) when is_list(dispositions) do
    Enum.all?(dispositions, fn
      %{"id" => id, "status" => status, "reason" => reason, "evidence" => evidence} = disposition ->
        Map.keys(disposition) |> Enum.sort() == ["evidence", "id", "reason", "status"] and
          nonblank?(id) and status in ["closed", "open"] and nonblank?(reason) and
          valid_evidence?(evidence)

      _ ->
        false
    end)
  end

  defp valid_dispositions?(_dispositions), do: false

  defp valid_findings?(findings) when is_list(findings) do
    Enum.all?(findings, fn
      %{"scenario_ids" => scenario_ids, "reason" => reason, "evidence" => evidence} = finding ->
        Map.keys(finding) |> Enum.sort() == ["evidence", "reason", "scenario_ids"] and
          is_list(scenario_ids) and scenario_ids != [] and Enum.all?(scenario_ids, &nonblank?/1) and
          nonblank?(reason) and valid_evidence?(evidence)

      _ ->
        false
    end)
  end

  defp valid_findings?(_findings), do: false

  defp valid_evidence?(evidence) when is_list(evidence) do
    Enum.all?(evidence, fn
      %{"path" => path, "locator" => locator} = reference ->
        Map.keys(reference) |> Enum.sort() == ["locator", "path"] and nonblank?(path) and
          nonblank?(locator)

      _ ->
        false
    end)
  end

  defp valid_evidence?(_evidence), do: false

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp verdict_keys do
    ["attempt_token", "candidate_id", "dispositions", "findings", "scenarios", "verdict"]
  end

  @doc "Launches the interactive Codex Shaping Controller with the caller's real terminal."
  def exec_shaper(model, effort, prompt_file, context \\ nil) do
    with_context(context, fn selected ->
      selected = %{selected | env: merge_environment(selected.env, [{"KOGEN_ROLE", "shaper"}])}
      Kogen.Codex.terminal(selected, shaper_args(model, effort, prompt_file))
    end)
  end

  @doc false
  def shaper_args(model, effort, prompt_file) do
    model_flags(model, effort) ++ @common_flags ++ ["--", File.read!(prompt_file)]
  end

  @doc false
  def resolve_executable do
    with_context(nil, & &1.executable)
  end

  defp with_context(context, function) when is_map(context), do: function.(context)

  defp with_context(nil, function) do
    {:ok, config} =
      if System.get_env("KOGEN_HARNESS"), do: {:ok, %{}}, else: Kogen.Intent.read_config()

    case Kogen.Codex.open(config) do
      {:ok, selection} ->
        try do
          function.(Kogen.Codex.launch_context(selection))
        after
          Kogen.Codex.close(selection)
        end

      {:error, reason} ->
        raise reason
    end
  end

  defp merge_environment(base, overrides),
    do: Map.merge(Map.new(base), Map.new(overrides)) |> Map.to_list()

  defp run_turn(args, stdin_text, policy_environment, context) do
    {output, exit_code} =
      run_with_stdin(
        context.executable,
        context.args ++ args,
        stdin_text,
        merge_environment(context.env, [{"KOGEN_ROLE", "developer"} | policy_environment])
      )

    parse_turn(decode_events(output), exit_code, output)
  end

  # Build's structured handoff is deliberately a separate transport. Never adopt
  # an agent_message event when the designated output file is absent or corrupt.
  defp run_structured_turn(_args, _stdin_text, schema, _policy_environment, _context)
       when not is_binary(schema),
       do: {:error, {:invalid_output_schema, "schema must be a binary"}}

  defp run_structured_turn(args, stdin_text, schema, policy_environment, context) do
    dir = temporary_directory("build-developer")
    schema_path = Path.join(dir, "developer-output.schema.json")
    message_path = Path.join(dir, "developer-output.last-message.json")
    File.write!(schema_path, schema, [:binary])

    try do
      output_flags = ["--output-schema", schema_path, "--output-last-message", message_path]

      structured_args =
        case Enum.take(args, -2) do
          [session_id, "-"] when session_id != "--json" ->
            Enum.drop(args, -2) ++ output_flags ++ [session_id, "-"]

          _ ->
            Enum.drop(args, -1) ++ output_flags ++ ["-"]
        end

      {output, exit_code} =
        run_with_stdin(
          context.executable,
          context.args ++ structured_args,
          stdin_text,
          merge_environment(context.env, [{"KOGEN_ROLE", "developer"} | policy_environment])
        )

      case parse_turn(decode_events(output), exit_code, output) do
        {:ok, turn} ->
          structured_response(turn, schema, message_path, output)

        {:error, reason} ->
          {:error,
           {:structured_transport_failure, reason,
            %{
              schema: schema,
              schema_sha256: digest(schema),
              outcome: :provider_failure,
              diagnostics: output
            }}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp structured_response(turn, schema, message_path, diagnostics) do
    evidence_base = %{
      schema: schema,
      schema_sha256: digest(schema),
      outcome: :settled,
      diagnostics: diagnostics,
      session_id: turn.session_id
    }

    case File.read(message_path) do
      {:ok, message} when byte_size(message) == 0 ->
        evidence =
          evidence_base
          |> Map.put(:message, message)
          |> Map.put(:message_sha256, digest(message))

        {:error, {:structured_output_empty, evidence}}

      {:ok, message} ->
        evidence =
          evidence_base
          |> Map.put(:message, message)
          |> Map.put(:message_sha256, digest(message))

        case structured_message_status(message) do
          :ok ->
            {:ok, %{session_id: turn.session_id, message: message, invocation_evidence: evidence}}

          status ->
            {:error, {status, evidence}}
        end

      {:error, _reason} ->
        {:error, {:structured_output_missing, Map.put(evidence_base, :message, nil)}}
    end
  end

  defp structured_message_status(message) do
    case Jason.decode(message) do
      {:ok, _json} ->
        :ok

      {:error, _reason} ->
        if truncated_json?(message),
          do: :structured_output_truncated,
          else: :structured_output_malformed
    end
  end

  defp truncated_json?(message) do
    trimmed = String.trim(message)

    (String.starts_with?(trimmed, "{") and not String.ends_with?(trimmed, "}")) or
      (String.starts_with?(trimmed, "[") and not String.ends_with?(trimmed, "]"))
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
  # the Developer's handoff. The final completed agent message is. Absence is
  # represented as an empty handoff while retaining the validated session so
  # Build can request correction in the exact same Developer conversation.
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

  defp run_with_stdin(exe, args, stdin_text, extra_env) do
    dir = temporary_directory("stdin")
    tmp = Path.join(dir, "prompt")
    File.write!(tmp, stdin_text)

    try do
      cmd = Enum.map_join([exe | args], " ", &shell_quote/1) <> " < " <> shell_quote(tmp)
      result = System.cmd("sh", ["-c", cmd], stderr_to_stdout: false, env: extra_env)
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

  defp persist_reviewer_verdict(message, session_id) do
    case System.get_env("KOGEN_RAW_LOG_DIR") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)

        name =
          "reviewer-verdict-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}.json"

        File.write!(Path.join(dir, name), message)

        receipt =
          message
          |> Jason.decode!()
          |> Map.put("session_id", session_id)
          |> Jason.encode!()

        File.write!(Path.join(dir, "reviewer-verdicts.jsonl"), receipt <> "\n", [:append])
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
