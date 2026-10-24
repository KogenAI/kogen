defmodule Kogen.Anthropic do
  @moduledoc "Kogen-owned Anthropic private key custody and native streaming Messages adapter."
  alias Kogen.{Bridge, Error, Lock}
  defp path, do: Path.join(Kogen.caller().env["HOME"], ".kogen/credentials/anthropic.json")
  defp fail(reason, detail), do: Error.raise!("provider", reason, detail, 4)

  defp valid?(s),
    do: is_binary(s) and s != "" and String.valid?(s) and not Regex.match?(~r/\p{Cc}/u, s)

  defp read do
    case File.read(path()) do
      {:error, :enoent} ->
        nil

      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"provider" => "anthropic", "api_key" => key}} ->
            if valid?(key) and String.trim(key) != "", do: key, else: :invalid

          _ ->
            :invalid
        end

      _ ->
        :invalid
    end
  end

  def status do
    text =
      case read() do
        nil -> "not signed in"
        :invalid -> "not signed in"
        _ -> "key saved (not verified)"
      end

    Bridge.puts("anthropic: " <> text)
    0
  end

  def require_login! do
    case read() do
      key when is_binary(key) -> key
      _ -> fail("login", "no usable Anthropic key; run kogen provider login anthropic")
    end
  end

  def login do
    Bridge.send_msg(%{type: "secret_input"})

    key =
      case Bridge.recv() do
        %{"type" => "secret_input", "ok" => true, "value" => value} ->
          # Trim surrounding whitespace and one terminating line ending, never internal controls.
          unless String.valid?(value),
            do: fail("login", "invalid Anthropic key input; saved login unchanged")

          value = String.replace(value, ~r/\r?\n\z/, "")

          if String.contains?(value, ["\n", "\r"]),
            do: fail("login", "invalid Anthropic key input; saved login unchanged")

          String.trim(value)

        %{"type" => "cancel", "signal" => sig} ->
          Bridge.cancelled(sig)

        _ ->
          fail("login", "Anthropic input interrupted; saved login unchanged")
      end

    if key == "", do: fail("login", "no Anthropic key supplied; saved login unchanged")

    unless valid?(key),
      do: fail("login", "invalid Anthropic key input; saved login unchanged")

    dir = Path.dirname(path())
    lock = Path.rootname(path()) <> ".lock"
    tmp = path() <> "." <> Base.encode16(:crypto.strong_rand_bytes(8))

    try do
      File.mkdir_p!(dir)
      File.chmod!(Path.dirname(dir), 0o700)
      File.chmod!(dir, 0o700)

      case Lock.acquire(lock) do
        {:held, _} ->
          fail("login", "Anthropic login is locked; saved login unchanged")

        _ ->
          try do
            File.write!(tmp, "", [:exclusive])
            File.chmod!(tmp, 0o600)
            File.write!(tmp, JSON.encode!(%{provider: "anthropic", api_key: key}))
            Bridge.check_cancel()
            File.rename!(tmp, path())
          after
            Lock.release(lock)
          end
      end
    rescue
      _ -> fail("login", "could not save Anthropic key; saved login unchanged")
    after
      File.rm(tmp)
    end

    Bridge.puts("anthropic: key saved (not verified)")
    0
  end

  def request_body(role, policy, input, tools) do
    if image?(input),
      do:
        fail(
          "unsupported_capability",
          "Anthropic images are unsupported; use external image preparation and pixel-review handoff"
        )

    Kogen.PromptCache.prepare(role.model, policy, input, tools, "anthropic")

    body = %{
      "model" => role.model,
      "stream" => true,
      "max_tokens" => 128_000,
      "thinking" => %{"type" => "adaptive"},
      "output_config" => %{"effort" => role.effort},
      "system" => [
        %{"type" => "text", "text" => policy, "cache_control" => %{"type" => "ephemeral"}}
      ],
      "cache_control" => %{"type" => "ephemeral"},
      "messages" => render(input)
    }

    if tools == [],
      do: body,
      else:
        Map.merge(body, %{
          "tool_choice" => %{"type" => "auto"},
          "tools" =>
            Enum.map(
              tools,
              &%{
                "name" => &1["name"],
                "description" => &1["description"],
                "input_schema" => &1["parameters"]
              }
            )
        })
  end

  defp image?(v) when is_list(v), do: Enum.any?(v, &image?/1)

  defp image?(v) when is_map(v),
    do: v["type"] == "input_image" or Enum.any?(Map.values(v), &image?/1)

  defp image?(_), do: false

  defp render(input) do
    {messages, _} =
      Enum.reduce(input, {[], MapSet.new()}, fn item, {messages, ids} ->
        cond do
          is_map(item["anthropic_message"]) ->
            raw = item["anthropic_message"]
            calls = for b <- raw["content"], b["type"] == "tool_use", do: b["id"]
            {messages ++ [raw], MapSet.union(ids, MapSet.new(calls))}

          item["type"] == "function_call" and MapSet.member?(ids, item["call_id"]) ->
            {messages, ids}

          item["type"] == "function_call_output" ->
            block = %{
              "type" => "tool_result",
              "tool_use_id" => item["call_id"],
              "content" => text(item["output"])
            }

            case List.last(messages) do
              %{"role" => "user", "content" => [%{"type" => "tool_result"} | _] = blocks} ->
                {List.replace_at(messages, -1, %{"role" => "user", "content" => blocks ++ [block]}),
                 ids}

              _ ->
                {messages ++ [%{"role" => "user", "content" => [block]}], ids}
            end

          item["role"] in ["user", "assistant"] ->
            {messages ++ [%{"role" => item["role"], "content" => text(item["content"])}], ids}

          true ->
            {messages, ids}
        end
      end)

    messages
  end

  defp text(v) when is_list(v), do: Enum.map(v, &%{"type" => "text", "text" => &1["text"]})
  defp text(v), do: v

  def transport(body, key, deadline) do
    base = Kogen.caller().env["KOGEN_PROVIDER_URL"] || "https://api.anthropic.com"
    headers = [{~c"x-api-key", String.to_charlist(key)}, {~c"anthropic-version", ~c"2026-10-21"}]

    case :httpc.request(
           :post,
           {String.to_charlist(base <> "/v1/messages"), headers, ~c"application/json", body},
           Keyword.put(Kogen.ChatGPT.http_opts(deadline), :autoredirect, false),
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, ref} ->
        try do
          collect(ref, key, deadline, [], "")
        after
          :httpc.cancel_request(ref)
        end

      {:error, _} ->
        {:transient, "Anthropic network failure"}
    end
  end

  defp collect(ref, key, deadline, chunks, tail) do
    Kogen.ChatGPT.remaining(deadline)

    receive do
      {:http, {^ref, :stream_start, headers}} ->
        capture_id(headers, key)
        collect(ref, key, deadline, chunks, tail)

      {:http, {^ref, :stream, chunk}} ->
        chunks = [chunk | chunks]
        frames = String.split(String.replace(tail <> chunk, "\r\n", "\n"), "\n\n")
        {tail, frames} = List.pop_at(frames, -1)

        if Enum.any?(frames, fn frame ->
             case decode_frame(frame) do
               {:ok, %{"type" => type}} -> type in ["message_stop", "error"]
               _ -> false
             end
           end) do
          complete(chunks, key, deadline)
        else
          collect(ref, key, deadline, chunks, tail)
        end

      {:http, {^ref, :stream_end, _}} ->
        complete(chunks, key, deadline)

      {:http, {^ref, {{_, status, _}, headers, bytes}}} ->
        capture_id(headers, key)
        Kogen.ChatGPT.remaining(deadline)
        diagnostic = http_failure(status, bytes, key)

        cond do
          status == 200 ->
            complete([bytes], key, deadline)

          status == 429 or status >= 500 ->
            {:transient,
             %{
               detail: "Anthropic temporary HTTP #{status}",
               provider_failure:
                 Map.new(diagnostic, fn
                   {:status, v} -> {"http_status", v}
                   {:type, v} -> {"type", v}
                 end)
             }}

          status == 401 ->
            {:unauthorized, diagnostic}

          true ->
            {:go_error,
             case status do
               404 -> "model_unavailable"
               413 -> "context_too_long"
               _ -> "refused"
             end, diagnostic}
        end

      {:http, {^ref, {:error, _}}} ->
        {:transient, "Anthropic network failure"}

      {:proto, %{"type" => "cancel", "signal" => sig}} ->
        Bridge.cancelled(sig)
    after
      Kogen.ChatGPT.remaining(deadline) ->
        fail("unavailable", "Anthropic response wait exceeded logical deadline")
    end
  end

  defp capture_id(headers, key) do
    Process.put(
      :provider_request_id,
      Enum.find_value(headers, fn {k, v} ->
        if String.downcase(to_string(k)) in ["request-id", "x-request-id"],
          do: safe_identifier(to_string(v), key)
      end)
    )
  end

  defp safe_identifier(v, key) when is_binary(v) do
    if not String.contains?(v, key) and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, v),
      do: Kogen.PromptCache.identifier(v)
  end

  defp safe_identifier(_, _), do: nil

  defp http_failure(status, bytes, key) do
    type =
      case JSON.decode(bytes) do
        {:ok, %{"error" => %{"type" => t}}}
        when t in ~w(invalid_request_error authentication_error billing_error permission_error not_found_error request_too_large rate_limit_error api_error overloaded_error) ->
          safe_identifier(t, key)

        _ ->
          nil
      end

    if type, do: %{status: status, type: type}, else: %{status: status}
  end

  defp complete(chunks, key, deadline) do
    Kogen.ChatGPT.remaining(deadline)

    case parse(chunks |> Enum.reverse() |> IO.iodata_to_binary()) do
      {:ok, result} ->
        {:ok,
         %{
           result
           | response_metadata:
               Map.new(result.response_metadata, fn {k, v} -> {k, safe_identifier(v, key)} end)
         }}

      other ->
        other
    end
  end

  defp decode_frame(frame) do
    lines = String.split(frame, "\n")

    name =
      Enum.find_value(lines, fn l ->
        if String.starts_with?(l, "event:"),
          do: String.trim(String.replace_prefix(l, "event:", ""))
      end)

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(String.replace_prefix(&1, "data:", "")))
      |> Enum.join("\n")

    cond do
      name != nil and
          name not in ~w(message_start content_block_start content_block_delta content_block_stop message_delta message_stop error) ->
        :ignore

      data == "" ->
        :ignore

      true ->
        case JSON.decode(data) do
          {:ok, %{"type" => type} = e} when name == nil or name == type -> {:ok, e}
          _ -> :invalid
        end
    end
  end

  def parse(bytes) do
    try do
      events =
        bytes
        |> String.replace("\r\n", "\n")
        |> String.split("\n\n")
        |> Enum.drop(-1)
        |> Enum.map(&decode_frame/1)

      if :invalid in events do
        if Enum.any?(events, &match?({:ok, %{"type" => "message_stop"}}, &1)),
          do: raise("malformed event"),
          else: throw(:cut)
      end

      initial = %{
        started: false,
        done: false,
        blocks: [],
        active: nil,
        fragments: "",
        stop: nil,
        usage: %{},
        meta: %{}
      }

      s =
        Enum.reduce(events, initial, fn
          :ignore, s -> s
          {:ok, e}, s -> event(e, s)
        end)

      cond do
        not s.done ->
          {:transient, "Anthropic cut stream"}

        s.stop == "model_context_window_exceeded" ->
          {:go_error, "context_too_long", %{status: 200}}

        true ->
          result(s)
      end
    rescue
      _ -> {:invalid, "malformed Anthropic completion"}
    catch
      :cut -> {:transient, "Anthropic cut stream"}
    end
  end

  defp event(%{"type" => "error"}, _), do: raise("stream error")

  defp event(%{"type" => t}, s)
       when t not in ~w(message_start content_block_start content_block_delta content_block_stop message_delta message_stop),
       do: s

  defp event(_, %{done: true}), do: raise("event after stop")

  defp event(%{"type" => "message_start", "message" => m}, %{started: false} = s)
       when is_map(m) do
    %{
      s
      | started: true,
        usage: usage_map(m["usage"]),
        meta: %{"id" => m["id"], "model" => m["model"]}
    }
  end

  defp event(
         %{"type" => "content_block_start", "index" => i, "content_block" => b},
         %{started: true, active: nil, stop: nil} = s
       )
       when is_integer(i) and is_map(b) do
    if i != length(s.blocks), do: raise("noncontiguous block")
    %{s | active: b, fragments: ""}
  end

  defp event(
         %{"type" => "content_block_delta", "index" => i, "delta" => d},
         %{active: b, stop: nil} = s
       )
       when is_integer(i) and is_map(b) and is_map(d) do
    if i != length(s.blocks), do: raise("wrong index")

    case {b["type"], d} do
      {"tool_use", %{"type" => "input_json_delta", "partial_json" => v}} when is_binary(v) ->
        %{s | fragments: s.fragments <> v}

      {"text", %{"type" => "text_delta", "text" => v}} when is_binary(v) ->
        %{s | active: Map.update!(b, "text", &(&1 <> v))}

      {"thinking", %{"type" => "thinking_delta", "thinking" => v}} when is_binary(v) ->
        %{s | active: Map.update!(b, "thinking", &(&1 <> v))}

      {"thinking", %{"type" => "signature_delta", "signature" => v}} when is_binary(v) ->
        %{s | active: Map.update(b, "signature", v, &(&1 <> v))}

      _ ->
        raise("unknown delta")
    end
  end

  defp event(%{"type" => "content_block_stop", "index" => i}, %{active: b, stop: nil} = s)
       when is_integer(i) and is_map(b) do
    if i != length(s.blocks), do: raise("wrong index")

    b =
      if b["type"] == "tool_use" and s.fragments != "",
        do: Map.put(b, "input", JSON.decode!(s.fragments)),
        else: b

    %{s | blocks: s.blocks ++ [b], active: nil, fragments: ""}
  end

  defp event(%{"type" => "message_delta", "delta" => d} = e, %{started: true, active: nil} = s)
       when is_map(d) do
    stop = d["stop_reason"] || s.stop
    if s.stop != nil and stop != s.stop, do: raise("changed stop")
    %{s | stop: stop, usage: Map.merge(s.usage, usage_map(e["usage"]))}
  end

  defp event(%{"type" => "message_stop"}, %{started: true, active: nil, stop: stop} = s)
       when not is_nil(stop), do: %{s | done: true}

  defp event(_, _), do: raise("invalid event order")
  defp usage_map(nil), do: %{}
  defp usage_map(m) when is_map(m), do: m

  defp result(s) do
    calls = Enum.filter(s.blocks, &(&1["type"] == "tool_use"))

    texts =
      for %{"type" => "text", "text" => t} <- s.blocks,
          is_binary(t) and String.trim(t) != "",
          do: %{"type" => "output_text", "text" => t}

    valid_blocks =
      Enum.all?(s.blocks, fn
        %{"type" => "text", "text" => t} ->
          is_binary(t)

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          valid?(id) and valid?(name) and String.trim(id) != "" and String.trim(name) != "" and
            is_map(input)

        %{"type" => "thinking", "thinking" => t, "signature" => sig} ->
          is_binary(t) and is_binary(sig) and sig != ""

        %{"type" => "redacted_thinking", "data" => d} ->
          is_binary(d)

        _ ->
          false
      end)

    if not valid_blocks or length(Enum.uniq_by(calls, & &1["id"])) != length(calls) or
         not ((s.stop == "end_turn" and texts != [] and calls == []) or
                (s.stop == "tool_use" and calls != [])) do
      {:invalid, "non-success Anthropic completion"}
    else
      raw = %{"role" => "assistant", "content" => s.blocks}

      items = [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => texts,
          "anthropic_message" => raw
        }
        | Enum.map(
            calls,
            &%{
              "type" => "function_call",
              "call_id" => &1["id"],
              "name" => &1["name"],
              "arguments" => JSON.encode!(&1["input"])
            }
          )
      ]

      u = usage(s.usage)

      inconsistent =
        Enum.any?(
          ~w(input_tokens cache_read_input_tokens cache_creation_input_tokens output_tokens),
          fn f ->
            v = s.usage[f]
            v != nil and not (is_integer(v) and v >= 0)
          end
        )

      {:ok,
       %{
         items: items,
         usage: Map.take(u, [:input, :cached, :output, :reasoning]),
         known_usage: u,
         usage_state: if(inconsistent, do: "inconsistent", else: Kogen.Usage.state(u)),
         response_metadata: s.meta
       }}
    end
  end

  def usage(u) do
    i = count(u["input_tokens"])
    r = count(u["cache_read_input_tokens"])
    w = count(u["cache_creation_input_tokens"])

    %{
      input: if(Enum.all?([i, r, w], &is_integer/1), do: i + r + w),
      cached: r,
      write: w,
      output: count(u["output_tokens"]),
      reasoning: nil,
      write_30m: nil,
      write_12h: nil
    }
  end

  defp count(v) when is_integer(v) and v >= 0, do: v
  defp count(_), do: nil
end
