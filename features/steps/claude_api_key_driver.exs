[config_path, receipt] = System.argv()
c = JSON.decode!(File.read!(config_path))
:persistent_term.put(:kogen_caller, %{
  env: %{"HOME" => c["home"], "KOGEN_PROVIDER_URL" => c["url"]},
  install_root: File.cwd!(),
  cwd: File.cwd!()
})
System.put_env("RELEASE_ROOT", c["home"])
File.write!(Path.join(c["home"], "VERSION"), "kogen local protocol fixture\n")
role = %{provider: c["provider"] || "anthropic", model: c["model"] || "claude-opus-5-5", effort: c["effort"] || "high"}
tools = [%{"type" => "function", "name" => "read_file", "description" => "Read local text", "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"], "additionalProperties" => false}, "strict" => true}]
base = [%{"role" => "user", "content" => "LOCAL_NATIVE_CONTRACT"}]
result = cond do
  c["mode"] == "config" ->
    try do
      config = Kogen.Config.parse!(File.read!(c["yaml"]), c["yaml"])
      %{outcome: "parsed", omitted_legacy: c["provider"] != "omitted" or not Map.has_key?(config.models["shape"], :provider)}
    rescue
      _ in Kogen.Error -> %{outcome: "refused"}
    end
  c["mode"] == "budget" ->
    render = fn s -> Kogen.ChatGPT.request_body(role, "LOCAL_POLICY", [%{"role" => "user", "content" => s}], tools) end
    overhead = byte_size(JSON.encode!(render.("")))
    bodies = Enum.map([524287, 524288, 524289], &render.(String.duplicate("x", &1 - overhead)))
    ms = Enum.map(bodies, &Kogen.WorkingContext.measure/1)
    %{body_is_messages: Enum.all?(bodies, &(is_list(&1["messages"]) and not Map.has_key?(&1, "input"))), bytes: Enum.map(ms, & &1.rendered_bytes), fits: Enum.map(ms, & &1.fits), reserve: Enum.map(ms, & &1.output_reserve_tokens)}
  true ->
    Process.put(:provider_conversation_scope, "local-build")
    input = if c["image"], do: base ++ [%{"type" => "function_call_output", "call_id" => "image", "output" => [%{"type" => "input_text", "text" => "{}"}, %{"type" => "input_image", "image_url" => "data:image/png;base64,synthetic"}]}], else: base
    invoke = fn items ->
      started = System.monotonic_time(:millisecond)
      try do
        v = Kogen.ChatGPT.respond(role, "LOCAL_POLICY", items, tools, response_budget_ms: c["budget"] || 15000)
        %{outcome: "completed", value: v, metadata: Process.get(:provider_attempt_metadata), elapsed: System.monotonic_time(:millisecond) - started}
      rescue
        e in Kogen.Error -> %{outcome: e.class <> "/" <> e.reason, detail: e.detail, value: nil, metadata: Process.get(:provider_attempt_metadata), elapsed: System.monotonic_time(:millisecond) - started}
      end
    end
    first = invoke.(input)
    calls = if first.value, do: Enum.filter(first.value.items, &(&1["type"] == "function_call")), else: []
    results = if calls != [] do
      replay = Enum.map(first.value.items, &Kogen.Shape.replay_item/1) |> Enum.reject(&is_nil/1)
      outputs = Enum.map(calls, &Kogen.Shape.output(&1, "LOCAL_TOOL_RESULT:" <> &1["call_id"]))
      next = input ++ replay ++ outputs
      saved = :erlang.term_to_binary(next)
      second = invoke.(:erlang.binary_to_term(saved, [:safe]))
      Process.put(:provider_conversation_scope, "local-independent-review")
      [first, second, invoke.(base)]
    else
      [first]
    end
    %{results: results}
end
File.write!(receipt, JSON.encode!(result))
