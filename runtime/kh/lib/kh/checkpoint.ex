defmodule Kh.Checkpoint.Error do
  defexception message: "cannot persist checkpoint"
end

defmodule Kh.Checkpoint do
  @moduledoc "Private atomic transcript storage for headless native recovery."

  @usage_keys [:input, :cached_input, :cache_write, :output, :reasoning]
  def validate!(cp) do
    valid = nonnegative?(cp.turn) and cost?(cp.cost) and
      usage?(cp.usage) and usage?(cp.failed_usage) and is_list(cp.messages) and cp.messages != [] and
      Enum.all?(cp.messages, &message?/1) and
      Enum.all?([:last_ctx_tokens, :unreported, :elapsed_ms], fn k -> not Map.has_key?(cp, k) or nonnegative?(cp[k]) end) and
      (not Map.has_key?(cp, :resume_binding) or (is_binary(cp.resume_binding) and byte_size(cp.resume_binding) == 64)) and
      (not Map.has_key?(cp, :runtime_provider) or cp.runtime_provider in ["chatgpt-subscription", "scripted-offline"]) and
      (not Map.has_key?(cp, :account_id_hash) or is_nil(cp.account_id_hash) or (is_binary(cp.account_id_hash) and byte_size(cp.account_id_hash) == 64)) and
      Enum.all?([:truncated, :overflowed], fn k -> not Map.has_key?(cp, k) or is_boolean(cp[k]) end) and
      (not Map.has_key?(cp, :last_text) or is_binary(cp.last_text)) and phase?(cp) and binding?(cp[:binding])
    if not valid, do: raise(ArgumentError, "invalid or unsupported checkpoint")
    cp
  end

  defp nonnegative?(n), do: is_integer(n) and n >= 0
  defp cost?(nil), do: true
  defp cost?(n), do: is_number(n) and n >= 0
  defp usage?(u), do: is_map(u) and Enum.sort(Map.keys(u)) == Enum.sort(@usage_keys) and Enum.all?(Map.values(u), &nonnegative?/1)
  defp call?(c), do: is_map(c) and is_binary(c[:id]) and c.id != "" and is_binary(c[:name]) and c.name != "" and is_binary(c[:args_raw])
  defp message?(%{role: :user, text: text}), do: is_binary(text)
  defp message?(%{role: :tool} = m), do: is_binary(m[:call_id]) and is_binary(m[:name]) and is_binary(m[:content]) and is_boolean(m[:is_error])
  defp message?(%{role: :assistant} = m), do: is_binary(m[:text]) and (is_nil(m[:reasoning]) or is_binary(m[:reasoning])) and (is_nil(m[:items]) or is_list(m[:items])) and is_list(m[:tool_calls]) and Enum.all?(m.tool_calls, &call?/1)
  defp message?(_), do: false
  # Unbound legacy snapshots remain valid for the codec; Kh.Session requires a bound snapshot.
  defp phase?(%{phase: p, pending: pending, in_flight: flight} = cp) when p in ["ready", "tools", "complete"] and is_list(pending) do
    Enum.all?(pending, &call?/1) and length(Enum.uniq_by(pending, & &1.id)) == length(pending) and
      case p do
        "ready" -> pending == [] and flight == nil
        "complete" -> pending == [] and flight == nil and cp[:terminal_status] in ["ok", "error"] and (cp[:terminal_error] == nil or is_binary(cp.terminal_error))
        "tools" -> flight == nil or (pending != [] and flight == hd(pending).id)
      end
  end
  defp phase?(cp), do: not Map.has_key?(cp, :phase) and cp[:binding] == nil
  defp binding?(nil), do: true
  defp binding?(b) when is_map(b) do
    Enum.all?([:model_id, :cwd, :session_id, :system], &is_binary(b[&1])) and b.model_id != "" and
      b.api in ["chat", "responses"] and is_boolean(b[:chatgpt]) and Path.type(b.cwd) == :absolute and
      is_list(b[:tools]) and Enum.all?(b.tools, fn t -> is_binary(t[:name]) and is_binary(t[:description]) and is_map(t[:parameters]) end) and
      is_list(b[:features]) and Enum.all?(b.features, &is_binary/1) and
      (b[:tools_allow] == nil or (is_list(b.tools_allow) and Enum.all?(b.tools_allow, &is_binary/1))) and
      (b[:effort_sent] == nil or is_binary(b.effort_sent)) and
      is_integer(b[:max_turns]) and b.max_turns > 0 and
      Enum.all?([:max_output, :max_total_tokens], fn k -> b[k] == nil or (is_integer(b[k]) and b[k] > 0) end) and
      (b[:compact_at] == nil or (is_number(b.compact_at) and b.compact_at > 0 and b.compact_at <= 1))
  end
  defp binding?(_), do: false

  def load(path) do
    with {:ok, json} <- File.read(path) do
      try do
        {:ok, Kh.Agent.decode_checkpoint(json)}
      rescue
        _ -> {:error, "invalid or unsupported checkpoint"}
      end
    else
      {:error, reason} -> {:error, "cannot read checkpoint: #{:file.format_error(reason)}"}
    end
  end

  def save(path, checkpoint) do
    path = Path.expand(path)
    temp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    # exclusive+0600 at creation: never make transcript bytes world-readable, including the temporary file.
    try do
      with {:ok, fd} <- :file.open(String.to_charlist(temp), [:write, :binary, :exclusive]) do
        result =
          try do
            with :ok <- File.chmod(temp, 0o600),
                 :ok <- :file.write(fd, Kh.Agent.encode_checkpoint(checkpoint)),
                 :ok <- :file.sync(fd) do
              :ok
            end
          after
            :file.close(fd)
          end

        with :ok <- result, :ok <- File.rename(temp, path), do: :ok
      end
    after
      File.rm(temp)
    end
  end

  def save!(path, checkpoint) do
    case save(path, checkpoint) do
      :ok -> :ok
      {:error, reason} -> raise Kh.Checkpoint.Error, message: "cannot persist checkpoint: #{:file.format_error(reason)}"
    end
  end
end
