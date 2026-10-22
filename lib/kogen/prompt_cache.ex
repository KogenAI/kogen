defmodule Kogen.PromptCache do
  @moduledoc "Responses cache policy and bounded local-byte evidence; never continuation authority."
  def fingerprint(nil), do: nil

  def fingerprint(text) when is_binary(text),
    do: %{
      sha256: Base.encode16(:crypto.hash(:sha256, text), case: :lower),
      bytes: byte_size(text)
    }

  def fingerprint(value), do: fingerprint(JSON.encode!(value))

  def prepare(model, policy, input, tools, provider \\ "chatgpt") do
    key =
      fingerprint([
        provider,
        model,
        Process.get(:provider_conversation_scope),
        Process.get(:provider_working_window),
        policy,
        tools,
        contract_identity(input)
      ]).sha256

    states = Process.get(:prompt_cache_states, %{})

    state =
      Map.get(states, key, %{
        id: Kogen.tmp_path("conversation") |> Path.basename(),
        unsupported: false,
        response: nil
      })

    supported =
      provider == "chatgpt" and
        Regex.match?(
          ~r/^gpt-(?:5\.(?:[6-9]|[1-9][0-9]+)(?:$|-)|(?:[6-9]|[1-9][0-9]+)(?:$|\.|-))/,
          model
        )

    enabled = supported and not state.unsupported
    {input, contract} = blocks(input, enabled)
    developer = %{"role" => "developer", "content" => [block(policy, enabled)]}
    options = %{"mode" => "implicit", "ttl" => "30m"}

    options =
      if state.response,
        do: Map.put(options, "comparison_response_id", state.response),
        else: options

    body =
      if supported,
        do: %{"input" => [developer | input]},
        else: %{"instructions" => policy, "input" => input}

    body = if enabled, do: Map.put(body, "prompt_cache_options", options), else: body

    body =
      if provider == "supergrok" and not state.unsupported,
        do: Map.put(body, "prompt_cache_key", state.id),
        else: body

    meta = %{
      conversation_id: state.id,
      cache: %{
        configured_mode: if(enabled, do: "implicit"),
        configured_ttl: if(enabled, do: "30m"),
        applied_mode: nil,
        applied_ttl: nil,
        status:
          if(enabled,
            do: "requested",
            else:
              if(provider == "chatgpt" and (supported or String.starts_with?(model, "gpt-5.")),
                do: "unsupported",
                else: "unknown"
              )
          ),
        boundaries:
          if(enabled,
            do:
              if(contract,
                do: ["input[0].content[0]", "input[1].content[0]"],
                else: ["input[0].content[0]"]
              ),
            else: []
          ),
        comparison_response_id: if(enabled, do: state.response),
        diagnostics: nil
      },
      fingerprints: %{
        policy: fingerprint(policy),
        tools: fingerprint(tools),
        schema:
          fingerprint(
            Enum.map(tools, &Map.take(&1, ~w(parameters output_schema response_format)))
          ),
        contract: fingerprint(contract),
        prefix: fingerprint([policy, tools, contract])
      }
    }

    Process.put(:prompt_cache_states, Map.put(states, key, state))
    Process.put(:prompt_cache_current, {key, state, meta})
    body
  end

  defp contract_identity([%{"content" => [%{"text" => text} | _], "role" => role} | _]),
    do: [role, text]

  defp contract_identity(input), do: List.first(input)

  def contract_blocks(stable, dynamic), do: [block(stable, false), block(dynamic, false)]

  defp blocks([%{"content" => content} = first | rest], enabled) when is_list(content) do
    case content do
      [%{"type" => "input_text", "text" => stable} | suffix] ->
        {[Map.put(first, "content", [block(stable, enabled) | suffix]) | rest], stable}

      _ ->
        {[first | rest], nil}
    end
  end

  defp blocks([%{"content" => text} = first | rest], enabled) when is_binary(text),
    do: {[Map.put(first, "content", [block(text, enabled)]) | rest], text}

  defp blocks(input, _), do: {input, nil}

  defp block(text, enabled) do
    b = %{"type" => "input_text", "text" => text}
    if enabled, do: Map.put(b, "prompt_cache_breakpoint", %{"mode" => "explicit"}), else: b
  end

  def unsupported do
    {key, state, meta} = Process.get(:prompt_cache_current)
    state = %{state | unsupported: true}
    Process.put(:prompt_cache_states, Map.put(Process.get(:prompt_cache_states, %{}), key, state))

    Process.put(
      :prompt_cache_current,
      {key, state, %{meta | cache: %{meta.cache | status: "unsupported"}}}
    )
  end

  def complete(response) do
    {key, state, _} = Process.get(:prompt_cache_current)
    state = %{state | response: identifier(response["id"]) || state.response}
    Process.put(:prompt_cache_states, Map.put(Process.get(:prompt_cache_states, %{}), key, state))
  end

  def identifier(value) when is_binary(value) and byte_size(value) in 1..256, do: value
  def identifier(_), do: nil

  def diagnostics(value) when is_map(value) do
    if byte_size(JSON.encode!(value)) <= 2048, do: classified_diagnostics(value), else: nil
  end

  def diagnostics(_), do: nil

  defp classified_diagnostics(value) do
    type =
      if value["type"] in ~w(cache_hit cache_miss comparison_response_not_found unavailable),
        do: value["type"],
        else: "other"

    reason =
      if value["reason"] in ~w(tools_changed policy_changed prefix_changed schema_changed contract_changed unavailable expired),
        do: value["reason"],
        else: "other"

    counts =
      for {k, v} <- value,
          k in ~w(comparison_reusable_tokens cache_missed_tokens cache_hit_tokens),
          is_integer(v) and v >= 0,
          into: %{},
          do: {k, v}

    Map.merge(counts, %{type: type, reason: reason})
  end
end
