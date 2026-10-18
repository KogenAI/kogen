defmodule Kogen.ChatGPT do
  @moduledoc """
  ChatGPT through OpenAI's "Sign in with ChatGPT" plan usage for open-source apps (chapter 08):
  Kogen's own login with dynamic registration, its stored and refreshed credentials, and
  streamed `POST /v1/responses` requests with tool calls, usage and classified errors.
  """
  alias Kogen.{Bridge, Error, Lock}

  @scope "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  @resource "https://api.openai.com/v1"
  @redirect "http://127.0.0.1:1455/auth/callback"

  # ---- Locations ----

  defp home, do: Kogen.caller().env["HOME"]
  defp creds_path, do: Path.join(home(), ".kogen/credentials/chatgpt.json")
  defp host_id_path, do: Path.join(home(), ".kogen/host-id")
  defp auth_base, do: Kogen.caller().env["KOGEN_AUTH_URL"] || "https://auth.openai.com"

  defp api_base,
    do:
      (Kogen.caller().env["KOGEN_PROVIDER_URL"] &&
         Kogen.caller().env["KOGEN_PROVIDER_URL"] <> "/v1") || @resource

  # ---- Status (GPT-4) ----

  def status do
    case read_creds() do
      nil ->
        Bridge.puts("chatgpt: not signed in")

      c ->
        if usable_credentials?(c) do
          Bridge.puts("chatgpt: signed in" <> email_suffix(c["email"]))
        else
          Bridge.puts("chatgpt: saved login cannot be used; run kogen provider login chatgpt")
        end
    end

    0
  end

  defp email_suffix(email) when is_binary(email) and email != "", do: " (#{email})"
  defp email_suffix(_), do: ""

  defp read_creds do
    case File.read(creds_path()) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, credentials} when is_map(credentials) -> credentials
          _ -> %{}
        end

      {:error, :enoent} ->
        nil

      {:error, _} ->
        %{}
    end
  end

  defp usable_credentials?(%{
         "client_id" => client_id,
         "refresh_token" => refresh_token,
         "access_token" => access_token,
         "expires_at" => expires_at
       })
       when is_binary(client_id) and byte_size(client_id) > 7 and
              is_binary(refresh_token) and byte_size(refresh_token) > 0 and
              is_binary(access_token) and byte_size(access_token) > 0 and is_integer(expires_at) do
    String.starts_with?(client_id, "oaiapp_")
  end

  defp usable_credentials?(_), do: false

  defp write_creds(c) do
    dir = Path.dirname(creds_path())
    File.mkdir_p!(dir)
    File.chmod!(Path.dirname(dir), 0o700)
    File.chmod!(dir, 0o700)
    tmp = creds_path() <> "." <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, JSON.encode!(c))
    File.rename!(tmp, creds_path())
  end

  defp host_id do
    case File.read(host_id_path()) do
      {:ok, id} ->
        String.trim(id)

      {:error, :enoent} ->
        id = "urn:uuid:" <> uuid4()
        File.mkdir_p!(Path.dirname(host_id_path()))
        File.write!(host_id_path(), id <> "\n")
        id
    end
  end

  defp uuid4 do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::62>>
    |> Base.encode16(case: :lower)
    |> then(fn h ->
      String.slice(h, 0, 8) <>
        "-" <>
        String.slice(h, 8, 4) <>
        "-" <>
        String.slice(h, 12, 4) <> "-" <> String.slice(h, 16, 4) <> "-" <> String.slice(h, 20, 12)
    end)
  end

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  # ---- Login (GPT-2, GPT-3) ----

  def login do
    previous = read_creds()
    verifier = b64url(:crypto.strong_rand_bytes(32))
    state = b64url(:crypto.strong_rand_bytes(16))
    nonce = b64url(:crypto.strong_rand_bytes(16))

    registration =
      case previous do
        %{"client_id" => "oaiapp_" <> _ = id} ->
          %{"client_id" => id}

        _ ->
          %{
            "client_id" => "dynamic_agent_client",
            "agent_name_hint" => "Kogen",
            "ext_agent_host_id" => host_id()
          }
      end

    params =
      Map.merge(registration, %{
        "response_type" => "code",
        "redirect_uri" => @redirect,
        "scope" => @scope,
        "resource" => @resource,
        "state" => state,
        "nonce" => nonce,
        "code_challenge_method" => "S256",
        "code_challenge" => b64url(:crypto.hash(:sha256, verifier))
      })

    url = auth_base() <> "/api/accounts/authorize?" <> URI.encode_query(params)
    Bridge.puts("Continue with ChatGPT")
    Bridge.puts(url)
    Bridge.send_msg(%{"type" => "listen", "url" => url})
    deadline = System.monotonic_time(:millisecond) + 300_000
    query = await_redirect(state, deadline)

    if query["error"] do
      login_failed(
        query["error"] <>
          if(query["error_description"], do: ": " <> query["error_description"], else: "")
      )
    end

    client_id = query["client_id"] || registration["client_id"]

    if not String.starts_with?(client_id, "oaiapp_"),
      do: login_failed("the sign-in did not register Kogen (no issued client ID)")

    tok =
      case post_form(auth_base() <> "/api/accounts/oauth/token", %{
             "grant_type" => "authorization_code",
             "client_id" => client_id,
             "code" => query["code"],
             "code_verifier" => verifier,
             "redirect_uri" => @redirect,
             "resource" => @resource
           }) do
        {200, tok} ->
          tok

        {status, body} ->
          login_failed("the token exchange failed (#{status} #{body["error"] || ""})")
      end

    if "chatgpt.tokens.use.direct" not in String.split(tok["scope"] || "") do
      Error.raise!(
        "provider",
        "login_failed",
        "ChatGPT plan usage was not granted; sign in again and allow it",
        4
      )
    end

    claims = jwt_claims(tok["id_token"])
    if claims["nonce"] != nonce, do: login_failed("the sign-in answer does not match this login")
    email = claims["email"]

    with_lock(fn ->
      write_creds(%{
        "client_id" => client_id,
        "access_token" => tok["access_token"],
        "refresh_token" => tok["refresh_token"],
        "expires_at" => now() + (tok["expires_in"] || 3600),
        "scope" => tok["scope"],
        "email" => email
      })
    end)

    Bridge.puts("chatgpt signed in" <> email_suffix(email))
    0
  end

  defp login_failed(detail), do: Error.raise!("provider", "login_failed", detail, 4)

  defp await_redirect(state, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:proto, %{"type" => "redirect", "url" => url}} ->
        query = URI.decode_query(URI.parse(url).query || "")

        if query["state"] == state do
          query
        else
          Bridge.progress("kogen: ignored a sign-in redirect with the wrong state")
          await_redirect(state, deadline)
        end

      {:proto, %{"type" => "cancel", "signal" => sig}} ->
        Bridge.cancelled(sig)
    after
      wait -> login_failed("no sign-in arrived within 300 seconds")
    end
  end

  defp jwt_claims(jwt) when is_binary(jwt) do
    [_, payload | _] = String.split(jwt, ".")
    payload |> Base.url_decode64!(padding: false) |> JSON.decode!()
  end

  defp jwt_claims(_), do: %{}

  defp now, do: System.os_time(:second)

  # A token request that an interrupt can cancel.
  defp post_form(url, form) do
    body = URI.encode_query(form)

    req =
      {String.to_charlist(url), [{~c"accept", ~c"application/json"}],
       ~c"application/x-www-form-urlencoded", body}

    {:ok, ref} = :httpc.request(:post, req, http_opts(), sync: false, body_format: :binary)

    receive do
      {:http, {^ref, {{_, status, _}, _headers, resp}}} ->
        {status,
         case JSON.decode(resp) do
           {:ok, map} when is_map(map) -> map
           _ -> %{}
         end}

      {:http, {^ref, {:error, reason}}} ->
        {0, %{"error" => inspect(reason)}}

      {:proto, %{"type" => "cancel", "signal" => sig}} ->
        :httpc.cancel_request(ref)
        Bridge.cancelled(sig)
    end
  end

  defp http_opts do
    [
      connect_timeout: 30_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  # ---- Credentials in use (GPT-5, GPT-6) ----

  @doc "Refuses without a login (GPT-5)."
  def require_login! do
    stored_credentials!()
    :ok
  end

  defp access_token do
    c = stored_credentials!()

    if expiring?(c), do: refreshed(c["access_token"], :proactive), else: c["access_token"]
  end

  defp stored_credentials! do
    case read_creds() do
      nil ->
        Error.raise!("provider", "login", "not signed in; run kogen provider login chatgpt", 4)

      credentials ->
        if usable_credentials?(credentials) do
          credentials
        else
          Error.raise!(
            "provider",
            "login",
            "saved login cannot be used; run kogen provider login chatgpt",
            4
          )
        end
    end
  end

  defp expiring?(c), do: c["expires_at"] - 60 <= now()

  # GPT-6: refresh under an exclusive lock; another kogen may already have rotated the token.
  defp refreshed(stale, reason) do
    with_lock(fn ->
      c = stored_credentials!()

      if c["access_token"] != stale and not expiring?(c),
        do: c["access_token"],
        else: refresh(c, reason)
    end)
  end

  defp with_lock(fun) do
    lock = Path.join(Path.dirname(creds_path()), "chatgpt.lock")

    case Lock.acquire(lock) do
      {:held, _pid} ->
        pause(100)
        with_lock(fun)

      _taken ->
        try do
          fun.()
        after
          Lock.release(lock)
        end
    end
  end

  defp refresh(c, reason) do
    case post_form(auth_base() <> "/api/accounts/oauth/token", %{
           "grant_type" => "refresh_token",
           "client_id" => c["client_id"],
           "refresh_token" => c["refresh_token"],
           "resource" => @resource
         }) do
      {200, tok} ->
        write_creds(%{
          c
          | "access_token" => tok["access_token"],
            "refresh_token" => tok["refresh_token"] || c["refresh_token"],
            "expires_at" => now() + (tok["expires_in"] || 3600)
        })

        tok["access_token"]

      {_status, %{"error" => "invalid_grant"}} ->
        login_rejected!()

      {_status, _body} when reason == :after_401 ->
        login_rejected!()

      _ ->
        Error.raise!(
          "provider",
          "login",
          "the ChatGPT sign-in expired and could not be refreshed; run kogen provider login chatgpt",
          4
        )
    end
  end

  defp login_rejected! do
    Error.raise!(
      "provider",
      "login",
      "the ChatGPT sign-in was rejected; run kogen provider login chatgpt",
      4
    )
  end

  # ---- Requests (GPT-7, GPT-8, GPT-9) ----

  @doc """
  Sends one streamed request: `instructions`, `input` items and `tools` on the given model and
  effort. Returns `%{items: [...], usage: %{...}}`; raises `Kogen.Error` (class `provider`) on a
  provider failure, with reason `context_too_long` when the conversation no longer fits.
  """
  def respond(%{model: model, effort: effort}, instructions, input, tools) do
    body =
      %{
        "model" => model,
        "reasoning" => %{"effort" => effort},
        "instructions" => instructions,
        "input" => input,
        "stream" => true,
        "store" => false
      }
      |> then(fn b ->
        if tools == [], do: b, else: Map.merge(b, %{"tools" => tools, "tool_choice" => "auto"})
      end)
      |> JSON.encode!()

    attempt(body, model, 1, false, false)
  end

  defp attempt(body, model, n, refreshed, retried_invalid) do
    token = access_token()

    case stream(body, token) do
      {:ok, result} ->
        result

      {:unauthorized, _} when not refreshed ->
        refreshed(token, :after_401)
        attempt(body, model, n, true, retried_invalid)

      {:unauthorized, _} ->
        login_rejected!()

      {:transient, _detail} when n < 3 ->
        pause(if n == 1, do: 2_000, else: 8_000)
        attempt(body, model, n + 1, refreshed, retried_invalid)

      {:transient, detail} ->
        Error.raise!(
          "provider",
          "unavailable",
          "ChatGPT did not answer after 3 attempts: #{detail}",
          4
        )

      {:invalid, _detail} when not retried_invalid ->
        attempt(body, model, n, refreshed, true)

      {:invalid, detail} ->
        Error.raise!(
          "provider",
          "invalid_response",
          "ChatGPT sent a response Kogen cannot read: #{detail}",
          4
        )

      {:error, error} ->
        classify(error, model)
    end
  end

  defp pause(ms) do
    receive do
      {:proto, %{"type" => "cancel", "signal" => sig}} -> Bridge.cancelled(sig)
    after
      ms -> :ok
    end
  end

  # A request error that retrying cannot fix.
  defp classify(
         %{status: status, code: code, param: param, message: message, resets_at: resets_at},
         model
       ) do
    cond do
      code == "subscription_sharing_usage_limit_exceeded" ->
        Error.raise!(
          "provider",
          "usage_limit",
          "ChatGPT usage limit reached" <> reset_text(resets_at),
          4
        )

      code == "model_not_found" or
          (code == "subscription_sharing_unsupported_capability" and param == "model") ->
        Error.raise!(
          "provider",
          "model_unavailable",
          "#{model} is not available to this ChatGPT account",
          4
        )

      code == "context_length_exceeded" ->
        Error.raise!(
          "provider",
          "context_too_long",
          "the conversation no longer fits #{model}'s context",
          4
        )

      true ->
        Error.raise!(
          "provider",
          "refused",
          "ChatGPT refused the request: #{status} #{message}" |> String.trim_trailing(),
          4
        )
    end
  end

  defp reset_text(nil), do: ""

  defp reset_text(t) when is_integer(t),
    do: "; it resets at " <> (t |> DateTime.from_unix!() |> DateTime.to_iso8601())

  defp reset_text(t) when is_binary(t), do: "; it resets at " <> t

  defp stream(body, token) do
    url = String.to_charlist(api_base() <> "/responses")

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"text/event-stream"}
    ]

    {:ok, ref} =
      :httpc.request(:post, {url, headers, ~c"application/json", body}, http_opts(),
        sync: false,
        stream: :self,
        body_format: :binary
      )

    collect(ref, %{buf: "", items: %{}, usage: nil, done: false, failure: nil})
  end

  defp collect(ref, acc) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        collect(ref, acc)

      {:http, {^ref, :stream, chunk}} ->
        case events(acc.buf <> chunk, acc) do
          {:ok, acc} -> collect(ref, acc)
          {:invalid, detail} -> :httpc.cancel_request(ref) && {:invalid, detail}
        end

      {:http, {^ref, :stream_end, _headers}} ->
        finish(acc)

      {:http, {^ref, {{_, status, _}, _headers, body}}} ->
        http_error(status, body)

      {:http, {^ref, {:error, reason}}} ->
        {:transient, "network error: #{inspect(reason)}"}

      {:proto, %{"type" => "cancel", "signal" => sig}} ->
        :httpc.cancel_request(ref)
        Bridge.cancelled(sig)
    end
  end

  defp finish(%{failure: f}) when f != nil, do: failure(f)
  defp finish(%{done: false}), do: {:transient, "the response stream ended before it completed"}

  defp finish(acc) do
    items = acc.items |> Enum.sort() |> Enum.map(&elem(&1, 1))
    {:ok, %{items: items, usage: usage(acc.usage)}}
  end

  defp usage(u) do
    u = u || %{}

    %{
      input: u["input_tokens"] || 0,
      cached: get_in(u, ["input_tokens_details", "cached_tokens"]) || 0,
      output: u["output_tokens"] || 0,
      reasoning: get_in(u, ["output_tokens_details", "reasoning_tokens"]) || 0
    }
  end

  defp events(buf, acc) do
    case String.split(buf, ~r/\r?\n\r?\n/, parts: 2) do
      [complete, rest] ->
        case event(complete, acc) do
          {:ok, acc} -> events(rest, acc)
          other -> other
        end

      [partial] ->
        {:ok, %{acc | buf: partial}}
    end
  end

  defp event(text, acc) do
    data =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &String.trim_leading(String.replace_prefix(&1, "data:", "")))

    cond do
      data == "" or data == "[DONE]" ->
        {:ok, acc}

      true ->
        case JSON.decode(data) do
          {:ok, %{"type" => type} = ev} -> {:ok, apply_event(type, ev, acc)}
          _ -> {:invalid, "an event is not JSON"}
        end
    end
  end

  defp apply_event("response.output_item.done", %{"output_index" => i, "item" => item}, acc),
    do: %{acc | items: Map.put(acc.items, i, item)}

  defp apply_event("response.completed", ev, acc),
    do: %{acc | done: true, usage: get_in(ev, ["response", "usage"])}

  defp apply_event("response.incomplete", ev, acc),
    do: %{
      acc
      | failure: %{
          "code" => "incomplete",
          "message" => inspect(get_in(ev, ["response", "incomplete_details"]))
        }
    }

  defp apply_event("response.failed", ev, acc),
    do: %{acc | failure: get_in(ev, ["response", "error"]) || %{}}

  defp apply_event("error", ev, acc), do: %{acc | failure: ev["error"] || ev}
  defp apply_event(_type, _ev, acc), do: acc

  # A failure reported inside the stream.
  defp failure(f) do
    error = %{
      status: "stream",
      code: f["code"],
      param: f["param"],
      message: f["message"] || "",
      resets_at: f["resets_at"]
    }

    cond do
      f["code"] in [
        "server_error",
        "rate_limit_exceeded",
        "subscription_sharing_usage_unavailable",
        "subscription_sharing_user_unavailable"
      ] ->
        {:transient, "#{f["code"]}: #{f["message"]}"}

      true ->
        {:error, error}
    end
  end

  defp http_error(status, body) do
    {err, detail} =
      case JSON.decode(body) do
        {:ok, %{"error" => %{} = e}} -> {e, e["message"] || e["code"] || ""}
        {:ok, %{"detail" => d}} -> {%{}, to_string(d)}
        _ -> {%{}, String.slice(body, 0, 200)}
      end

    error = %{
      status: status,
      code: err["code"],
      param: err["param"],
      message: detail,
      resets_at: err["resets_at"]
    }

    cond do
      status == 401 ->
        {:unauthorized, detail}

      err["code"] == "subscription_sharing_usage_limit_exceeded" ->
        {:error, error}

      status == 429 or status >= 500 ->
        {:transient, "HTTP #{status} #{detail}" |> String.trim_trailing()}

      true ->
        {:error, error}
    end
  end
end
