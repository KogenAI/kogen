defmodule Kh.Provider do
  @moduledoc """
  A provider turns (system, messages, tools) into one streamed assistant turn.

  Canonical messages:
    %{role: :user, text: s}
    %{role: :assistant, text: s, reasoning: s | nil, tool_calls: [%{id, name, args_raw}], items: raw | nil}
    %{role: :tool, call_id: id, name: n, content: s, is_error: bool}

  Result: {:ok, %{text, reasoning, tool_calls, usage: %{input, cached_input, cache_write, output, reasoning}, stop, items, response_id, ttft_ms}}
  or {:error, {:rate_limit | :auth | :transient | :fatal | :timeout, message}}.
  """
  @callback stream(model :: map, system :: String.t(), messages :: list, tools :: list, opts :: map) ::
              {:ok, map} | {:error, term} | {:error, term, map}

  def module(%{api: :responses}), do: Kh.Provider.Responses
  def module(_), do: raise(ArgumentError, "unsupported provider API; this runtime supports Responses only")

  def empty_usage, do: %{input: 0, cached_input: 0, cache_write: 0, output: 0, reasoning: 0}

  def prompt_tokens(u), do: u.input + u.cached_input + u.cache_write

  @doc "cached / (fresh + cached + cache_write); nil when the prompt was empty."
  def cache_hit_rate(u) do
    case prompt_tokens(u) do
      0 -> nil
      p -> Float.round(u.cached_input / p, 4)
    end
  end

  def add_usage(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)

  # Retry classification of provider errors that arrive inside the stream (response.failed / error events), ported from pi 0.99
  # (pi-ai utils/retry.js): quota/billing limits are final, transient wording (timed out, terminated, overloaded, ...) is retried.
  @non_retryable ~r/usage_limit_reached|usage limit reached|GoUsageLimitError|FreeUsageLimitError|Monthly usage limit reached|available balance|insufficient_quota|out of budget|quota exceeded|billing|subscription_sharing_usage_limit_exceeded/i
  @retryable ~r/overloaded|currently experiencing high demand|rate.?limit|too many requests|429|500|502|503|504|520|524|service.?unavailable|server.?error|internal.?error|provider.?returned.?error|exceeded request buffer limit while retrying upstream|network.?error|connection.?error|connection.?refused|connection.?lost|other side closed|fetch failed|getaddrinfo|ENOTFOUND|EAI_AGAIN|upstream.?connect|reset before headers|socket hang up|socket connection was closed|timed? out|timeout|terminated|websocket.?closed|websocket.?error|ended without|stream ended before message_stop|stream ended before a terminal response event|http2 request did not get a response|retry delay|you can retry your request|try your request again|please retry your request|ResourceExhausted|subscription_sharing_usage_unavailable|subscription_sharing_user_unavailable/i

  @doc "Shared HTTP driver: sends `body`, feeds SSE data payloads to `handle.(json_string, state)` and returns final state."
  def run_sse(url, headers, body, deadline, init_state, handle) do
    started = Kh.Util.now_ms()
    key = {__MODULE__, make_ref()}
    Process.put(key, {"", init_state})

    on_data = fn chunk ->
      {buf, st} = Process.get(key)
      {events, buf} = Kh.SSE.feed(buf, chunk)

      st =
        Enum.reduce(events, st, fn data, s -> if data == "[DONE]" and not Map.has_key?(s, :done), do: s, else: safe_event(data, s, started, handle) end)

      Process.put(key, {buf, st})
    end

    result = Kh.Http.post_stream(url, headers, JSON.encode!(body), on_data, deadline)
    {_buf, st} = Process.delete(key)

    # failures return {:error, {kind, msg}, meta}; meta.state is the partial stream state (providers use it to recover the
    # usage of a failed attempt), meta.retryable / meta.retry_after_ms mark a retryable 429
    case result do
      :ok -> {:ok, st}
      {:error, :timeout} ->
        # overall deadline -> :timeout (final); an idle stream (no data for the idle window, 300 s) is retryable, as in pi
        if Kh.Util.now_ms() >= deadline,
          do: {:error, {:timeout, "no response before deadline or idle timeout"}, %{state: st}},
          else: {:error, {:transient, "idle timeout: no data for #{div(Application.get_env(:kh, :idle_ms, 300_000), 1000)} s"}, %{state: st}}

      {:error, {:http, status, resp, hdrs}} ->
        msg = "HTTP #{status}: #{Kh.Util.clip(Kh.Util.utf8(resp), 500)}"

        # a per-minute 429 is retried (honouring Retry-After); quota / usage-limit 429s stay final
        if status == 429 and not Regex.match?(@non_retryable, msg),
          do: {:error, {:rate_limit, msg}, %{state: st, retryable: true, retry_after_ms: retry_after_ms(hdrs)}},
          else: {:error, {classify(status), msg}, %{state: st}}

      {:error, {:network, reason}} -> {:error, {:transient, "network: #{reason}"}, %{state: st}}
    end
  end

  defp safe_event(data, st, started, handle) do
    try do
      decoded = if data == "[DONE]", do: {:ok, %{}}, else: JSON.decode(data)
      case decoded do
        {:ok, %{"type" => type, "delta" => delta}} when type in ["response.output_text.delta", "response.reasoning_summary_text.delta", "response.function_call_arguments.delta"] and not is_binary(delta) -> malformed(st)
        {:ok, %{} = frame} ->
          if Map.has_key?(frame, "usage") and not (is_nil(frame["usage"]) or is_map(frame["usage"])),
            do: malformed(st), else: handle.(data, st, started)
        _ -> malformed(st)
      end
    rescue
      _ -> malformed(st)
    catch
      _, _ -> malformed(st)
    end
  end

  defp malformed(st) do
    st
    |> Map.put(:error, st[:error] || "stream ended before a terminal response event: malformed provider event")
    |> Map.update(:bad_frames, 1, &(&1 + 1))
  end

  def safe_result(fun, failed_usage) do
    try do
      r = fun.()
      valid = is_binary(r.text) and (r.reasoning == nil or is_binary(r.reasoning)) and
        is_list(r.tool_calls) and valid_usage?(r.usage) and
        Enum.all?(r.tool_calls, fn c -> is_binary(c.id) and c.id != "" and is_binary(c.name) and c.name != "" and is_binary(c.args_raw) end)
      if valid, do: {:ok, r}, else: error({:transient, "malformed provider stream result"}, %{}, failed_usage)
    rescue
      _ -> error({:transient, "malformed provider stream result"}, %{}, failed_usage)
    catch
      _, _ -> error({:transient, "malformed provider stream result"}, %{}, failed_usage)
    end
  end

  def safe_usage(fun) do
    try do
      u = fun.()
      if valid_usage?(u), do: u, else: nil
    rescue
      _ -> nil
    end
  end

  defp valid_usage?(u) when is_map(u), do: Enum.all?([:input, :cached_input, :cache_write, :output, :reasoning], fn key -> v = u[key]; is_integer(v) and v >= 0 end)
  defp valid_usage?(_), do: false

  defp retry_after_ms(hdrs) do
    v = Enum.find_value(hdrs, fn {k, v} -> if String.downcase(to_string(k)) == "retry-after", do: to_string(v) end)

    case v && Integer.parse(v) do
      {s, _} when s >= 0 -> min(s * 1000, 120_000)
      _ -> nil
    end
  end

  @doc "Provider error return: drops the partial state from meta and attaches `usage` (the failed attempt's usage) when known."
  def error(err, meta, usage) do
    meta = Map.delete(meta, :state)
    meta = if usage, do: Map.put(meta, :usage, usage), else: meta
    if meta == %{}, do: {:error, err}, else: {:error, err, meta}
  end

  @doc "Kind for an error message found inside a 200 stream: :transient when pi would retry it, else :fatal."
  def classify_stream_error(msg) when is_binary(msg) do
    cond do
      Regex.match?(@non_retryable, msg) -> :fatal
      Regex.match?(@retryable, msg) -> :transient
      true -> :fatal
    end
  end

  defp classify(429), do: :rate_limit
  defp classify(s) when s in [401, 403], do: :auth
  defp classify(s) when s >= 500 or s in [408, 409, 425], do: :transient
  defp classify(_), do: :fatal
end
