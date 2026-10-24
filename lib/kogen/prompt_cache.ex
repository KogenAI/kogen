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

    # Older checkpoints suppressed retired prompt_cache_options. That refusal
    # says nothing about the routing key introduced by this implementation.
    state =
      if provider == "chatgpt" and state[:control] != "prompt_cache_key",
        do: Map.merge(state, %{control: "prompt_cache_key", unsupported: false}),
        else: state

    {input, contract} = blocks(input)

    body =
      if provider == "chatgpt" and
           Regex.match?(
             ~r/^gpt-(?:5\.(?:[6-9]|[1-9][0-9]+)(?:$|-)|(?:[6-9]|[1-9][0-9]+)(?:$|\.|-))/,
             model
           ),
         do: %{"input" => [%{"role" => "developer", "content" => [block(policy)]} | input]},
         else: %{"instructions" => policy, "input" => input}

    body =
      if provider in ["chatgpt", "supergrok"] and not state.unsupported,
        do: Map.put(body, "prompt_cache_key", state.id),
        else: body

    meta = %{
      conversation_id: state.id,
      cache: %{
        configured_mode: if(provider == "anthropic", do: "ephemeral"),
        configured_ttl: nil,
        applied_mode: nil,
        applied_ttl: nil,
        status:
          if(state.unsupported,
            do: "unsupported",
            else: if(provider == "anthropic", do: "requested", else: "unknown")
          ),
        boundaries: if(provider == "anthropic", do: ["system[0]", "conversation"], else: []),
        comparison_response_id: nil,
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

  def contract_blocks(stable, dynamic), do: [block(stable), block(dynamic)]

  defp blocks([%{"content" => content} = first | rest]) when is_list(content) do
    case content do
      [%{"type" => "input_text", "text" => stable} | suffix] ->
        {[Map.put(first, "content", [block(stable) | suffix]) | rest], stable}

      _ ->
        {[first | rest], nil}
    end
  end

  defp blocks([%{"content" => text} = first | rest]) when is_binary(text),
    do: {[Map.put(first, "content", [block(text)]) | rest], text}

  defp blocks(input), do: {input, nil}

  defp block(text), do: %{"type" => "input_text", "text" => text}

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
