defmodule Kogen.OpenCodeGo do
  @moduledoc "Kogen-owned Go key custody and lossless non-streaming Chat Completions adapter."
  alias Kogen.{Bridge, Error, Lock}
  defp path, do: Path.join(Kogen.caller().env["HOME"], ".kogen/credentials/opencode-go.json")
  defp fail(reason, detail), do: Error.raise!("provider", reason, detail, 4)

  defp valid?(s),
    do: is_binary(s) and s != "" and String.valid?(s) and not Regex.match?(~r/\p{Cc}/u, s)

  defp read do
    case File.read(path()) do
      {:error, :enoent} ->
        nil

      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"provider" => "opencode-go", "api_key" => key}} ->
            if valid?(key), do: key, else: :invalid

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
        :invalid -> "saved login cannot be used; run kogen provider login opencode-go"
        _ -> "key saved (not verified)"
      end

    Bridge.puts("opencode-go: " <> text)
    0
  end

  def require_login! do
    case read() do
      key when is_binary(key) -> key
      _ -> fail("login", "no usable OpenCode Go key; run kogen provider login opencode-go")
    end
  end

  def login do
    Bridge.send_msg(%{type: "secret_input"})

    key =
      case Bridge.recv() do
        %{"type" => "secret_input", "ok" => true, "value" => value} ->
          # Trim surrounding whitespace and one terminating line ending, never internal controls.
          unless String.valid?(value),
            do: fail("login_failed", "invalid OpenCode Go key input; saved login unchanged")

          value = String.replace(value, ~r/\r?\n\z/, "")

          if String.contains?(value, ["\n", "\r"]),
            do: fail("login_failed", "invalid OpenCode Go key input; saved login unchanged")

          String.trim(value)

        %{"type" => "cancel", "signal" => sig} ->
          Bridge.cancelled(sig)

        _ ->
          fail("login_failed", "OpenCode Go input interrupted; saved login unchanged")
      end

    if key == "", do: fail("login_failed", "no OpenCode Go key supplied; saved login unchanged")

    unless valid?(key),
      do: fail("login_failed", "invalid OpenCode Go key input; saved login unchanged")

    dir = Path.dirname(path())
    lock = Path.rootname(path()) <> ".lock"
    tmp = path() <> "." <> Base.encode16(:crypto.strong_rand_bytes(8))

    try do
      File.mkdir_p!(dir)
      File.chmod!(Path.dirname(dir), 0o700)
      File.chmod!(dir, 0o700)

      case Lock.acquire(lock) do
        {:held, _} ->
          fail("login_failed", "OpenCode Go login is locked; saved login unchanged")

        _ ->
          try do
            File.write!(tmp, "", [:exclusive])
            File.chmod!(tmp, 0o600)
            File.write!(tmp, JSON.encode!(%{provider: "opencode-go", api_key: key}))
            Bridge.check_cancel()
            File.rename!(tmp, path())
          after
            Lock.release(lock)
          end
      end
    rescue
      _ -> fail("login_failed", "could not save OpenCode Go key; saved login unchanged")
    after
      File.rm(tmp)
    end

    Bridge.puts("opencode-go: key saved (not verified)")
    0
  end

  def request_body(role, policy, input, tools) do
    if image?(input),
      do:
        fail(
          "unsupported_capability",
          "OpenCode Go images are unqualified; use external image preparation and pixel-review handoff"
        )

    Kogen.PromptCache.prepare(role.model, policy, input, tools, "opencode-go")
    {_, _, meta} = Process.get(:prompt_cache_current)
    Process.put(:opencode_go_session, meta.conversation_id)
    messages = [%{"role" => "system", "content" => policy} | render(input)]
    body = %{"model" => role.model, "stream" => false, "store" => false, "messages" => messages}

    body =
      if tools == [],
        do: body,
        else:
          Map.merge(body, %{
            "tool_choice" => "auto",
            "tools" =>
              Enum.map(tools, &%{"type" => "function", "function" => Map.delete(&1, "type")})
          })

    if role.effort == "default", do: body, else: Map.put(body, "reasoning_effort", role.effort)
  end

  defp image?(v) when is_list(v), do: Enum.any?(v, &image?/1)

  defp image?(v) when is_map(v),
    do: v["type"] == "input_image" or Enum.any?(Map.values(v), &image?/1)

  defp image?(_), do: false

  defp render(input) do
    {messages, _} =
      Enum.reduce(input, {[], MapSet.new()}, fn item, {out, suppressed} ->
        cond do
          is_map(item["opencode_go_message"]) ->
            raw = item["opencode_go_message"]
            ids = Enum.map(raw["tool_calls"] || [], & &1["id"])
            {out ++ [raw], MapSet.union(suppressed, MapSet.new(ids))}

          item["type"] == "function_call" and MapSet.member?(suppressed, item["call_id"]) ->
            {out, suppressed}

          item["type"] == "function_call_output" ->
            {out ++
               [
                 %{
                   "role" => "tool",
                   "tool_call_id" => item["call_id"],
                   "content" => content(item["output"])
                 }
               ], suppressed}

          item["role"] in ["user", "system", "assistant"] ->
            content = content(item["content"])

            {out ++ [%{"role" => item["role"], "content" => content}], suppressed}

          true ->
            {out, suppressed}
        end
      end)

    messages
  end

  defp content(blocks) when is_list(blocks),
    do: Enum.map(blocks, fn b -> %{"type" => "text", "text" => b["text"]} end)

  defp content(text), do: text

  def transport(body, token, deadline) do
    base = Kogen.caller().env["KOGEN_PROVIDER_URL"] || "https://opencode.ai"

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"user-agent", String.to_charlist(Kogen.SuperGrok.user_agent())},
      {~c"x-opencode-session", String.to_charlist(Process.get(:opencode_go_session))}
    ]

    {:ok, ref} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> "/inference/go/openai/v1/chat/completions"), headers,
         ~c"application/json", body},
        Keyword.put(Kogen.ChatGPT.http_opts(deadline), :autoredirect, false),
        sync: false,
        body_format: :binary
      )

    try do
      receive do
        {:http, {^ref, {{_, status, _}, hs, bytes}}} ->
          Process.put(
            :provider_request_id,
            Enum.find_value(hs, fn {k, v} ->
              if String.downcase(to_string(k)) == "x-request-id",
                do: Kogen.PromptCache.identifier(to_string(v))
            end)
          )

          Kogen.ChatGPT.remaining(deadline)

          response =
            case JSON.decode(bytes) do
              {:ok, m} when is_map(m) -> m
              _ -> %{}
            end

          error = if is_map(response["error"]), do: response["error"], else: %{}

          diagnostic = %{
            status: status,
            code: safe_code(error["code"]),
            type: safe_code(error["type"])
          }

          cond do
            status == 200 ->
              adapt(response)

            status == 429 or status >= 500 ->
              {:transient,
               %{
                 detail: "OpenCode Go temporary HTTP #{status}",
                 provider_failure: failure_fields(diagnostic)
               }}

            status == 401 ->
              {:unauthorized, diagnostic}

            true ->
              code = diagnostic.code
              reason = if code == "model_not_found", do: "model_unavailable", else: "refused"
              {:go_error, reason, diagnostic}
          end

        {:http, {^ref, {:error, _}}} ->
          {:transient, "OpenCode Go network failure"}

        {:proto, %{"type" => "cancel", "signal" => sig}} ->
          Bridge.cancelled(sig)
      after
        Kogen.ChatGPT.remaining(deadline) ->
          fail("unavailable", "OpenCode Go response wait exceeded logical deadline")
      end
    after
      :httpc.cancel_request(ref)
    end
  end

  defp safe_code(v) when is_binary(v) do
    if Regex.match?(~r/\A[a-zA-Z0-9_.:-]{1,128}\z/, v), do: v
  end

  defp safe_code(_), do: nil

  defp failure_fields(d),
    do:
      for(
        {k, v} <- [{"http_status", d.status}, {"code", d.code}, {"type", d.type}],
        not is_nil(v),
        into: %{},
        do: {k, v}
      )

  def adapt(response) do
    with true <- is_nil(response["error"]),
         true <- is_nil(response["usage"]) or is_map(response["usage"]),
         [
           %{
             "message" => %{"role" => "assistant", "content" => content} = raw,
             "finish_reason" => finish
           }
           | _
         ] <-
           response["choices"],
         true <- finish in ["stop", "tool_calls"],
         true <- is_nil(content) or is_binary(content),
         true <- raw["refusal"] in [nil, ""],
         calls when is_list(calls) <-
           if(is_nil(raw["tool_calls"]), do: [], else: raw["tool_calls"]),
         true <- finish != "tool_calls" or calls != [],
         true <- Enum.all?(calls, &valid_call?/1),
         true <- length(Enum.uniq(Enum.map(calls, & &1["id"]))) == length(calls),
         true <- calls != [] or (is_binary(raw["content"]) and raw["content"] != "") do
      text =
        if is_binary(raw["content"]),
          do: [%{"type" => "output_text", "text" => raw["content"]}],
          else: []

      message = %{
        "type" => "message",
        "role" => "assistant",
        "content" => text,
        "opencode_go_message" => raw
      }

      items = [
        message
        | Enum.map(calls, fn c ->
            %{
              "type" => "function_call",
              "call_id" => c["id"],
              "name" => c["function"]["name"],
              "arguments" => c["function"]["arguments"]
            }
          end)
      ]

      u = response["usage"] || %{}

      usage = %{
        input: count(u["prompt_tokens"]),
        cached: detail_count(u, "prompt_tokens_details", "cached_tokens"),
        output: count(u["completion_tokens"]),
        reasoning: detail_count(u, "completion_tokens_details", "reasoning_tokens")
      }

      {:ok,
       %{
         items: items,
         usage: usage,
         known_usage: Map.merge(usage, %{write: nil, write_30m: nil, write_12h: nil}),
         usage_state:
           Kogen.Usage.state(Map.merge(usage, %{write: nil, write_30m: nil, write_12h: nil})),
         response_metadata: response |> Map.take(~w(id model))
       }}
    else
      _ -> {:invalid, "incomplete or malformed OpenCode Go completion"}
    end
  end

  defp detail_count(u, k, field), do: if(is_map(u[k]), do: count(u[k][field]), else: nil)
  defp count(v) when is_integer(v) and v >= 0, do: v
  defp count(_), do: nil

  defp valid_call?(%{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args}
       }) do
    valid?(id) and valid?(name) and is_binary(args) and
      match?({:ok, m} when is_map(m), JSON.decode(args))
  end

  defp valid_call?(_), do: false
end
