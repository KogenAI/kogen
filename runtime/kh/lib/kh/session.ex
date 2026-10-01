defmodule Kh.Session do
  @moduledoc """
  Programmatic custom-runtime session boundary.

  Sessions are opened with an explicit provider, model, working directory,
  system prompt and private checkpoint path. ChatGPT credentials are passed
  in memory by the caller. Scripted sessions use only an in-memory queue owned
  by this process and cannot fall through to a network provider. A scripted
  reply may explicitly echo a successful Bash result as its final text.
  """
  use GenServer

  @credential_margin_s 60
  @script_expectations ~w(model effort_sent session_id tool_names message_count last_user_text last_message_role last_tool_name last_tool_is_error)a

  @doc "Open a fresh session or restore a durable session from a checkpoint."
  def open(config) do
    with {:ok, normalized} <- normalize(config),
         :ok <- validate_restore_binding(normalized) do
      GenServer.start_link(__MODULE__, normalized)
    end
  end

  @doc "Start the initial text prompt in an open session."
  def run(session, prompt), do: GenServer.call(session, {:run, prompt}, :infinity)

  @doc "Wait for a run result containing its summary, JSON events and evidence."
  def await(session, run_ref, timeout \\ :infinity), do: GenServer.call(session, {:await, run_ref}, timeout)

  @doc "Resume the exact durable checkpoint without appending input."
  def resume(session), do: GenServer.call(session, :resume, :infinity)

  @doc "Append a new Shaper answer or Developer rework prompt after successful completion."
  def append_input(session, input), do: GenServer.call(session, {:append_input, input}, :infinity)

  @doc "Cancel only this session's active tool processes and worker."
  def cancel(session), do: GenServer.call(session, :cancel, :infinity)

  @doc "Return the latest structured session and usage evidence."
  def evidence(session), do: GenServer.call(session, :evidence)

  @doc "Return the number of requests recorded by the strict local scripted provider."
  def scripted_requests(session), do: GenServer.call(session, :scripted_requests)

  @doc false
  def scripted_request(server, run_ref, request),
    do: GenServer.call(server, {:scripted_request, run_ref, request}, :infinity)

  @doc false
  def persist_checkpoint!(server, run_ref, checkpoint) do
    case GenServer.call(server, {:persist_checkpoint, run_ref, checkpoint}, :infinity) do
      :ok -> :ok
      {:error, message} -> raise Kh.Checkpoint.Error, message: message
    end
  end

  @impl true
  def init(config) do
    Kh.Procs.init()

    case restore_checkpoint(config) do
      {:ok, checkpoint, session_id} ->
        {:ok, initial_state(config, checkpoint, session_id, "paused")}

      {:error, reason} ->
        {:stop, reason}

      :fresh ->
        if File.exists?(config.checkpoint_path) do
          {:stop, "checkpoint already exists; pass restore_from to continue it"}
        else
          File.mkdir_p!(Path.dirname(config.checkpoint_path))
          {:ok, initial_state(config, nil, config.session_id || new_id(), "open")}
        end
    end
  end

  @impl true
  def handle_call({:run, prompt}, _from, %{status: "open", checkpoint: nil} = state)
      when is_binary(prompt) do
    launch_run(state, prompt, nil)
  end

  def handle_call({:run, _prompt}, _from, state),
    do: {:reply, {:error, "run is available only for a fresh session; use resume or append_input"}, state}

  def handle_call(:resume, _from, %{checkpoint: checkpoint, status: status} = state)
      when is_map(checkpoint) and status != "running" do
    launch_run(state, nil, nil)
  end

  def handle_call(:resume, _from, state),
    do: {:reply, {:error, "session has no resumable checkpoint"}, state}

  def handle_call({:append_input, input}, _from, %{checkpoint: checkpoint, status: status} = state)
      when is_map(checkpoint) and status != "running" and is_binary(input) and input != "" do
    if checkpoint[:phase] == "complete" and checkpoint[:terminal_status] == "ok" do
      launch_run(state, nil, input)
    else
      {:reply, {:error, "new input requires a successfully completed checkpoint"}, state}
    end
  end

  def handle_call({:append_input, _input}, _from, state),
    do: {:reply, {:error, "session cannot append input in its current state"}, state}

  def handle_call({:await, run_ref}, from, state) do
    cond do
      run_ref != state.run_ref ->
        {:reply, {:error, :unknown_run}, state}

      state.status == "running" ->
        {:noreply, %{state | waiters: [from | state.waiters]}}

      true ->
        {:reply, {:ok, run_result(state)}, state}
    end
  end

  def handle_call(:cancel, _from, %{status: "running", worker: worker} = state) do
    Kh.Procs.kill_session(state.session_id)
    if is_pid(worker), do: Process.exit(worker, :kill)
    state = persist_cancel_elapsed(state)
    summary = cancelled_summary(state.checkpoint)
    state = %{state | status: "cancelled", worker: nil, monitor: nil, last_summary: summary}
    reply_waiters(state, {:ok, run_result(state)})
    {:reply, {:ok, session_evidence(state)}, %{state | waiters: []}}
  end

  def handle_call(:cancel, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:evidence, _from, state), do: {:reply, session_evidence(state), state}

  def handle_call(:scripted_requests, _from, state) do
    {:reply, Enum.reverse(state.script_requests), state}
  end

  def handle_call({:persist_checkpoint, run_ref, checkpoint}, _from, %{run_ref: run_ref} = state) do
    checkpoint = enrich_checkpoint(state, checkpoint)

    case Kh.Checkpoint.save(state.config.checkpoint_path, checkpoint) do
      :ok ->
        {:reply, :ok,
         %{state | checkpoint: checkpoint, checkpoint_error: nil, last_checkpoint_at: Kh.Util.now_ms(), scripted_uncommitted: false}}

      {:error, reason} ->
        message = "cannot persist checkpoint: #{inspect(reason)}"
        {:reply, {:error, message}, %{state | checkpoint_error: message}}
    end
  end

  def handle_call({:persist_checkpoint, _run_ref, _checkpoint}, _from, state),
    do: {:reply, {:error, "stale session run cannot write its checkpoint"}, state}

  def handle_call({:scripted_request, run_ref, request}, _from, %{provider: :scripted, run_ref: run_ref} = state) do
    request_record = %{"run_id" => run_ref, "model" => request["model"], "tool_names" => request["tool_names"]}
    state = %{state | script_requests: [request_record | state.script_requests]}

    case state.script do
      [%{"expect" => expect, "reply" => reply} | rest] ->
        if expectation_matches?(expect, request) do
          {result, state} = scripted_reply(reply, state, request)
          {:reply, result, %{state | script: rest, scripted_uncommitted: true}}
        else
          {:reply, {:error, {:fatal, "unexpected scripted provider request: expectation mismatch"}}, state}
        end

      [] ->
        {:reply, {:error, {:fatal, "unexpected scripted provider request: script exhausted"}}, state}
    end
  end

  def handle_call({:scripted_request, _run_ref, _request}, _from, state),
    do: {:reply, {:error, {:fatal, "scripted provider request has no active owning session"}}, state}

  @impl true
  def handle_info({:kh_runtime_event, run_ref, type, data}, %{run_ref: run_ref} = state) do
    data = json_safe(data)
    data = if type == "run_end", do: normalize_run_end(data, state), else: data

    event = %{
      "t" => max(Kh.Util.now_ms() - state.opened_at, 0),
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => type,
      "session_id" => state.session_id,
      "run_id" => run_ref,
      "data" => data
    }

    if is_function(state.config.event_sink, 1) do
      try do
        state.config.event_sink.(event)
      rescue
        _ -> :ok
      end
    end

    {:noreply, %{state | events: [event | state.events]}}
  end

  def handle_info({:kh_runtime_event, _run_ref, _type, _data}, state), do: {:noreply, state}

  def handle_info({:kh_runtime_done, run_ref, summary}, %{run_ref: run_ref, status: "running"} = state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    status = if summary.status == "ok", do: "complete", else: summary.status
    state = %{state | status: status, worker: nil, monitor: nil, last_summary: summary, last_checkpoint_at: nil}
    reply_waiters(state, {:ok, run_result(state)})
    {:noreply, %{state | waiters: []}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor, status: "running"} = state) do
    Kh.Procs.kill_session(state.session_id)
    state = persist_cancel_elapsed(state)
    error = "runtime worker stopped: #{inspect(reason)}"
    summary = %{
      status: "error",
      error: error,
      error_kind: :runtime_worker,
      turns: state.checkpoint && state.checkpoint[:turn] || 0,
      usage: nil,
      usage_total: nil,
      usage_failed_attempts: nil,
      turns_without_usage: nil
    }
    state = %{state | status: "interrupted", worker: nil, monitor: nil, last_summary: summary}
    reply_waiters(state, {:ok, run_result(state)})
    {:noreply, %{state | waiters: []}}
  end

  def handle_info({:kh_runtime_done, _run_ref, _summary}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{session_id: session_id} = state) do
    Kh.Procs.kill_session(session_id)
    if is_pid(state.worker), do: Process.exit(state.worker, :kill)
    Process.delete({__MODULE__, :access_token})
    Process.delete({__MODULE__, :account_id})
    :ok
  end

  defp initial_state(config, checkpoint, session_id, status) do
    Process.put({__MODULE__, :access_token}, config[:access_token])
    Process.put({__MODULE__, :account_id}, config[:account_id])
    config = config |> Map.delete(:access_token) |> Map.delete(:account_id)
    script = config.script || []

    %{
      config: config,
      provider: config.provider,
      provider_module: if(config.provider == :scripted, do: Kh.Provider.Scripted, else: Kh.Provider.Responses),
      session_id: session_id,
      checkpoint: checkpoint,
      checkpoint_error: nil,
      status: status,
      worker: nil,
      monitor: nil,
      waiters: [],
      run_ref: nil,
      last_summary: nil,
      last_checkpoint_at: nil,
      events: [],
      script: script,
      script_requests: [],
      scripted_uncommitted: false,
      opened_at: Kh.Util.now_ms()
    }
  end

  defp start_run(state, prompt, append_input) do
    run_ref = new_id()
    parent = self()
    base_elapsed = if state.checkpoint, do: state.checkpoint[:elapsed_ms] || 0, else: 0

    opts = %{
      model: state.config.model_descriptor,
      effort: state.config.effort,
      prompt: prompt || Map.get(state.config, :initial_prompt, ""),
      system_prompt: state.config.system_prompt,
      cwd: state.config.cwd,
      timeout_s: state.config.timeout_s,
      max_turns: state.config.max_turns,
      features: state.config.features,
      tools: state.config.tools,
      provider: state.provider_module,
      provider_name: provider_name(state.provider),
      base_url: if(state.provider == :chatgpt, do: state.config.base_url, else: nil),
      api_key: if(state.provider == :chatgpt, do: Process.get({__MODULE__, :access_token}), else: nil),
      account_id: if(state.provider == :chatgpt, do: Process.get({__MODULE__, :account_id}), else: nil),
      account_id_hash: state.config.account_id_hash,
      session_id: state.session_id,
      session_server: parent,
      run_ref: run_ref,
      emit: fn type, data -> send(parent, {:kh_runtime_event, run_ref, type, data}) end,
      on_checkpoint: fn checkpoint -> persist_checkpoint!(parent, run_ref, checkpoint) end,
      checkpoint_guard: true,
      checkpoint: state.checkpoint,
      resume: state.checkpoint,
      append_input: append_input,
      compact_at: state.config.compact_at,
      max_output: state.config.max_output,
      max_total_tokens: state.config.max_total_tokens,
      tmp_dir: state.config.tmp_dir,
      bash_pgroup: state.config.bash_pgroup,
    }

    {worker, monitor} =
      spawn_monitor(fn ->
        summary =
          if state.checkpoint do
            Kh.Agent.run_continue(opts, state.checkpoint, append_input)
          else
            Kh.Agent.run(opts)
          end

        send(parent, {:kh_runtime_done, run_ref, summary})
      end)

    {:ok, run_ref, worker, monitor, base_elapsed}
  end

  defp launch_run(state, prompt, append_input) do
    case start_run(state, prompt, append_input) do
      {:ok, run_ref, worker, monitor, _base_elapsed} ->
        {:reply, {:ok, run_ref},
         %{
           state
           | status: "running",
             worker: worker,
             monitor: monitor,
             run_ref: run_ref,
             last_summary: nil,
             last_checkpoint_at: Kh.Util.now_ms(),
             events: [],
             waiters: []
         }}
    end
  end

  defp persist_cancel_elapsed(%{checkpoint: checkpoint} = state) when is_map(checkpoint) do
    elapsed = (checkpoint[:elapsed_ms] || 0) + max(Kh.Util.now_ms() - (state.last_checkpoint_at || Kh.Util.now_ms()), 0)
    checkpoint = enrich_checkpoint(state, Map.put(checkpoint, :elapsed_ms, elapsed))

    case Kh.Checkpoint.save(state.config.checkpoint_path, checkpoint) do
      :ok -> %{state | checkpoint: checkpoint, checkpoint_error: nil, last_checkpoint_at: nil}
      {:error, reason} -> %{state | checkpoint_error: "cannot persist cancellation checkpoint: #{inspect(reason)}", last_checkpoint_at: nil}
    end
  end

  defp persist_cancel_elapsed(state), do: state

  defp enrich_checkpoint(state, checkpoint) do
    checkpoint
    |> Map.put(:runtime_provider, provider_name(state.provider))
    |> Map.put(:account_id_hash, state.config.account_id_hash)
  end

  defp run_result(state) do
    %{
      "session_id" => state.session_id,
      "run_id" => state.run_ref,
      "summary" => json_safe(public_summary(state)),
      "events" => Enum.reverse(state.events),
      "evidence" => session_evidence(state)
    }
  end

  defp session_evidence(state) do
    summary = state.last_summary || %{}
    turn_events = Enum.filter(state.events, &(&1["type"] == "turn_start"))
    completed_turns = Enum.filter(state.events, &(&1["type"] == "turn_end"))
    retry_events = Enum.filter(state.events, &(&1["type"] == "retry"))
    failed_usage_events = Enum.filter(state.events, &(&1["type"] == "failed_attempt_usage"))
    reported_turns = Enum.filter(completed_turns, &get_in(&1, ["data", "usage_reported"]))
    observed_usage = sum_event_usage(reported_turns)
    observed_failed_usage = sum_event_usage(failed_usage_events)
    usage_reported? = completed_turns != [] and length(reported_turns) == length(completed_turns)
    usage_complete? = state.status == "complete" and usage_reported? and not is_nil(observed_usage) and length(turn_events) == length(completed_turns) and retry_events == []
    complete_usage = if usage_complete?, do: observed_usage

    usage_state =
      cond do
        completed_turns == [] -> "unknown"
        usage_complete? -> "reported"
        true -> "partial"
      end

    %{
      "session_id" => state.session_id,
      "run_id" => state.run_ref,
      "provider" => provider_name(state.provider),
      "model" => state.config.model,
      "effort" => state.config.effort,
      "status" => state.status,
      "checkpoint_path" => state.config.checkpoint_path,
      "checkpoint_sha256" => checkpoint_sha(state.config.checkpoint_path),
      "checkpoint_error" => state.checkpoint_error,
      "checkpoint_phase" => state.checkpoint && state.checkpoint[:phase],
      "checkpoint_turn" => state.checkpoint && state.checkpoint[:turn],
      "checkpoint_elapsed_ms" => state.checkpoint && state.checkpoint[:elapsed_ms],
      "resumable" => is_map(state.checkpoint) and is_nil(state.checkpoint_error),
      "usage_scope" => "run",
      "usage_state" => usage_state,
      "usage" => json_safe(complete_usage),
      "usage_observed" => json_safe(observed_usage),
      "failed_attempt_usage_observed" => json_safe(observed_failed_usage),
      "turns_without_usage" => max(length(completed_turns) - length(reported_turns), 0),
      "error_kind" => summary[:error_kind] && to_string(summary[:error_kind]),
      "error" => summary[:error],
      "scripted_requests" => length(state.script_requests)
    }
  end

  defp public_summary(%{last_summary: nil}), do: nil

  defp public_summary(state) do
    evidence = session_evidence(state)

    state.last_summary
    |> Map.put(:usage, evidence["usage"])
    |> Map.put(:usage_total, evidence["usage"])
    |> Map.put(:usage_observed, evidence["usage_observed"])
    |> Map.put(:usage_failed_attempts, evidence["failed_attempt_usage_observed"])
    |> Map.put(:usage_scope, evidence["usage_scope"])
    |> Map.put(:usage_state, evidence["usage_state"])
    |> Map.put(:turns_without_usage, evidence["turns_without_usage"])
  end

  defp sum_event_usage([]), do: nil

  defp sum_event_usage(events) do
    empty = %{"input" => 0, "cached_input" => 0, "cache_write" => 0, "output" => 0, "reasoning" => 0}
    values = Enum.map(events, &get_in(&1, ["data", "usage"]))

    if Enum.all?(values, fn usage ->
         is_map(usage) and Enum.all?(empty, fn {key, _} -> is_integer(usage[key]) and usage[key] >= 0 end)
       end) do
      Enum.reduce(values, empty, fn usage, acc -> Map.merge(acc, usage, fn _key, left, right -> left + right end) end)
    else
      nil
    end
  end

  defp normalize_run_end(data, state) do
    status = if data["status"] == "ok", do: "complete", else: data["status"]
    evidence = session_evidence(%{state | status: status})

    data
    |> Map.put("usage", evidence["usage"])
    |> Map.put("usage_total", evidence["usage"])
    |> Map.put("usage_observed", evidence["usage_observed"])
    |> Map.put("usage_failed_attempts", evidence["failed_attempt_usage_observed"])
    |> Map.put("usage_scope", "run")
    |> Map.put("usage_state", evidence["usage_state"])
    |> Map.put("turns_without_usage", evidence["turns_without_usage"])
  end

  defp cancelled_summary(checkpoint, error \\ "cancelled by caller")

  defp cancelled_summary(nil, error),
    do: %{status: "cancelled", error: error, error_kind: :cancelled, turns: 0, usage: nil, usage_failed_attempts: nil, turns_without_usage: 0}

  defp cancelled_summary(checkpoint, error) do
    %{
      status: "cancelled",
      error: error,
      error_kind: :cancelled,
      turns: checkpoint[:turn] || 0,
      usage: checkpoint[:usage],
      usage_failed_attempts: checkpoint[:failed_usage],
      turns_without_usage: checkpoint[:unreported],
      final_text: checkpoint[:last_text]
    }
  end

  defp reply_waiters(state, result) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
  end

  defp restore_checkpoint(%{restore_from: nil}), do: :fresh

  defp restore_checkpoint(config) do
    case Kh.Checkpoint.load(config.restore_from) do
      {:ok, checkpoint} ->
        binding = checkpoint[:binding]

        cond do
          not is_map(binding) -> {:error, "checkpoint lacks the exact run binding"}
          binding.model_id != config.model -> {:error, "checkpoint model does not match"}
          binding.api != "responses" or binding.chatgpt != (config.provider == :chatgpt) -> {:error, "checkpoint provider does not match"}
          Path.expand(binding.cwd) != config.cwd -> {:error, "checkpoint working directory does not match"}
          binding.system != config.system_prompt -> {:error, "checkpoint system prompt does not match"}
          binding.effort_sent != config.effort_sent -> {:error, "checkpoint effort does not match"}
          binding.tools_allow != config.tools -> {:error, "checkpoint tools do not match"}
          binding.max_turns != config.max_turns -> {:error, "checkpoint turn allowance does not match"}
          checkpoint[:runtime_provider] != provider_name(config.provider) -> {:error, "checkpoint runtime provider does not match"}
          checkpoint[:account_id_hash] != config.account_id_hash -> {:error, "checkpoint account does not match"}
          true -> {:ok, checkpoint, binding.session_id}
        end

      {:error, message} -> {:error, message}
    end
  end

  # Reject a refused restore before start_link can deliver an init failure as
  # a linked exit to the caller. init/1 repeats this check to close the gap
  # between admission and process startup.
  defp validate_restore_binding(%{restore_from: nil}), do: :ok

  defp validate_restore_binding(config) do
    case restore_checkpoint(config) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp normalize(config) when is_list(config), do: config |> Map.new() |> normalize()

  defp normalize(config) when is_map(config) do
    provider = config[:provider]
    model_id = config[:model]
    cwd = config[:cwd]
    system_prompt = config[:system_prompt]
    checkpoint_path = config[:checkpoint_path]

    with true <- provider in [:chatgpt, :scripted] || {:error, "provider must be :chatgpt or :scripted"},
         true <- is_binary(model_id) and model_id != "" || {:error, "model is required"},
         true <- is_binary(cwd) and cwd != "" || {:error, "cwd is required"},
         true <- is_binary(system_prompt) and system_prompt != "" || {:error, "system_prompt is required"},
         true <- is_binary(checkpoint_path) and checkpoint_path != "" || {:error, "checkpoint_path is required"},
         {:ok, auth} <- auth_options(provider, config),
         {:ok, effort, effort_sent} <- normalize_effort(config[:effort], model_id),
         {:ok, script} <- normalize_script(provider, config[:scripted_replies] || config[:script]),
         :ok <- require_fresh_script_for_restore(provider, config) do
      features = MapSet.new(config[:features] || [])
      tools = config[:tools] || Kh.Tools.all_names(features)
      supported_tools = Kh.Tools.all_names(features)

      if not Enum.all?(tools, &(&1 in supported_tools)) do
        {:error, "tools must be selected from read, write, edit, bash"}
      else
        {:ok,
         Map.merge(config, auth)
         |> Map.merge(%{
           provider: provider,
           model: model_id,
           model_descriptor: Kh.Models.chatgpt(model_id, %{chatgpt: provider == :chatgpt}),
           effort: effort,
           effort_sent: effort_sent,
           cwd: Path.expand(cwd),
           system_prompt: system_prompt,
           checkpoint_path: Path.expand(checkpoint_path),
           restore_from: if(config[:restore_from], do: Path.expand(config[:restore_from]), else: nil),
           session_id: config[:session_id],
           timeout_s: config[:timeout_s] || 600,
           max_turns: config[:max_turns] || 100,
           features: features,
           tools: tools,
           script: script,
           base_url: Kh.Models.chatgpt_base_url(),
           compact_at: config[:compact_at],
           max_output: config[:max_output],
           max_total_tokens: config[:max_total_tokens],
           tmp_dir: config[:tmp_dir],
           bash_pgroup: config[:bash_pgroup] == true,
           event_sink: config[:event_sink]
         })}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp normalize(_), do: {:error, "session configuration must be a map or keyword list"}

  defp auth_options(:chatgpt, config) do
    token = config[:access_token]
    account_id = config[:account_id]

    if not (is_binary(token) and token != "" and is_binary(account_id) and account_id != "") do
      {:error, "ChatGPT session requires caller-supplied access_token and account_id"}
    else
      now = System.os_time(:second)

      case jwt_exp(token) do
        exp when is_integer(exp) and exp - now < @credential_margin_s ->
          {:error, "ChatGPT access token expires within 60 seconds; refresh the selected Codex login and reopen"}

        _ ->
          {:ok, %{access_token: token, account_id: account_id, account_id_hash: hash(account_id)}}
      end
    end
  end

  defp auth_options(:scripted, config) do
    if Map.has_key?(config, :access_token) or Map.has_key?(config, :account_id) do
      {:error, "scripted provider does not accept credentials"}
    else
      {:ok, %{access_token: nil, account_id: nil, account_id_hash: nil}}
    end
  end

  defp normalize_effort(nil, _model_id), do: {:ok, nil, nil}

  defp normalize_effort(effort, model_id) when is_binary(effort) do
    model = Kh.Models.chatgpt(model_id)

    if Map.has_key?(model.efforts, effort) do
      {sent, _note} = Kh.Models.effort(model, effort)
      {:ok, effort, sent}
    else
      {:error, "unsupported ChatGPT effort for this model; choose a documented setting or omit it"}
    end
  end

  defp normalize_effort(_, _model_id), do: {:error, "effort must be a string"}

  defp normalize_script(:chatgpt, nil), do: {:ok, nil}
  defp normalize_script(:chatgpt, _), do: {:error, "ChatGPT sessions do not accept scripted replies"}
  defp normalize_script(:scripted, nil), do: {:ok, []}

  defp normalize_script(:scripted, script) when is_list(script) do
    valid = Enum.all?(script, &valid_script_step?/1)

    if valid, do: {:ok, script}, else: {:error, "script steps require expectation maps and reply maps"}
  end

  defp normalize_script(:scripted, _), do: {:error, "script must be a list"}

  defp valid_script_step?(%{"expect" => expect, "reply" => reply}) when is_map(expect) and is_map(reply) do
    expectation_keys = Enum.map(@script_expectations, &Atom.to_string/1)
    Enum.all?(Map.keys(expect), &(&1 in expectation_keys)) and valid_expectation?(expect) and
      valid_reply?(reply) and valid_echo_expectation?(expect, reply)
  end

  defp valid_script_step?(_), do: false

  defp valid_expectation?(expect) do
    Enum.all?(expect, fn
      {"model", value} -> is_binary(value)
      {"effort_sent", value} -> is_nil(value) or is_binary(value)
      {"session_id", value} -> is_binary(value)
      {"tool_names", value} -> is_list(value) and Enum.all?(value, &is_binary/1)
      {"message_count", value} -> is_integer(value) and value >= 0
      {"last_user_text", value} -> is_binary(value)
      {"last_message_role", value} -> value in ["user", "assistant", "tool"]
      {"last_tool_name", value} -> is_binary(value)
      {"last_tool_is_error", value} -> is_boolean(value)
      _ -> false
    end)
  end

  defp valid_reply?(reply) do
    allowed = ~w(text text_from_last_tool reasoning tool_calls usage error message)
    Enum.all?(Map.keys(reply), &(&1 in allowed)) and
      (is_nil(reply["text"]) or is_binary(reply["text"])) and
      valid_echo_reply?(reply) and
      (is_nil(reply["reasoning"]) or is_binary(reply["reasoning"])) and
      (is_nil(reply["usage"]) or valid_script_usage?(reply["usage"])) and
      (is_nil(reply["message"]) or is_binary(reply["message"])) and
      (is_nil(reply["tool_calls"]) or valid_script_calls?(reply["tool_calls"])) and
      (is_nil(reply["error"]) or reply["error"] in ~w(fatal transient rate_limit auth timeout)) and
      (is_nil(reply["error"]) or is_nil(reply["tool_calls"]))
  end

  defp valid_echo_reply?(reply) do
    case reply["text_from_last_tool"] do
      nil -> true
      true ->
        is_nil(reply["text"]) and is_nil(reply["reasoning"]) and
          is_nil(reply["tool_calls"]) and is_nil(reply["error"]) and is_nil(reply["message"])

      _ -> false
    end
  end

  defp valid_echo_expectation?(expect, %{"text_from_last_tool" => true}) do
    expect["last_message_role"] == "tool" and expect["last_tool_name"] == "bash" and
      expect["last_tool_is_error"] == false
  end

  defp valid_echo_expectation?(_expect, _reply), do: true

  defp valid_script_calls?(calls) when is_list(calls) do
    Enum.all?(calls, fn
      %{"name" => name, "args" => args} = call ->
        is_binary(name) and name in ~w(read write edit bash) and is_map(args) and
          Enum.all?(Map.keys(call), &(&1 in ["id", "name", "args"])) and
          (is_nil(call["id"]) or is_binary(call["id"])) and json_object?(args)

      _ -> false
    end)
  end

  defp valid_script_calls?(_), do: false

  defp valid_script_usage?(usage) when is_map(usage) do
    keys = ~w(input cached_input cache_write output reasoning)
    Enum.all?(keys, &(is_integer(usage[&1]) and usage[&1] >= 0)) and Enum.all?(Map.keys(usage), &(&1 in keys))
  end

  defp valid_script_usage?(_), do: false

  defp json_object?(map) do
    Enum.all?(Map.keys(map), &is_binary/1) and
      try do
        JSON.encode!(map)
        true
      rescue
        _ -> false
      end
  end

  defp require_fresh_script_for_restore(:scripted, %{restore_from: path} = config)
       when is_binary(path) do
    if Map.has_key?(config, :scripted_replies) or Map.has_key?(config, :script),
      do: :ok,
      else: {:error, "scripted restore requires a fresh scripted_replies queue"}
  end

  defp require_fresh_script_for_restore(_provider, _config), do: :ok

  defp expectation_matches?(expected, request) do
    Enum.all?(expected, fn
      {"message_count", n} -> length(request["messages"]) == n
      {"last_user_text", text} -> last_user_text(request["messages"]) == text
      {"last_message_role", role} -> last_message_role(request["messages"]) == role
      {"last_tool_name", name} -> last_tool(request["messages"], :name) == name
      {"last_tool_is_error", value} -> last_tool(request["messages"], :is_error) == value
      {key, value} -> Map.get(request, key) == value
    end)
  end

  defp scripted_reply(%{"text_from_last_tool" => true} = reply, state, request) do
    case last_tool_message(request["messages"]) do
      %{name: "bash", is_error: false, content: content}
      when is_binary(content) ->
        output = String.trim(content)

        if output != "" and output != "(no output)" do
          scripted_reply(reply |> Map.delete("text_from_last_tool") |> Map.put("text", content), state, request)
        else
          {{:error, {:fatal, "scripted last-tool echo requires nonempty successful bash output"}}, state}
        end

      _ ->
        {{:error, {:fatal, "scripted last-tool echo requires nonempty successful bash output"}}, state}
    end
  end

  defp scripted_reply(%{"error" => kind} = reply, state, _request) when kind in ["fatal", "transient", "rate_limit", "auth", "timeout"] do
    usage = usage(reply["usage"])
    meta = if is_nil(usage), do: %{}, else: %{usage: usage}
    result = if meta == %{}, do: {:error, {String.to_existing_atom(kind), reply["message"] || "scripted error"}}, else: {:error, {String.to_existing_atom(kind), reply["message"] || "scripted error"}, meta}
    {result, state}
  end

  defp scripted_reply(reply, state, _request) do
    calls =
      Enum.with_index(reply["tool_calls"] || [])
      |> Enum.map(fn {call, index} ->
        %{
          id: call["id"] || "#{state.session_id}-script-#{length(state.script_requests)}-#{index}",
          name: call["name"],
          args_raw: JSON.encode!(call["args"] || %{})
        }
      end)

    usage = usage(reply["usage"])

    response = %{
      text: reply["text"] || "",
      reasoning: reply["reasoning"],
      tool_calls: calls,
      usage: usage || Kh.Provider.empty_usage(),
      usage_reported: not is_nil(usage),
      stop: if(calls == [], do: "stop", else: "tool_calls"),
      items: nil,
      response_id: "scripted-#{length(state.script_requests)}",
      ttft_ms: nil
    }

    {{:ok, response}, state}
  end

  defp usage(nil), do: nil

  defp usage(input) when is_map(input) do
    values = Map.new(["input", "cached_input", "cache_write", "output", "reasoning"], fn key -> {String.to_existing_atom(key), input[key] || 0} end)

    if Enum.all?(Map.values(values), &(is_integer(&1) and &1 >= 0)), do: values, else: nil
  end

  defp usage(_), do: nil

  defp last_user_text(messages), do: Enum.find_value(Enum.reverse(messages), fn %{role: :user, text: text} -> text; _ -> nil end)
  defp last_message_role(messages), do: messages |> List.last() |> then(fn m -> if m, do: Atom.to_string(m.role), else: nil end)
  defp provider_name(:chatgpt), do: "chatgpt-subscription"
  defp provider_name(:scripted), do: "scripted-offline"

  defp jwt_exp(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- JSON.decode(decoded) do
      exp
    else
      _ -> nil
    end
  end

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp checkpoint_sha(path) do
    case File.read(path) do
      {:ok, bytes} -> hash(bytes)
      _ -> nil
    end
  end

  defp last_tool(messages, key) do
    case last_tool_message(messages) do
      nil -> nil
      message -> Map.get(message, key)
    end
  end

  defp last_tool_message(messages),
    do: Enum.find(Enum.reverse(messages), &(&1[:role] == :tool))

  defp json_safe(nil), do: nil
  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_safe(%MapSet{} = value), do: value |> MapSet.to_list() |> json_safe()
  defp json_safe(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: inspect(value)
end
