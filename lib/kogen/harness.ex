defmodule Kogen.Harness do
  @moduledoc """
  Runs Codex for interactive shaping, Developer turns, and independent reviews.
  `KOGEN_HARNESS` can select an alternate executable for offline testing.
  Codex thread IDs are exposed as `session_id` to the build state machine.
  """
  use Boundary, deps: []

  @verdict_schema Jason.encode!(%{
                    "type" => "object",
                    "properties" => %{
                      "verdict" => %{"type" => "string", "enum" => ["accept", "rework"]},
                      "findings" => %{"type" => "array", "items" => %{"type" => "string"}}
                    },
                    "required" => ["verdict", "findings"],
                    "additionalProperties" => false
                  })

  @common_flags [
    "--enable",
    "hooks",
    "--dangerously-bypass-hook-trust",
    "--dangerously-bypass-approvals-and-sandbox"
  ]

  @doc "Launches a fresh Developer turn with the prompt on stdin."
  def launch_developer(prompt, model, effort, policy_environment \\ []) do
    run_turn(developer_args(model, effort), prompt, policy_environment)
  end

  @doc "Resumes the exact Developer thread with the prompt on stdin."
  def resume_developer(session_id, text, model, effort, policy_environment \\ []) do
    run_turn(developer_args(model, effort, session_id), text, policy_environment)
  end

  @doc false
  def developer_args(model, effort, resume_session_id \\ nil) do
    prefix = if resume_session_id, do: ["exec", "resume"], else: ["exec"]
    suffix = if resume_session_id, do: [resume_session_id, "-"], else: ["-"]
    prefix ++ exec_flags(model, effort) ++ suffix
  end

  @doc "Launches an independent Reviewer and requires a schema-valid Verdict."
  def launch_reviewer(prompt, model, effort) do
    dir = temporary_directory("review")
    schema_path = Path.join(dir, "verdict.schema.json")
    message_path = Path.join(dir, "verdict.json")
    File.write!(schema_path, @verdict_schema)

    try do
      args =
        reviewer_args(model, effort) ++
          ["--output-schema", schema_path, "--output-last-message", message_path, "-"]

      {output, exit_code} =
        run_with_stdin(resolve_executable(), args, prompt, [{"KOGEN_ROLE", "reviewer"}])

      with {:ok, turn} <- parse_turn(decode_events(output), exit_code, output),
           message = reviewer_message(message_path, turn.events),
           {:ok, verdict} <- parse_verdict(message) do
        persist_reviewer_verdict(message, turn.session_id)
        {:ok, Map.put(verdict, :session_id, turn.session_id)}
      else
        _ -> {:error, {:malformed_verdict, exit_code, String.slice(output, 0, 4000)}}
      end
    after
      File.rm_rf(dir)
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
    with {:ok, %{"verdict" => verdict, "findings" => findings} = json} <-
           Jason.decode(String.trim(output)),
         true <- Map.keys(json) |> Enum.sort() == ["findings", "verdict"],
         true <- verdict in ["accept", "rework"],
         true <- valid_findings?(verdict, findings) do
      {:ok, %{verdict: verdict, findings: findings}}
    else
      _ -> :error
    end
  end

  defp valid_findings?("rework", findings) do
    nonblank_findings?(findings) and findings != []
  end

  defp valid_findings?("accept", findings), do: nonblank_findings?(findings)

  defp nonblank_findings?(findings) when is_list(findings) do
    Enum.all?(findings, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp nonblank_findings?(_findings), do: false

  @doc "Launches the interactive Codex Shaping Controller with the caller's real terminal."
  def exec_shaper(model, effort, prompt_file) do
    port =
      Port.open({:spawn_executable, resolve_executable()}, [
        :nouse_stdio,
        :exit_status,
        args: shaper_args(model, effort, prompt_file),
        env: [{~c"KOGEN_ROLE", ~c"shaper"}]
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  @doc false
  def shaper_args(model, effort, prompt_file) do
    model_flags(model, effort) ++ @common_flags ++ ["--", File.read!(prompt_file)]
  end

  @doc false
  def resolve_executable do
    name = System.get_env("KOGEN_HARNESS") || "codex"

    if String.contains?(name, "/"),
      do: Path.expand(name),
      else: System.find_executable(name) || raise("harness executable not found on PATH: #{name}")
  end

  defp run_turn(args, stdin_text, policy_environment) do
    {output, exit_code} =
      run_with_stdin(
        resolve_executable(),
        args,
        stdin_text,
        [{"KOGEN_ROLE", "developer"} | policy_environment]
      )

    parse_turn(decode_events(output), exit_code, output)
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
    do: {:error, {:provider_exit, exit_code, String.slice(output, 0, 4000)}}

  defp parse_turn(events, exit_code, output) do
    init = Enum.find(events, &(&1["type"] == "thread.started"))
    last = List.last(events)
    failure = Enum.find(events, &(&1["type"] in ["turn.failed", "error"]))

    with :ok <- no_provider_failure(failure),
         {:ok, session_id} <- session_id(init, exit_code, output),
         :ok <- turn_completed(last, exit_code, output),
         :ok <- consistent_session_id(events, session_id) do
      {:ok, %{session_id: session_id, result: last, events: events}}
    end
  end

  defp no_provider_failure(nil), do: :ok
  defp no_provider_failure(failure), do: {:error, {:provider_error, failure}}

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
