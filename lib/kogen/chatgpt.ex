defmodule Kogen.ChatGPT do
  @moduledoc """
  ChatGPT through OpenAI's "Sign in with ChatGPT" plan usage for open-source apps (chapter 08):
  Kogen's own login with dynamic registration, its stored and refreshed credentials, and
  streamed `POST /v1/responses` requests with tool calls, usage and classified errors.
  The Responses transport also routes SuperGrok roles through Kogen-owned subscription auth.
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

    with_lock(nil, fn ->
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
  defp post_form(url, form, deadline \\ nil) do
    body = URI.encode_query(form)

    req =
      {String.to_charlist(url), [{~c"accept", ~c"application/json"}],
       ~c"application/x-www-form-urlencoded", body}

    {:ok, ref} =
      :httpc.request(:post, req, http_opts(deadline), sync: false, body_format: :binary)

    try do
      remaining(deadline)

      receive do
        {:http, {^ref, {{_, status, _}, _headers, resp}}} ->
          remaining(deadline)

          {status,
           case JSON.decode(resp) do
             {:ok, map} when is_map(map) -> map
             _ -> %{}
           end}

        {:http, {^ref, {:error, reason}}} ->
          remaining(deadline)
          {0, %{"error" => inspect(reason)}}

        {:proto, %{"type" => "cancel", "signal" => sig}} ->
          :httpc.cancel_request(ref)
          Bridge.cancelled(sig)
      after
        remaining(deadline) -> expired!()
      end
    after
      :httpc.cancel_request(ref)
    end
  end

  def http_opts(deadline) do
    [
      connect_timeout: min(30_000, remaining(deadline)),
      timeout: remaining(deadline),
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

  defp access_token(deadline) do
    if supergrok?(),
      do: Kogen.SuperGrok.access_token(deadline),
      else: chatgpt_access_token(deadline)
  end

  defp chatgpt_access_token(deadline) do
    remaining(deadline)
    c = stored_credentials!()

    if expiring?(c),
      do: refreshed(c["access_token"], :proactive, deadline),
      else: c["access_token"]
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
  defp refreshed(stale, reason, deadline) do
    if supergrok?(),
      do: Kogen.SuperGrok.refreshed(stale, reason, deadline),
      else: chatgpt_refreshed(stale, reason, deadline)
  end

  defp chatgpt_refreshed(stale, reason, deadline) do
    with_lock(deadline, fn ->
      c = stored_credentials!()

      if c["access_token"] != stale and not expiring?(c),
        do: c["access_token"],
        else: refresh(c, reason, deadline)
    end)
  end

  defp with_lock(deadline, fun) do
    remaining(deadline)
    lock = Path.join(Path.dirname(creds_path()), "chatgpt.lock")

    case Lock.acquire(lock) do
      {:held, _pid} ->
        pause(100, deadline)
        with_lock(deadline, fun)

      _taken ->
        try do
          fun.()
        after
          Lock.release(lock)
        end
    end
  end

  defp refresh(c, reason, deadline) do
    case post_form(
           auth_base() <> "/api/accounts/oauth/token",
           %{
             "grant_type" => "refresh_token",
             "client_id" => c["client_id"],
             "refresh_token" => c["refresh_token"],
             "resource" => @resource
           },
           deadline
         ) do
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

  defp login_rejected!(diagnostics \\ %{}) do
    raise with_diagnostics(
            %Error{
              class: "provider",
              reason: "login",
              detail:
                "the #{provider_label()} sign-in was rejected; run kogen provider login #{if(supergrok?(), do: "supergrok", else: "chatgpt")}",
              exit: 4
            },
            diagnostics
          )
  end

  # ---- Requests (GPT-7, GPT-8, GPT-9) ----

  @doc """
  Sends one streamed request: `instructions`, `input` items and `tools` on the given model and
  effort. Returns `%{items: [...], usage: %{...}}`; raises `Kogen.Error` (class `provider`) on a
  provider failure, with reason `context_too_long` when the conversation no longer fits.
  """
  def request_body(%{model: model, effort: effort} = role, instructions, input, tools) do
    %{
      "model" => model,
      "reasoning" => %{"effort" => effort},
      "include" => ["reasoning.encrypted_content"],
      "input" => input,
      "stream" => true,
      "store" => false
    }
    |> then(fn b ->
      if tools == [], do: b, else: Map.merge(b, %{"tools" => tools, "tool_choice" => "auto"})
    end)
    |> Map.merge(
      Kogen.PromptCache.prepare(model, instructions, input, tools, Kogen.Provider.name(role))
    )
  end

  def respond(%{model: model, effort: effort} = role, instructions, input, tools, opts \\ []) do
    Process.put(:routed_provider, Kogen.Provider.name(role))

    deadline =
      System.monotonic_time(:millisecond) +
        min(1_800_000, Keyword.get(opts, :response_budget_ms, 1_800_000))

    body =
      request_body(role, instructions, input, tools) |> JSON.encode!()

    Process.put(:provider_operation, %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      id: Kogen.tmp_path("operation") |> Path.basename(),
      model: model,
      effort: effort
    })

    if Keyword.get(opts, :single_attempt, false) and not supergrok?() do
      case stream(body, access_token(deadline), deadline) do
        {:ok, result} ->
          result

        {:error, %{status: 400} = error} ->
          if cache_refusal?(error) and
               Map.has_key?(JSON.decode!(body), "prompt_cache_options") do
            Kogen.PromptCache.unsupported()
            single_compatibility(strip_cache(body), model, deadline)
          else
            classify(error, model)
          end

        {:error, error} ->
          classify(error, model)

        {:unauthorized, error} ->
          login_rejected!(diagnostics(error))

        {:transient, %{detail: detail, provider_failure: diagnostics}} ->
          raise with_diagnostics(
                  %Error{class: "provider", reason: "unavailable", detail: detail, exit: 4},
                  diagnostics
                )

        {:transient, detail} ->
          Error.raise!("provider", "unavailable", detail, 4)

        {:invalid, detail} ->
          Error.raise!("provider", "invalid_response", detail, 4)
      end
    else
      attempt(body, model, 1, false, false, deadline)
    end
  end

  defp single_compatibility(body, model, deadline) do
    case stream(body, access_token(deadline), deadline) do
      {:ok, result} ->
        result

      {:error, error} ->
        classify(error, model)

      {:unauthorized, error} ->
        login_rejected!(diagnostics(error))

      {:invalid, detail} ->
        Error.raise!("provider", "invalid_response", detail, 4)

      {:transient, _} ->
        Error.raise!("provider", "unavailable", "ChatGPT response unavailable", 4)
    end
  end

  defp attempt(body, model, n, refreshed, retried_invalid, deadline, token \\ nil) do
    token = token || access_token(deadline)

    case stream(body, token, deadline) do
      {:ok, result} ->
        result

      {:unauthorized, error} when not refreshed ->
        refreshed_token =
          try do
            refreshed(token, :after_401, deadline)
          rescue
            e in Error -> reraise with_diagnostics(e, diagnostics(error)), __STACKTRACE__
          end

        # A short-lived SuperGrok grant still gets exactly one retry after its 401 refresh.
        attempt(
          body,
          model,
          n,
          true,
          retried_invalid,
          deadline,
          if(supergrok?(), do: refreshed_token)
        )

      {:unauthorized, error} ->
        login_rejected!(diagnostics(error))

      {:transient, _detail} when n < 3 ->
        pause(if(n == 1, do: 2_000, else: 8_000), deadline)
        attempt(body, model, n + 1, refreshed, retried_invalid, deadline)

      {:transient, detail} ->
        {message, diagnostics} =
          case detail do
            %{detail: message, provider_failure: diagnostics} -> {message, diagnostics}
            message -> {message, %{}}
          end

        raise with_diagnostics(
                %Error{
                  class: "provider",
                  reason: "unavailable",
                  detail: "#{provider_label()} did not answer after 3 attempts: #{message}",
                  exit: 4
                },
                diagnostics
              )

      {:invalid, _detail} when not retried_invalid ->
        attempt(body, model, n, refreshed, true, deadline)

      {:invalid, detail} ->
        Error.raise!(
          "provider",
          "invalid_response",
          "#{provider_label()} sent a response Kogen cannot read: #{detail}",
          4
        )

      {:error, %{status: 400} = error} ->
        if cache_refusal?(error) and
             Map.has_key?(JSON.decode!(body), "prompt_cache_options") do
          Kogen.PromptCache.unsupported()
          attempt(strip_cache(body), model, n, refreshed, retried_invalid, deadline)
        else
          classify(error, model)
        end

      {:error, error} ->
        classify(error, model)
    end
  end

  defp supergrok?, do: Process.get(:routed_provider, "chatgpt") == "supergrok"
  defp provider_label, do: if(supergrok?(), do: "SuperGrok", else: "ChatGPT")
  defp detail_suffix(""), do: ""
  defp detail_suffix(message), do: " " <> message
  defp cache_refusal?(error), do: not supergrok?() and chatgpt_cache_refusal?(error)

  defp chatgpt_cache_refusal?(%{code: "invalid_parameter", message: message, param: param}),
    do:
      message == "prompt_cache_options is not supported on this model" and
        param in [nil, "prompt_cache_options"]

  defp chatgpt_cache_refusal?(%{code: code, param: param}) when is_binary(param),
    do:
      code in ~w(unknown_parameter unsupported_parameter subscription_sharing_unsupported_capability) and
        Regex.match?(~r/(?:^|[.\[])prompt_cache_(?:options|breakpoint)(?:$|[.\[])/, param)

  defp chatgpt_cache_refusal?(_), do: false

  defp strip_cache(body) do
    b = JSON.decode!(body) |> Map.delete("prompt_cache_options")

    input =
      Enum.map(b["input"], fn item ->
        if is_list(item["content"]),
          do:
            Map.update!(item, "content", fn blocks ->
              Enum.map(blocks, &Map.delete(&1, "prompt_cache_breakpoint"))
            end),
          else: item
      end)

    b |> Map.put("input", input) |> JSON.encode!()
  end

  defp pause(ms, deadline) do
    receive do
      {:proto, %{"type" => "cancel", "signal" => sig}} -> Bridge.cancelled(sig)
    after
      min(ms, remaining(deadline)) -> remaining(deadline)
    end
  end

  defp expired!,
    do:
      Error.raise!(
        "provider",
        "unavailable",
        "#{provider_label()} response wait exceeded 30 minutes",
        4
      )

  def remaining(nil), do: :infinity

  def remaining(deadline) do
    receive do
      {:proto, %{"type" => "cancel", "signal" => sig}} -> Bridge.cancelled(sig)
    after
      0 -> :ok
    end

    case deadline - System.monotonic_time(:millisecond) do
      ms when ms > 0 -> ms
      _ -> expired!()
    end
  end

  defp diagnostics(error) do
    # response.incomplete's code is a local fallback marker, not a provider field.
    for {key, value} <- [
          code: if(error[:event_kind] == "response.incomplete", do: nil, else: error[:code]),
          type: error[:type],
          event_kind: error[:event_kind],
          http_status: error[:status]
        ],
        (key == :http_status and is_integer(value)) or
          (key != :http_status and is_binary(value) and value != ""),
        into: %{},
        do: {Atom.to_string(key), value}
  end

  defp with_diagnostics(error, diagnostics) when map_size(diagnostics) == 0, do: error

  defp with_diagnostics(error, diagnostics),
    do: %{
      error
      | provider_failure: diagnostics,
        lines: error.lines ++ ["provider failure: " <> JSON.encode!(diagnostics)]
    }

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp classify(error, model) do
    try do
      classify_error(error, model)
    rescue
      e in Error -> reraise with_diagnostics(e, diagnostics(error)), __STACKTRACE__
    end
  end

  # A request error that retrying cannot fix.
  defp classify_error(
         %{status: status, code: code, param: param, message: message, resets_at: resets_at},
         model
       ) do
    cond do
      supergrok?() and status == 402 ->
        Error.raise!(
          "provider",
          "refused",
          "SuperGrok reported a billing or credit limit (402#{detail_suffix(message)}); Kogen uses only the subscription sign-in and never falls back to paid API usage",
          4
        )

      supergrok?() and status == 403 ->
        Error.raise!(
          "provider",
          "refused",
          "SuperGrok denied API access for this sign-in (403#{detail_suffix(message)}); Kogen never falls back to an API key or another provider",
          4
        )

      not supergrok?() and code == "subscription_sharing_usage_limit_exceeded" ->
        Error.raise!(
          "provider",
          "usage_limit",
          "ChatGPT usage limit reached" <> reset_text(resets_at),
          4
        )

      code == "model_not_found" or
          (not supergrok?() and code == "subscription_sharing_unsupported_capability" and
             param == "model") ->
        Error.raise!(
          "provider",
          "model_unavailable",
          "#{model} is not available to this #{provider_label()} account",
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
          "#{provider_label()} refused the request: #{status} #{message}"
          |> String.trim_trailing(),
          4
        )
    end
  end

  defp reset_text(nil), do: ""

  defp reset_text(t) when is_integer(t),
    do: "; it resets at " <> (t |> DateTime.from_unix!() |> DateTime.to_iso8601())

  defp reset_text(t) when is_binary(t), do: "; it resets at " <> t

  defp stream(body, token, deadline) do
    Kogen.ShapeEvidence.transport(fn ->
      t = System.monotonic_time(:millisecond)
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      Process.delete(:provider_request_id)

      try do
        result = stream_request(body, token, deadline)

        case result do
          {:error, %{status: 400} = error} ->
            if cache_refusal?(error) and
                 Map.has_key?(JSON.decode!(body), "prompt_cache_options"),
               do: Kogen.PromptCache.unsupported()

          _ ->
            :ok
        end

        record_attempt(result, t, timestamp, body)
        result
      catch
        kind, reason ->
          record_attempt(
            {:failed, if(match?({:cancel, _}, reason), do: "cancelled", else: "failed")},
            t,
            timestamp,
            body
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  end

  defp returned_effort(%{"effort" => effort}), do: Kogen.PromptCache.identifier(effort)
  defp returned_effort(_), do: nil

  defp record_attempt(result, t, timestamp, body) do
    {_, _, meta} = Process.get(:prompt_cache_current)
    op = Process.get(:provider_operation)

    r =
      case result do
        {:ok, r} -> r
        _ -> %{}
      end

    response = Map.get(r, :response_metadata, %{})
    completed = match?({:ok, _}, result)

    outcome =
      case result do
        {:ok, _} -> "completed"
        {:failed, "cancelled"} -> "cancelled"
        _ -> "failed"
      end

    cache =
      if completed and meta.cache.status == "requested",
        do: %{
          meta.cache
          | status: "applied",
            applied_mode: "implicit",
            diagnostics: Kogen.PromptCache.diagnostics(response["prompt_cache_diagnostics"])
        },
        else: meta.cache

    cache =
      if Map.has_key?(JSON.decode!(body), "prompt_cache_options"),
        do: cache,
        else: %{cache | boundaries: [], comparison_response_id: nil}

    cache =
      if completed,
        do: %{
          cache
          | diagnostics: Kogen.PromptCache.diagnostics(response["prompt_cache_diagnostics"])
        },
        else: cache

    context = Process.get(:provider_context, %{})
    measured_usage = Map.get(r, :known_usage, known_usage(nil))

    provider =
      Map.merge(
        meta,
        Map.merge(context, %{
          provider: if(supergrok?(), do: "supergrok", else: "chatgpt"),
          operation_id: op.id,
          attempt_id: Kogen.tmp_path("attempt") |> Path.basename(),
          timestamp: timestamp,
          provider_response_id: Kogen.PromptCache.identifier(response["id"]),
          provider_request_id: Process.get(:provider_request_id),
          configured_model: op.model,
          configured_effort: op.effort,
          effective_model: Kogen.PromptCache.identifier(response["model"]),
          effective_effort: returned_effort(response["reasoning"]),
          requested_service_tier: nil,
          effective_service_tier: Kogen.PromptCache.identifier(response["service_tier"]),
          requested_reasoning_context: nil,
          effective_reasoning_context: nil,
          cache: cache,
          usage: measured_usage,
          usage_state:
            if(completed,
              do: Map.get(r, :usage_state, Kogen.Usage.state(measured_usage)),
              else: "unknown"
            ),
          wall_ms: System.monotonic_time(:millisecond) - t,
          ttft_ms: nil,
          outcome: outcome,
          error: if(completed, do: nil, else: "provider_failure")
        })
      )

    if b = Process.get(:kogen_build) do
      Kogen.Run.log(b.run, %{event: "provider_attempt", provider: provider})
    else
      Process.put(:provider_attempt_metadata, provider)
    end

    if completed, do: Kogen.PromptCache.complete(response)
  end

  defp stream_request(body, token, deadline) do
    url =
      String.to_charlist(
        if(supergrok?(), do: Kogen.SuperGrok.api_base(), else: api_base()) <> "/responses"
      )

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"text/event-stream"}
    ]

    headers =
      if supergrok?(),
        do: headers ++ [{~c"user-agent", String.to_charlist(Kogen.SuperGrok.user_agent())}],
        else: headers

    {:ok, ref} =
      :httpc.request(:post, {url, headers, ~c"application/json", body}, http_opts(deadline),
        sync: false,
        stream: :self,
        body_format: :binary
      )

    try do
      collect(
        ref,
        %{
          response_metadata: %{},
          buf: "",
          items: %{},
          pending: MapSet.new(),
          usage: nil,
          done: false,
          failure: nil,
          validation_reasons: [],
          terminal_response_present: false,
          terminal_output_present: false,
          terminal_output_replaced: false,
          observed_index_count: 0
        },
        deadline
      )
    after
      :httpc.cancel_request(ref)
    end
  end

  defp collect(ref, acc, deadline) do
    remaining(deadline)

    receive do
      {:http, {^ref, :stream_start, headers}} ->
        capture_request_id(headers)
        collect(ref, acc, deadline)

      {:http, {^ref, :stream, chunk}} ->
        case events(acc.buf <> chunk, acc) do
          {:ok, acc} ->
            remaining(deadline)
            if acc.done or acc.failure != nil, do: finish(acc), else: collect(ref, acc, deadline)

          {:invalid, detail} ->
            :httpc.cancel_request(ref) && {:invalid, detail}
        end

      {:http, {^ref, :stream_end, _headers}} ->
        remaining(deadline)
        finish(acc)

      {:http, {^ref, {{_, status, _}, headers, body}}} ->
        capture_request_id(headers)
        remaining(deadline)
        http_error(status, body)

      {:http, {^ref, {:error, reason}}} ->
        remaining(deadline)
        {:transient, "network error: #{inspect(reason)}"}

      {:proto, %{"type" => "cancel", "signal" => sig}} ->
        :httpc.cancel_request(ref)
        Bridge.cancelled(sig)
    after
      remaining(deadline) -> expired!()
    end
  end

  defp capture_request_id(headers) do
    id =
      Enum.find_value(headers, fn {k, v} ->
        if String.downcase(to_string(k)) == "x-request-id", do: to_string(v)
      end)

    Process.put(:provider_request_id, Kogen.PromptCache.identifier(id))
  end

  defp finish(%{failure: f}) when f != nil, do: failure(f)
  defp finish(%{done: false}), do: {:transient, "the response stream ended before it completed"}

  defp finish(acc) do
    items = acc.items |> Enum.sort() |> Enum.map(&elem(&1, 1))
    indexes = Map.keys(acc.items) |> Enum.sort()
    contiguous = indexes == Enum.to_list(0..(length(items) - 1)//1)

    reasons =
      acc.validation_reasons
      |> reject_reason(items == [], "empty_output")
      |> reject_reason(not contiguous, "noncontiguous_indexes")
      |> reject_reason(MapSet.size(acc.pending) != 0, "pending_items")
      |> reject_reason(
        Enum.any?(items, &(item_field(&1, "status") not in [nil, "completed"])),
        "item_status"
      )
      |> reject_reason(Enum.any?(items, &(not valid_item?(&1))), "item_shape")
      |> Enum.uniq()
      |> Enum.sort()

    if reasons == [] do
      measured = known_usage(acc.usage)
      usage_state = Kogen.Usage.state(measured)

      {:ok,
       %{
         items: items,
         usage:
           if(usage_state == "inconsistent",
             do: Kogen.Usage.zero(),
             else: usage(acc.usage)
           ),
         known_usage:
           Map.new(measured, fn {k, v} ->
             {k, if(is_integer(v) and v >= 0, do: v)}
           end),
         usage_state: usage_state,
         response_metadata: acc.response_metadata
       }}
    else
      counts = [length(items), MapSet.size(acc.pending), acc.observed_index_count]
      [item_count, pending_count, observed_index_count] = Enum.map(counts, &min(&1, 1024))

      facts = %{
        event_kind: "response.completed",
        done: acc.done,
        terminal_response_present: acc.terminal_response_present,
        terminal_output_present: acc.terminal_output_present,
        terminal_output_replaced: acc.terminal_output_replaced,
        item_count: item_count,
        pending_count: pending_count,
        observed_index_count: observed_index_count,
        counts_capped: Enum.any?(counts, &(&1 > 1024)),
        indexes_contiguous: contiguous,
        item_types:
          aggregate(items, &category(item_field(&1, "type"), ~w(function_call message reasoning))),
        item_statuses:
          aggregate(
            items,
            &category(item_field(&1, "status"), ~w(completed in_progress incomplete failed))
          ),
        arguments_object:
          items
          |> Enum.filter(&(item_field(&1, "type") == "function_call"))
          |> aggregate(&arguments_object/1)
      }

      {:invalid,
       "the completed response has invalid or unfinished output; validation=" <>
         JSON.encode!(%{reasons: reasons, facts: facts})}
    end
  end

  defp reject_reason(reasons, true, reason), do: [reason | reasons]
  defp reject_reason(reasons, false, _reason), do: reasons

  defp item_field(%{} = item, key), do: item[key]
  defp item_field(_, _), do: nil

  defp category(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp category(_, _), do: "unknown"

  defp aggregate(items, fun), do: items |> Enum.map(fun) |> Enum.uniq() |> Enum.sort()

  defp arguments_object(item) do
    case item_field(item, "arguments") do
      args when is_binary(args) ->
        case JSON.decode(args) do
          {:ok, value} when is_map(value) -> "yes"
          _ -> "no"
        end

      _ ->
        "unknown"
    end
  end

  defp known_usage(nil),
    do: Map.new(~w(input cached write write_30m write_12h output reasoning)a, &{&1, nil})

  defp known_usage(u),
    do: %{
      write: optional_count(u, ["input_tokens_details", "cache_write_tokens"]),
      write_30m:
        optional_count(u, ["input_tokens_details", "cache_write_tokens_details", "ttl_30m_tokens"]),
      write_12h:
        optional_count(u, ["input_tokens_details", "cache_write_tokens_details", "ttl_12h_tokens"]),
      input: u["input_tokens"],
      cached: optional_count(u, ["input_tokens_details", "cached_tokens"]),
      output: u["output_tokens"],
      reasoning: optional_count(u, ["output_tokens_details", "reasoning_tokens"])
    }

  defp optional_count(value, []), do: value

  defp optional_count(value, [key | rest]) when is_map(value),
    do: optional_count(value[key], rest)

  defp optional_count(_, _), do: nil

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

  defp valid_usage?(nil), do: true

  defp valid_usage?(%{} = usage) do
    Enum.all?(~w(input_tokens output_tokens), fn key ->
      is_nil(usage[key]) or is_integer(usage[key])
    end) and
      Enum.all?(
        [
          {"input_tokens_details", "cached_tokens"},
          {"output_tokens_details", "reasoning_tokens"}
        ],
        fn {key, count} ->
          case usage[key] do
            nil -> true
            %{} = details -> is_nil(details[count]) or is_integer(details[count])
            _ -> false
          end
        end
      )
  end

  defp valid_usage?(_), do: false

  defp valid_item?(%{
         "type" => "function_call",
         "call_id" => id,
         "name" => name,
         "arguments" => args
       })
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_binary(args) do
    case JSON.decode(args) do
      {:ok, value} when is_map(value) -> true
      _ -> false
    end
  end

  defp valid_item?(%{"type" => "message", "content" => content}) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> true
      %{"type" => "refusal", "refusal" => text} when is_binary(text) -> true
      _ -> false
    end)
  end

  defp valid_item?(%{"type" => "reasoning"}), do: true
  defp valid_item?(_), do: false

  defp apply_event("response.output_item.added", %{"output_index" => i}, acc)
       when is_integer(i) and i >= 0,
       do: %{acc | pending: MapSet.put(acc.pending, i)}

  defp apply_event("response.output_item.done", %{"output_index" => i, "item" => item}, acc)
       when is_integer(i) and i >= 0,
       do: %{acc | items: Map.put(acc.items, i, item), pending: MapSet.delete(acc.pending, i)}

  defp apply_event(type, _ev, acc)
       when type in ["response.output_item.added", "response.output_item.done"],
       do: %{
         acc
         | validation_reasons: reject_reason(acc.validation_reasons, true, "item_event_shape")
       }

  defp apply_event("response.completed", %{"response" => response}, acc) when is_map(response) do
    observed = MapSet.union(MapSet.new(Map.keys(acc.items)), acc.pending)

    reasons =
      acc.validation_reasons
      |> reject_reason(response["status"] not in [nil, "completed"], "response_status")
      |> reject_reason(response["error"] != nil, "response_error")
      |> reject_reason(not valid_usage?(response["usage"]), "usage_shape")

    acc = %{
      acc
      | response_metadata:
          Map.take(response, ~w(id model service_tier reasoning prompt_cache_diagnostics)),
        done: true,
        usage: response["usage"],
        validation_reasons: reasons,
        terminal_response_present: true,
        terminal_output_present: Map.has_key?(response, "output"),
        observed_index_count: MapSet.size(observed)
    }

    case Map.fetch(response, "output") do
      :error ->
        acc

      {:ok, []} ->
        acc

      {:ok, output} when is_list(output) ->
        items = output |> Enum.with_index() |> Map.new(fn {item, i} -> {i, item} end)
        indexes = MapSet.new(Map.keys(items))

        %{
          acc
          | items: items,
            pending: MapSet.new(),
            terminal_output_replaced: true,
            validation_reasons:
              reject_reason(
                reasons,
                not MapSet.subset?(observed, indexes),
                "terminal_index_coverage"
              )
        }

      _ ->
        %{acc | validation_reasons: reject_reason(reasons, true, "terminal_output_shape")}
    end
  end

  defp apply_event("response.completed", _ev, acc),
    do: %{
      acc
      | done: true,
        observed_index_count:
          MapSet.size(MapSet.union(MapSet.new(Map.keys(acc.items)), acc.pending)),
        validation_reasons: reject_reason(acc.validation_reasons, true, "terminal_envelope")
    }

  defp apply_event("response.incomplete", ev, acc),
    do: %{
      acc
      | failure:
          {%{
             "code" => "incomplete",
             "message" => inspect(get_in(ev, ["response", "incomplete_details"]))
           }, "response.incomplete"}
    }

  defp apply_event("response.failed", ev, acc),
    do: %{acc | failure: {get_in(ev, ["response", "error"]) || %{}, "response.failed"}}

  defp apply_event("error", ev, acc),
    do: %{acc | failure: {ev["error"] || Map.delete(ev, "type"), "error"}}

  defp apply_event(_type, _ev, acc), do: acc

  # A failure reported inside the stream.
  defp failure({f, event_kind}) do
    f = if is_map(f), do: f, else: %{}

    error = %{
      status: "stream",
      code: f["code"],
      type: f["type"],
      event_kind: event_kind,
      param: f["param"],
      message: text(f["message"]),
      resets_at: f["resets_at"]
    }

    cond do
      f["code"] in [
        "server_error",
        "rate_limit_exceeded",
        "subscription_sharing_usage_unavailable",
        "subscription_sharing_user_unavailable"
      ] ->
        {:transient,
         %{detail: "#{f["code"]}: #{text(f["message"])}", provider_failure: diagnostics(error)}}

      true ->
        {:error, error}
    end
  end

  defp http_error(status, body) do
    {err, detail} =
      case JSON.decode(body) do
        {:ok, %{"error" => %{} = e}} -> {e, text(e["message"] || e["code"])}
        {:ok, %{"detail" => d}} -> {%{}, text(d)}
        _ -> {%{}, String.slice(body, 0, 200)}
      end

    error = %{
      status: status,
      code: err["code"],
      type: err["type"],
      param: err["param"],
      message: detail,
      resets_at: err["resets_at"]
    }

    cond do
      status == 401 ->
        {:unauthorized, error}

      not supergrok?() and err["code"] == "subscription_sharing_usage_limit_exceeded" ->
        {:error, error}

      status == 429 or status >= 500 ->
        {:transient,
         %{
           detail: "HTTP #{status} #{detail}" |> String.trim_trailing(),
           provider_failure: diagnostics(error)
         }}

      true ->
        {:error, error}
    end
  end
end
