defmodule Kh.Provider.Responses do
  @moduledoc "ChatGPT subscription Responses API streaming. Requests are stateless and replay encrypted reasoning."
  @behaviour Kh.Provider

  @impl true
  def stream(model, system, messages, tools, opts) do
    body = build_body(model, system, messages, tools, opts)
    url = String.trim_trailing(opts.base_url, "/") <> "/responses"
    init = %{text: [], reasoning: [], items: [], completed: nil, ttft: nil, error: nil, bad_frames: 0, failed_usage: nil, sequence_hashes: %{}}

    case Kh.Provider.run_sse(url, headers(model, opts), body, opts.deadline, init, &handle/3) do
      {:ok, %{error: err} = st} when not is_nil(err) -> Kh.Provider.error({Kh.Provider.classify_stream_error(err), err}, %{}, failed_usage(st))
      {:ok, %{completed: nil} = st} -> Kh.Provider.error({:transient, "stream ended before a terminal response event"}, %{}, failed_usage(st))
      {:ok, st} -> Kh.Provider.safe_result(fn -> finish(st) end, failed_usage(st))
      {:error, e, meta} -> Kh.Provider.error(e, meta, failed_usage(meta.state))
    end
  end

  # tokens billed on an attempt that failed: response.failed carries a usage block
  defp failed_usage(%{failed_usage: u}) when is_map(u),
    do: Kh.Provider.safe_usage(fn -> usage(u) end)

  defp failed_usage(%{completed: %{"usage" => u}}) when is_map(u),
    do: Kh.Provider.safe_usage(fn -> usage(u) end)
  defp failed_usage(_), do: nil

  def headers(%{chatgpt: true}, opts) do
    [
      {"authorization", "Bearer " <> opts.api_key},
      {"chatgpt-account-id", opts.account_id || ""},
      {"openai-beta", "responses=experimental"},
      {"originator", "kh"},
      {"accept", "text/event-stream"},
      {"session_id", opts.session_id},
      {"user-agent", "kh/0.1"}
    ]
  end

  def headers(_model, _opts), do: raise(ArgumentError, "only the ChatGPT subscription Responses provider is retained")

  def build_body(model, system, messages, tools, opts) do
    body = %{
      "model" => model.id,
      "instructions" => system,
      "input" => convert(messages),
      "stream" => true,
      "store" => false,
      "prompt_cache_key" => String.slice(opts.session_id, 0, 64)
    }

    body =
      if tools == [],
        do: body,
        else:
          Map.put(
            body,
            "tools",
            Enum.map(tools, fn t ->
              %{"type" => "function", "name" => t.name, "description" => t.description, "parameters" => t.parameters, "strict" => false}
            end)
          )

    body =
      case opts[:effort_sent] do
        nil ->
          body

        e ->
          body |> Map.put("reasoning", %{"effort" => e, "summary" => "auto"}) |> Map.put("include", ["reasoning.encrypted_content"])
      end

    cond do
      # the ChatGPT backend rejects max_output_tokens; it also wants an explicit tool_choice
      model[:chatgpt] ->
        Map.merge(body, %{"text" => %{"verbosity" => "medium"}, "tool_choice" => "auto", "parallel_tool_calls" => true})

      opts[:max_output] ->
        Map.put(body, "max_output_tokens", opts.max_output)

      true ->
        body
    end
  end

  def convert(messages) do
    Enum.flat_map(messages, fn
      %{role: :user, text: t} ->
        [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => t}]}]

      %{role: :assistant, items: items} when is_list(items) ->
        items

      %{role: :assistant} = m ->
        text = if m.text in [nil, ""], do: [], else: [%{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => m.text}]}]
        text ++ Enum.map(m.tool_calls, &%{"type" => "function_call", "call_id" => &1.id, "name" => &1.name, "arguments" => &1.args_raw})

      %{role: :tool} = m ->
        [%{"type" => "function_call_output", "call_id" => m.call_id, "output" => m.content}]
    end)
  end

  defp handle(data, st, started) do
    case JSON.decode(data) do
      {:ok, %{"sequence_number" => n} = event} when is_integer(n) and n >= 0 ->
        digest = :crypto.hash(:sha256, JSON.encode!(event))
        case Map.fetch(st.sequence_hashes, n) do
          {:ok, ^digest} -> st
          {:ok, _} -> %{st | error: "stream ended before a terminal response event: conflicting sequence number"}
          :error -> handle_raw(data, %{st | sequence_hashes: Map.put(st.sequence_hashes, n, digest)}, started)
        end
      _ -> handle_raw(data, st, started)
    end
  end

  defp handle_raw(data, st, started) do
    case JSON.decode(data) do
      {:ok, %{"type" => "response.output_text.delta", "delta" => d}} ->
        %{st | text: [d | st.text], ttft: st.ttft || Kh.Util.now_ms() - started}

      {:ok, %{"type" => "response.reasoning_summary_text.delta", "delta" => d}} ->
        %{st | reasoning: [d | st.reasoning], ttft: st.ttft || Kh.Util.now_ms() - started}

      {:ok, %{"type" => "response.function_call_arguments.delta"}} ->
        %{st | ttft: st.ttft || Kh.Util.now_ms() - started}

      {:ok, %{"type" => "response.output_item.done", "item" => item}} ->
        # A repeated item id (or exact item without an id) must not add the item twice.
        key = item["id"] || item
        if key && Enum.any?(st.items, &((&1["id"] || &1) == key)), do: st, else: %{st | items: [item | st.items]}

      {:ok, %{"type" => t, "response" => r}} when t in ["response.completed", "response.incomplete"] ->
        %{st | completed: r}

      {:ok, %{"type" => "response.failed", "response" => r}} ->
        %{st | error: "response failed: " <> Kh.Util.clip(inspect(r["error"] || r), 500), failed_usage: r["usage"]}

      {:ok, %{"type" => "error"} = e} ->
        %{st | error: "provider error: " <> Kh.Util.clip(inspect(e["error"] || e), 500)}

      {:ok, %{"error" => e}} when not is_nil(e) ->
        %{st | error: "provider error: " <> Kh.Util.clip(inspect(e), 500)}

      _ ->
        %{st | bad_frames: st.bad_frames + if(match?({:ok, _}, JSON.decode(data)), do: 0, else: 1)}
    end
  end

  defp finish(st) do
    r = st.completed || %{}
    reported_usage = usage(r["usage"])
    items = if is_list(r["output"]) and r["output"] != [], do: r["output"], else: Enum.reverse(st.items)

    calls =
      for %{"type" => "function_call"} = i <- items do
        %{id: i["call_id"], name: i["name"], args_raw: if(i["arguments"] in [nil, ""], do: "{}", else: i["arguments"])}
      end

    text =
      items
      |> Enum.filter(&(&1["type"] == "message"))
      |> Enum.flat_map(&(&1["content"] || []))
      |> Enum.filter(&(&1["type"] == "output_text"))
      |> Enum.map_join(& &1["text"])

    text = if text == "", do: st.text |> Enum.reverse() |> Enum.join(), else: text

    %{
      text: text,
      reasoning: if(st.reasoning == [], do: nil, else: st.reasoning |> Enum.reverse() |> Enum.join()),
      tool_calls: calls,
      usage: reported_usage || Kh.Provider.empty_usage(),
      usage_reported: not is_nil(reported_usage),
      bad_frames: st.bad_frames,
      stop: r["status"] || if(calls == [], do: "stop", else: "tool_calls"),
      items: items,
      response_id: r["id"],
      ttft_ms: st.ttft
    }
  end

  defp complete_usage?(usage) when is_map(usage) do
    nonnegative_integer?(usage["input_tokens"]) and
      nonnegative_integer?(usage["output_tokens"]) and
      nonnegative_integer?(get_in(usage, ["input_tokens_details", "cached_tokens"])) and
      nonnegative_integer?(get_in(usage, ["output_tokens_details", "reasoning_tokens"]))
  end

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  def usage(nil), do: nil

  def usage(u) when is_map(u) do
    if complete_usage?(u), do: normalized_usage(u)
  end

  def usage(_), do: nil

  defp normalized_usage(u) do
    input = u["input_tokens"] || 0
    cached = get_in(u, ["input_tokens_details", "cached_tokens"]) || 0

    %{
      input: max(0, input - cached),
      cached_input: cached,
      cache_write: 0,
      output: u["output_tokens"] || 0,
      reasoning: get_in(u, ["output_tokens_details", "reasoning_tokens"]) || 0
    }
  end
end
