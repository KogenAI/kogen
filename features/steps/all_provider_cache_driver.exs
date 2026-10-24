[config_path, receipt] = System.argv()
c = JSON.decode!(File.read!(config_path))
a = c["authority"]
:persistent_term.put(:kogen_caller, %{env: %{"HOME" => c["home"], "KOGEN_PROVIDER_URL" => c["url"]}, install_root: File.cwd!(), cwd: File.cwd!()})
System.put_env("RELEASE_ROOT", c["home"])
File.write!(Path.join(c["home"], "VERSION"), "kogen local cache fixture\n")
role = %{provider: c["provider"], model: c["model"], effort: c["effort"]}
tools = [%{"type" => "function", "name" => "read_file", "description" => "Read exact text", "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"], "additionalProperties" => false}, "strict" => true}]
base = [%{"role" => "user", "content" => Kogen.PromptCache.contract_blocks(a["contract"], "dynamic suffix")}]
Process.put(:provider_conversation_scope, "fixture-build")
Kogen.ShapeEvidence.start(Path.join(c["home"], "evidence"))
call = fn input ->
  try do
    scope = Process.get(:provider_conversation_scope)
    r = Kogen.ShapeEvidence.provider("shape", nil, "cache-fixture", [], role, fn ->
      Process.put(:provider_conversation_scope, scope)
      Kogen.ChatGPT.respond(role, a["policy"], input, tools, single_attempt: c["single"] == true, response_budget_ms: 10000)
    end)
    %{outcome: "completed", value: r}
  rescue
    e in Kogen.Error -> %{outcome: e.class <> "/" <> e.reason, value: nil}
  end
end
result = if c["mode"] == "budget" do
  render = fn text -> Kogen.ChatGPT.request_body(role, a["policy"], [%{"role" => "user", "content" => text}], tools) end
  overhead = byte_size(JSON.encode!(render.("")))
  bodies = Enum.map([a["limit"] - 1, a["limit"], a["limit"] + 1], &render.(String.duplicate("x", &1 - overhead)))
  measured = Enum.map(bodies, &Kogen.WorkingContext.measure/1)
  results = Enum.map([a["limit"], a["limit"] + 1], fn n -> call.([%{"role" => "user", "content" => String.duplicate("x", n - overhead)}]) end)
  %{bytes: Enum.map(measured, & &1.rendered_bytes), fits: Enum.map(measured, & &1.fits), reserves: Enum.map(measured, & &1.output_reserve_tokens), results: results}
else
  first = call.(base)
  results = if first.value do
    replay = Enum.map(first.value.items, &Kogen.Shape.replay_item/1) |> Enum.reject(&is_nil/1)
    calls = Enum.filter(first.value.items, &(&1["type"] == "function_call"))
    outputs = Enum.map(calls, &Kogen.Shape.output(&1, a["tool_result"] <> ":" <> &1["call_id"]))
    saved = :erlang.term_to_binary({Process.get(:prompt_cache_states), base ++ replay ++ outputs})
    Process.delete(:prompt_cache_states)
    {states, next} = :erlang.binary_to_term(saved, [:safe])
    Process.put(:prompt_cache_states, states)
    second = call.(next)
    if c["mode"] == "refusal" do
      [first, second]
    else
      Process.put(:provider_conversation_scope, "fixture-independent-review")
      third = call.(base)
      Process.put(:provider_conversation_scope, "fixture-build")
      Process.put(:provider_working_window, 1)
      [first, second, third, call.(base)]
    end
  else
    [first]
  end
  %{results: results}
end
rows = File.read!(Path.join(c["home"], "evidence/events.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
File.write!(receipt, JSON.encode!(Map.put(result, :rows, rows)))
