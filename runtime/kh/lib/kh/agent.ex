defmodule Kh.Agent do
  @moduledoc "The agent loop: call the model, run tool calls sequentially, repeat until no tool calls, max turns or deadline."
  alias Kh.{Util, Provider, Models}

  @checkpoint_fields ~w(phase pending in_flight terminal_status terminal_error binding messages turn usage failed_usage cost last_ctx_tokens last_text truncated unreported overflowed elapsed_ms resume_binding runtime_provider account_id_hash)a
  @retry_delays [2_000, 4_000, 8_000]
  @overflow ~r/context.?length|context window|maximum context|prompt is too long|too many tokens|exceeds? (the )?(maximum|context|model)|input is too long|request too large|context_length_exceeded/i

  @doc """
  opts: model (map), effort (string|nil), prompt, cwd, timeout_s, max_turns, features (MapSet), tools (list|nil),
        provider (module), base_url, api_key, account_id, session_id, emit (fn type, map), compact_at (float|nil), max_output, tmp_dir, max_total_tokens (optional prompt+output token budget),
        on_checkpoint (callback at loop boundaries), resume (decoded checkpoint; keep request options unchanged),
        checkpoint_guard (cumulative active-time and bound-request admission; enabled by Kh.Session)
  """
  def run(o) do
    binding = o[:resume] && o.resume[:binding]
    o = Kh.ResumeBinding.restore(o, binding)
    started = Util.now_ms()
    deadline = started + o.timeout_s * 1000
    {sent, note} = if binding, do: {binding.effort_sent, "restored from checkpoint"}, else: Models.effort(o.model, o.effort)
    system = o[:system_prompt] || raise(ArgumentError, "system_prompt is required; project context is supplied by the caller")
    context = []
    tools = if binding, do: binding.tools, else: Kh.Tools.specs(o.features, o[:tools])

    o.emit.("run_start", %{
      kh_version: Kh.Version.string(),
      bash_pgroup: o[:bash_pgroup] == true,
      strict_chat_finish: o[:strict_chat_finish] == true,
      model: o.model.id,
      api: o.model.api,
      effort_requested: o.effort,
      effort_sent: sent,
      effort_note: note,
      cwd: o.cwd,
      session_id: o.session_id,
      provider: o[:provider_name] || if(o.model[:chatgpt], do: "chatgpt-subscription", else: "custom"),
      cache_mode:
        cond do
          o[:provider_name] == "scripted-offline" -> "none (strict local scripted provider)"
          o.model[:chatgpt] -> "prompt_cache_key+session_id (chatgpt backend)"
          o.model.api == :responses -> "prompt_cache_key+x-opencode-session+x-client-request-id"
          true -> "x-opencode-session (provider automatic prefix cache)"
        end,
      features: o.features |> MapSet.to_list() |> Enum.sort(),
      tools: Enum.map(tools, & &1.name),
      max_turns: o.max_turns,
      timeout_s: o.timeout_s,
      system_prompt_chars: String.length(system),
      tool_schema_chars: tools |> JSON.encode!() |> String.length(),
      context_files: Enum.map(context, &elem(&1, 0))
    })

    st = %{
      phase: "ready",
      pending: [],
      in_flight: nil,
      terminal_status: nil,
      terminal_error: nil,
      binding: nil,
      o: o,
      system: system,
      tools: tools,
      messages: [%{role: :user, text: o.prompt}],
      turn: 0,
      usage: Provider.empty_usage(),
      failed_usage: Provider.empty_usage(),
      truncated: false,
      overflowed: false,
      unreported: 0,
      cost: nil,
      tool_ctx: %{cwd: o.cwd, deadline: deadline, features: o.features, tmp_dir: o[:tmp_dir], session_id: o.session_id, bash_pgroup: o[:bash_pgroup] == true},
      deadline: deadline,
      sent: sent,
      started: started,
      last_ctx_tokens: 0,
      last_text: "",
      elapsed_ms: 0,
      resume_binding: nil,
      runtime_provider: o[:provider_name],
      account_id_hash: o[:account_id_hash]
    }

    st = %{st | binding: Kh.ResumeBinding.snapshot(st)}
    st = %{st | resume_binding: guard_binding(st.binding, st.messages)}
    st =
      case o[:resume] do
        %{messages: _} = cp -> Map.merge(st, Map.take(cp, @checkpoint_fields))
        _ -> st
      end

    st =
      case o[:append_input] do
        input when is_binary(input) ->
          if match?(%{phase: "complete", terminal_status: "ok"}, o[:resume]) do
            %{
              st
              | messages: st.messages ++ [%{role: :user, text: input}],
                phase: "ready",
                terminal_status: nil,
                terminal_error: nil
            }
          else
            raise ArgumentError, "new input requires a successfully completed checkpoint"
          end

        _ ->
          st
      end

    try do
      if o[:checkpoint_guard] do
        valid_resume =
          is_nil(o[:resume]) or
            (is_integer(st.elapsed_ms) and st.elapsed_ms >= 0 and
               st.resume_binding == guard_binding(st.binding, st.messages))

        if valid_resume do
          guarded_deadline = started + o.timeout_s * 1000 - st.elapsed_ms
          loop(%{st | deadline: guarded_deadline, tool_ctx: %{st.tool_ctx | deadline: guarded_deadline}})
        else
          finish(st, "error", "checkpoint request/context or elapsed accounting missing or changed", "resume_binding")
        end
      else
        loop(st)
      end
    catch
      {:checkpoint_failed, failed} -> finish(failed, "error", "cannot persist checkpoint; stopped before the next action", :checkpoint)
    end
  end

  @doc "Resume a checkpoint exactly, optionally appending one user turn after a clean successful completion."
  def run_continue(opts, checkpoint, append_input \\ nil) do
    opts = Map.put(opts, :resume, checkpoint)

    if is_nil(append_input) do
      run(opts)
    else
      if checkpoint[:phase] == "complete" and checkpoint[:terminal_status] == "ok" and is_binary(append_input) do
        run(Map.put(opts, :append_input, append_input))
      else
        %{status: "error", error_kind: :resume_binding, error: "new input requires a successfully completed checkpoint"}
      end
    end
  end

  @doc "Snapshot sufficient to continue a run exactly (same next request) in a new process."
  def checkpoint(st) do
    cp = Map.take(st, @checkpoint_fields)

    if st.o[:checkpoint_guard] do
      cp
      |> Map.put(:elapsed_ms, st.elapsed_ms + max(Util.now_ms() - st.started, 0))
      |> Map.put(:resume_binding, st.resume_binding)
    else
      cp
    end
  end

  defp guard_binding(binding, messages) do
    first_prompt = Enum.find_value(messages, fn %{role: :user, text: text} -> text; _ -> nil end)

    :crypto.hash(:sha256, :erlang.term_to_binary({binding, first_prompt}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "JSON-safe form of a checkpoint (and its inverse)."
  def encode_checkpoint(cp), do: JSON.encode!(Map.put(%{cp | messages: Enum.map(cp.messages, &encode_msg/1)}, :version, 1))

  def decode_checkpoint(json) do
    m = JSON.decode!(json)
    if m["version"] not in [nil, 1], do: raise(ArgumentError, "invalid or unsupported checkpoint")
    atomize = fn map -> Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end) end

    cp = %{
      messages: Enum.map(m["messages"], &decode_msg/1),
      turn: m["turn"],
      usage: atomize.(m["usage"]),
      failed_usage: atomize.(m["failed_usage"]),
      cost: m["cost"]
    }

    cp = Enum.reduce(@checkpoint_fields -- Map.keys(cp), cp, fn key, acc ->
      if Map.has_key?(m, Atom.to_string(key)) do
        value = case key do
          :binding -> Kh.ResumeBinding.decode(m["binding"])
          :pending -> Enum.map(m["pending"], fn c -> %{id: c["id"], name: c["name"], args_raw: c["args_raw"]} end)
          _ -> m[Atom.to_string(key)]
        end
        Map.put(acc, key, value)
      else
        acc
      end
    end)
    Kh.Checkpoint.validate!(cp)
  end

  defp encode_msg(%{role: r} = m), do: m |> Map.put(:role, Atom.to_string(r)) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

  defp decode_msg(%{"role" => "user"} = m), do: %{role: :user, text: m["text"]}

  defp decode_msg(%{"role" => "tool"} = m), do: %{role: :tool, call_id: m["call_id"], name: m["name"], content: m["content"], is_error: m["is_error"]}

  defp decode_msg(%{"role" => "assistant"} = m) do
    %{role: :assistant, text: m["text"], reasoning: m["reasoning"], items: m["items"], tool_calls: Enum.map(m["tool_calls"] || [], &%{id: &1["id"], name: &1["name"], args_raw: &1["args_raw"]})}
  end

  defp loop(st) do
    st = persist(st)

    cond do
      st.phase == "complete" -> finish(st, st.terminal_status, st.terminal_error)
      st.phase == "tools" -> loop(recover_tools(st))
      Util.now_ms() >= st.deadline -> finish(st, "timeout", "overall timeout reached")
      st.turn >= st.o.max_turns -> finish(st, "max_turns", "reached max turns (#{st.o.max_turns})")
      budget_spent?(st) -> finish(st, "budget", "token budget reached (#{st.o.max_total_tokens})")
      true -> turn(compact(st))
    end
  end

  defp budget_spent?(%{o: %{max_total_tokens: n}} = st) when is_integer(n), do: Provider.prompt_tokens(st.usage) + st.usage.output + Provider.prompt_tokens(st.failed_usage) + st.failed_usage.output >= n
  defp budget_spent?(_), do: false

  defp turn(st) do
    n = st.turn + 1
    t0 = Util.now_ms()
    st.o.emit.("turn_start", %{turn: n, messages: length(st.messages)})

    popts = %{
      base_url: st.o.base_url,
      api_key: st.o.api_key,
      account_id: st.o[:account_id],
      session_id: st.o.session_id,
      session_server: st.o[:session_server],
      run_ref: st.o[:run_ref],
      effort_sent: st.sent,
      max_output: st.o[:max_output],
      deadline: st.deadline
    }

    {res, failed} = call(st, n, popts, 0, Provider.empty_usage())
    st = %{st | failed_usage: Provider.add_usage(st.failed_usage, failed)}

    case res do
      {:ok, r0} ->
        r = uniquify_call_ids(r0)
        if r[:bad_frames] && r.bad_frames > 0, do: st.o.emit.("warn", %{turn: n, bad_frames: r.bad_frames, note: "undecodable stream frames were dropped"})
        st = %{st | turn: n, overflowed: false, usage: Provider.add_usage(st.usage, r.usage), unreported: st.unreported + if(Map.get(r, :usage_reported, true), do: 0, else: 1)}
        st = %{st | last_ctx_tokens: r.usage.input + r.usage.cached_input + r.usage.cache_write, last_text: r.text}

        {hist_calls, hist_items} = sanitize_history(r.tool_calls, r.items)
        msg = %{role: :assistant, text: r.text, reasoning: r.reasoning, tool_calls: hist_calls, items: hist_items}
        st = %{st | messages: st.messages ++ [msg], truncated: r.stop in ["length", "max_output_tokens", "incomplete"] and r.tool_calls == []}

        # Publish accepted-response events only after their exact continuation is durable.
        st =
          cond do
            r.tool_calls != [] -> %{st | phase: "tools", pending: r.tool_calls, in_flight: nil}
            r.stop in ["length", "max_output_tokens", "incomplete"] and r.text == "" ->
              %{st | phase: "complete", terminal_status: "error", terminal_error: "response truncated (#{r.stop}) with no text or tool call"}
            true -> %{st | phase: "complete", terminal_status: "ok", terminal_error: nil}
          end
          |> persist()

        st.o.emit.("turn_end", %{
          turn: n,
          latency_ms: Util.now_ms() - t0,
          ttft_ms: r.ttft_ms,
          usage: r.usage,
          usage_reported: Map.get(r, :usage_reported, true),
          prompt_tokens: Provider.prompt_tokens(r.usage),
          cache_hit_rate: Provider.cache_hit_rate(r.usage),
          cost_usd: nil,
          stop_reason: r.stop,
          text: r.text,
          reasoning_chars: String.length(r.reasoning || ""),
          tool_calls: Enum.map(r.tool_calls, & &1.name),
          response_id: r.response_id
        })

        cond do
          r.tool_calls != [] ->
            loop(run_pending(st, n))

          r.stop in ["length", "max_output_tokens", "incomplete"] and r.text == "" ->
            finish(st, "error", "response truncated (#{r.stop}) with no text or tool call")

          true ->
            finish(st, "ok", nil)
        end

      {:error, {:fatal, msg}} = err ->
        # provider says the request is too big: elide old tool output and retry the turn once
        if Regex.match?(@overflow, msg) and not st.overflowed do
          st2 = compact(st, true)
          if st2.messages != st.messages, do: turn(%{st2 | overflowed: true}), else: fail(st, n, err)
        else
          fail(st, n, err)
        end

      {:error, _} = err ->
        fail(st, n, err)
    end
  end

  # Reserve original ids so generated suffixes cannot collide with another call.
  defp uniquify_call_ids(%{tool_calls: calls} = r) do
    reserved = MapSet.new(calls, & &1.id)
    {calls2, _} = Enum.map_reduce(calls, MapSet.new(), fn c, seen ->
      id = if MapSet.member?(seen, c.id), do: unused_call_id(c.id, 1, MapSet.union(reserved, seen)), else: c.id
      {%{c | id: id}, MapSet.put(seen, id)}
    end)
    items =
      if is_list(r.items) do
        {items, _} = Enum.map_reduce(r.items, calls2, fn
          %{"type" => "function_call"} = item, [call | rest] -> {Map.put(item, "call_id", call.id), rest}
          item, rest -> {item, rest}
        end)
        items
      else
        r.items
      end
    %{r | tool_calls: calls2, items: items}
  end

  defp unused_call_id(id, n, reserved) do
    candidate = "#{id}-dup#{n}"
    if MapSet.member?(reserved, candidate), do: unused_call_id(id, n + 1, reserved), else: candidate
  end

  defp fail(st, n, {:error, {kind, msg}}), do: finish(%{st | turn: n}, error_status(kind), msg, kind)

  # A call whose arguments are not a JSON object is answered with an error result, but it must not be replayed verbatim
  # into the provider history (providers validate `arguments`): replay `{}` instead.
  defp sanitize_history(calls, items) do
    bad = for c <- calls, not match?({:ok, %{}}, JSON.decode(c.args_raw)), into: MapSet.new(), do: c.id
    if MapSet.size(bad) == 0, do: {calls, items}, else: {Enum.map(calls, &if(MapSet.member?(bad, &1.id), do: %{&1 | args_raw: "{}"}, else: &1)), patch_items(items, bad)}
  end

  defp patch_items(items, bad) when is_list(items),
    do: Enum.map(items, fn %{"type" => "function_call", "call_id" => id} = i -> if(MapSet.member?(bad, id), do: %{i | "arguments" => "{}"}, else: i); i -> i end)

  defp patch_items(items, _), do: items

  defp error_status(:budget), do: "budget"
  defp error_status(:timeout), do: "timeout"
  defp error_status(_), do: "error"

  # -> {result, usage billed by failed attempts}. Failed attempts that report usage are summed apart from the successful turn.
  defp call(st, n, popts, attempt, failed) do
    mod = st.o.provider || Provider.module(st.o.model)
    res = mod.stream(st.o.model, st.system, st.messages, st.tools, popts)
    {res, meta} = case res do {:error, e, meta} -> {{:error, e}, meta}; other -> {other, %{}} end
    failed = if meta[:usage], do: Provider.add_usage(failed, meta.usage), else: failed
    # Durable observed usage before a retry sleeps or another request starts.
    observed = %{st | failed_usage: Provider.add_usage(st.failed_usage, failed)}
    if meta[:usage] do
      st.o.emit.("failed_attempt_usage", %{turn: n, attempt: attempt + 1, usage: meta.usage})
      persist(observed)
    end
    res = if budget_spent?(observed), do: {:error, {:budget, "token budget reached on failed attempt"}}, else: res
    retryable? = match?({:error, {:transient, _}}, res) or (match?({:error, {:rate_limit, _}}, res) and meta[:retryable] == true)

    case res do
      {:error, {_kind, msg}} when retryable? and attempt < length(@retry_delays) ->
        delay = max(Enum.at(@retry_delays, attempt), meta[:retry_after_ms] || 0)
        ev = %{turn: n, attempt: attempt + 1, delay_ms: delay, reason: Util.clip(msg, 300)}
        st.o.emit.("retry", if(meta[:usage], do: Map.put(ev, :usage, meta.usage), else: ev))

        if Util.now_ms() + delay < st.deadline do
          Process.sleep(if(st.o[:fast_retry], do: 1, else: delay))
          call(st, n, popts, attempt + 1, failed)
        else
          {{:error, {:timeout, "deadline reached while retrying: " <> msg}}, failed}
        end

      other ->
        {other, failed}
    end
  end

  defp persist(st) do
    try do
      if f = st.o[:on_checkpoint], do: f.(checkpoint(st))
      st
    rescue
      Kh.Checkpoint.Error -> throw({:checkpoint_failed, st})
    end
  end

  defp recover_tools(%{in_flight: nil} = st), do: run_pending(st, st.turn)

  defp recover_tools(%{pending: [c | rest]} = st) do
    # A process death cannot tell us whether an arbitrary tool's side effect happened.
    text = "Not repeated: interrupted tool outcome is uncertain. Inspect the workspace before deciding whether to retry this action."
    result = %{role: :tool, call_id: c.id, name: c.name, content: text, is_error: true}
    st = %{st | messages: st.messages ++ [result], pending: rest, in_flight: nil}
    st = persist(st)
    st.o.emit.("recovery_uncertain", %{turn: st.turn, id: c.id, name: c.name, note: text})
    run_pending(st, st.turn)
  end

  defp run_pending(%{pending: []} = st, _n), do: %{st | phase: "ready", in_flight: nil}

  defp run_pending(%{pending: [c | rest]} = st, n) do
    t0 = Util.now_ms()
    {args, parse_err} =
      case JSON.decode(c.args_raw) do
        {:ok, %{} = m} -> {m, nil}
        {:ok, _} -> {%{}, "Tool arguments must be a JSON object"}
        {:error, _} -> {%{}, "Invalid JSON in tool arguments: " <> Util.clip(c.args_raw, 200)}
      end

    st = persist(%{st | in_flight: c.id})
    st.o.emit.("tool_start", %{turn: n, id: c.id, name: c.name, args: summarize_args(args)})
    {ok?, text} =
      cond do
        parse_err -> {:error, parse_err}
        Util.now_ms() >= st.deadline -> {:error, "Not run: overall deadline reached"}
        true -> Kh.Tools.run(c.name, args, st.tool_ctx, st.o[:tools])
      end

    result = %{role: :tool, call_id: c.id, name: c.name, content: text, is_error: ok? == :error}
    phase = if rest == [], do: "ready", else: "tools"
    st = persist(%{st | messages: st.messages ++ [result], pending: rest, in_flight: nil, phase: phase})
    st.o.emit.("tool_end", %{
      turn: n, id: c.id, name: c.name, is_error: ok? == :error,
      duration_ms: Util.now_ms() - t0, result_chars: String.length(text), result_head: Util.clip(text, 300)
    })
    run_pending(st, n)
  end

  defp summarize_args(args), do: Map.new(args, fn {k, v} -> {k, if(is_binary(v), do: Util.clip(v, 500), else: v)} end)

  # Feature-free, cheap context control: when the last prompt exceeded compact_at * window, elide old tool results.
  defp compact(st, force \\ false)

  defp compact(%{o: %{compact_at: at}} = st, false) when is_number(at) and at > 0 do
    if st.last_ctx_tokens > at * st.o.model.ctx do
      elide(st, 8)
    else
      st
    end
  end

  defp compact(st, false), do: st
  # forced (provider reported a context overflow): keep only the last few messages verbatim
  defp compact(st, true), do: elide(st, 4, forced: true)

  defp elide(st, keep, opts \\ []) do
    {old, recent} = Enum.split(st.messages, max(length(st.messages) - keep, 1))
    before = chars(st.messages)

    old =
      Enum.map(old, fn
        %{role: :tool, content: c} = m when byte_size(c) > 400 -> %{m | content: "[kh: elided #{byte_size(c)} bytes of older tool output to save context]"}
        m -> m
      end)

    st = %{st | messages: old ++ recent}
    st.o.emit.("compact", %{turn: st.turn, ctx_tokens: st.last_ctx_tokens, chars_before: before, chars_after: chars(st.messages), forced: opts[:forced] == true})
    %{st | last_ctx_tokens: 0}
  end

  defp chars(msgs), do: Enum.reduce(msgs, 0, fn m, a -> a + String.length(m[:content] || m[:text] || "") end)

  defp finish(st, status, error, kind \\ nil) do
    st =
      cond do
        status == "ok" and st.phase != "complete" ->
          persist(%{st | phase: "complete", terminal_status: status, terminal_error: nil})

        status != "ok" and st.o[:checkpoint_guard] and
            kind not in [:checkpoint, "resume_binding"] ->
          # Retain failure, active time and exact ready/tool state. A later
          # explicit resume can retry the provider call without replaying tools.
          persist(%{st | terminal_status: "error", terminal_error: error})

        true ->
          st
      end

    wall = (Util.now_ms() - st.started) / 1000

    summary = %{
      status: status,
      error: error,
      error_kind: kind,
      turns: st.turn,
      usage: st.usage,
      prompt_tokens: Provider.prompt_tokens(st.usage),
      cache_hit_rate: Provider.cache_hit_rate(st.usage),
      usage_failed_attempts: st.failed_usage,
      turns_without_usage: st.unreported,
      truncated: st.truncated,
      cost_usd_successful_turns: nil,
      cost_usd_failed_attempts: nil,
      usage_total: Provider.add_usage(st.usage, st.failed_usage),
      cost_usd: nil,
      wall_s: Float.round(wall, 3),
      model: st.o.model.id,
      final_text: st.last_text
    }

    st.o.emit.("run_end", summary)
    summary
  end
end
