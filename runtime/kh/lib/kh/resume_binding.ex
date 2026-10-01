defmodule Kh.ResumeBinding do
  @moduledoc false

  @doc "Freeze request identity without credentials or process-local state."
  def snapshot(st) do
    %{
      model_id: st.o.model.id,
      api: Atom.to_string(st.o.model.api),
      chatgpt: st.o.model[:chatgpt] == true,
      cwd: st.o.cwd,
      session_id: st.o.session_id,
      system: st.system,
      tools: st.tools,
      effort_sent: st.sent,
      features: st.o.features |> MapSet.to_list() |> Enum.sort(),
      tools_allow: st.o[:tools],
      compact_at: st.o[:compact_at],
      max_total_tokens: st.o[:max_total_tokens],
      max_turns: st.o.max_turns,
      max_output: st.o[:max_output]
    }
  end

  def restore(o, nil), do: o
  def restore(o, b) do
    if {o.model.id, Atom.to_string(o.model.api), o.model[:chatgpt] == true, o.cwd} !=
         {b.model_id, b.api, b.chatgpt, b.cwd} do
      raise ArgumentError, "checkpoint model, API, provider or working directory does not match"
    end
    o
    |> Map.put(:system_prompt, b.system)
    |> Map.put(:context_files, false)
    |> Map.put(:session_id, b.session_id)
    |> Map.put(:features, MapSet.new(b.features))
    |> Map.put(:tools, b.tools_allow)
    |> Map.put(:max_output, b.max_output)
    |> Map.put(:compact_at, b.compact_at)
    |> Map.put(:max_total_tokens, b.max_total_tokens)
  end

  def decode(nil), do: nil
  def decode(m) do
    %{
      model_id: m["model_id"], api: m["api"], chatgpt: m["chatgpt"], cwd: m["cwd"],
      session_id: m["session_id"], system: m["system"], effort_sent: m["effort_sent"],
      features: m["features"], tools_allow: m["tools_allow"], max_output: m["max_output"],
      compact_at: m["compact_at"], max_total_tokens: m["max_total_tokens"], max_turns: m["max_turns"],
      tools: Enum.map(m["tools"], fn t -> %{name: t["name"], description: t["description"], parameters: t["parameters"]} end)
    }
  end
end
