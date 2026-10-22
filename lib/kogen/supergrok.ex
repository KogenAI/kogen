defmodule Kogen.SuperGrok do
  @moduledoc "Kogen-owned SuperGrok device authorization and private refreshed credentials."
  alias Kogen.{Bridge, Error, Lock}
  @client "b1a00492-073a-47ea-816f-4c329264a828"
  @scope "openid profile email offline_access grok-cli:access api:access"
  def user_agent, do: "kogen/" <> (Kogen.version() |> String.split() |> Enum.at(1))
  defp now, do: System.system_time(:second)
  defp clock, do: System.monotonic_time(:millisecond)
  defp path, do: Path.join(Kogen.caller().env["HOME"], ".kogen/credentials/supergrok.json")
  defp auth, do: Kogen.caller().env["KOGEN_AUTH_URL"] || "https://auth.x.ai"
  def api_base, do: (Kogen.caller().env["KOGEN_PROVIDER_URL"] || "https://api.x.ai") <> "/v1"
  defp fail(reason, message), do: Error.raise!("provider", reason, message, 4)
  defp login_failed(message), do: fail("login_failed", message)
  defp suffix(email) when is_binary(email) and email != "", do: " (#{email})"
  defp suffix(_), do: ""

  defp read do
    case File.read(path()) do
      {:error, :enoent} ->
        nil

      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, value} when is_map(value) -> value
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp nonempty(v), do: is_binary(v) and v != ""

  defp usable(c),
    do:
      is_map(c) and Enum.all?(~w(client_id access_token refresh_token), &nonempty(c[&1])) and
        is_integer(c["expires_at"]) and c["referrer"] == "kogen"

  def status do
    c = read()

    text =
      cond do
        c == nil -> "not signed in"
        usable(c) -> "signed in" <> suffix(c["email"])
        true -> "saved login cannot be used; run kogen provider login supergrok"
      end

    Bridge.puts("supergrok: " <> text)
    0
  end

  def require_login! do
    c = read()

    cond do
      c == nil ->
        fail("login", "not signed in; run kogen provider login supergrok")

      not usable(c) ->
        fail("login", "saved login cannot be used; run kogen provider login supergrok")

      true ->
        c
    end
  end

  defp write(c) do
    dir = Path.dirname(path())
    File.mkdir_p!(dir)
    File.chmod!(Path.dirname(dir), 0o700)
    File.chmod!(dir, 0o700)
    tmp = path() <> "." <> Base.encode16(:crypto.strong_rand_bytes(8))
    File.write!(tmp, "", [:exclusive])
    File.chmod!(tmp, 0o600)
    File.write!(tmp, JSON.encode!(c))
    File.rename!(tmp, path())
  end

  defp locked(deadline, fun) do
    lock = Path.rootname(path()) <> ".lock"

    case Lock.acquire(lock) do
      {:held, _} ->
        wait(100, deadline)
        locked(deadline, fun)

      _ ->
        try do
          fun.()
        after
          Lock.release(lock)
        end
    end
  end

  defp https?(s) when is_binary(s) do
    uri = URI.parse(s)
    uri.scheme == "https" and nonempty(uri.host)
  end

  defp https?(_), do: false

  def login do
    {status, device} =
      post("/oauth2/device/code", %{
        "client_id" => @client,
        "scope" => @scope,
        "referrer" => "kogen"
      })

    received = clock()

    if status != 200,
      do:
        login_failed(
          "the SuperGrok device authorization request failed (#{answer(status, device)})"
        )

    unless Enum.all?(~w(device_code user_code verification_uri), &nonempty(device[&1])) and
             is_integer(device["expires_in"]) and device["expires_in"] > 0,
           do: login_failed("the SuperGrok device authorization response is incomplete")

    unless https?(device["verification_uri"]) and
             (not Map.has_key?(device, "verification_uri_complete") or
                https?(device["verification_uri_complete"])),
           do: login_failed("the SuperGrok verification address is not HTTPS")

    Bridge.puts("Continue with SuperGrok")
    Bridge.puts(device["verification_uri_complete"] || device["verification_uri"])
    Bridge.puts("Code: " <> device["user_code"])
    interval = max(device["interval"] || 5, 1) * 1000
    tok = poll(device["device_code"], interval, received + device["expires_in"] * 1000)

    unless nonempty(tok["access_token"]) and nonempty(tok["refresh_token"]),
      do: login_failed("the SuperGrok sign-in returned no usable tokens")

    scope = tok["scope"] || @scope

    unless "api:access" in String.split(scope),
      do: login_failed("SuperGrok API access was not granted; sign in again and allow it")

    c = %{
      "client_id" => @client,
      "referrer" => "kogen",
      "access_token" => tok["access_token"],
      "refresh_token" => tok["refresh_token"],
      "expires_at" => now() + (tok["expires_in"] || 3600),
      "scope" => scope
    }

    email = claims(tok["id_token"])["email"]
    c = if is_binary(email), do: Map.put(c, "email", email), else: c
    locked(nil, fn -> write(c) end)
    Bridge.puts("supergrok signed in" <> suffix(email))
    0
  end

  defp claims(jwt) do
    with [_, payload | _] <- String.split(jwt || "", "."),
         {:ok, bytes} <- Base.url_decode64(payload, padding: false),
         {:ok, map} when is_map(map) <- JSON.decode(bytes),
         do: map,
         else: (_ -> %{})
  end

  defp answer(status, body),
    do: "#{status}" <> if(nonempty(body["error"]), do: " " <> body["error"], else: "")

  defp expired, do: login_failed("the SuperGrok sign-in code expired")

  defp poll(code, interval, deadline) do
    wait(min(interval, max(deadline - clock(), 0)), nil)
    if clock() >= deadline, do: expired()

    {status, tok} =
      post(
        "/oauth2/token",
        %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => code,
          "client_id" => @client
        },
        nil,
        deadline
      )

    if clock() >= deadline, do: expired()

    cond do
      status == 200 ->
        tok

      tok["error"] == "authorization_pending" ->
        poll(code, interval, deadline)

      tok["error"] == "slow_down" ->
        poll(code, interval + 5000, deadline)

      tok["error"] in ~w(access_denied authorization_denied) ->
        login_failed("the SuperGrok sign-in was denied")

      tok["error"] == "expired_token" ->
        expired()

      true ->
        login_failed("the SuperGrok token request failed (#{answer(status, tok)})")
    end
  end

  def access_token(deadline) do
    c = require_login!()

    if c["expires_at"] - 60 <= now(),
      do: refreshed(c["access_token"], :proactive, deadline),
      else: c["access_token"]
  end

  def rejected!,
    do: fail("login", "the SuperGrok sign-in was rejected; run kogen provider login supergrok")

  def refreshed(stale, reason, deadline) do
    locked(deadline, fn ->
      c = require_login!()

      if c["access_token"] != stale and c["expires_at"] - 60 > now() do
        c["access_token"]
      else
        {status, tok} =
          post(
            "/oauth2/token",
            %{
              "grant_type" => "refresh_token",
              "refresh_token" => c["refresh_token"],
              "client_id" => c["client_id"]
            },
            deadline
          )

        cond do
          status == 200 and nonempty(tok["access_token"]) ->
            write(%{
              c
              | "access_token" => tok["access_token"],
                "refresh_token" => tok["refresh_token"] || c["refresh_token"],
                "expires_at" => now() + (tok["expires_in"] || 3600)
            })

            tok["access_token"]

          tok["error"] == "invalid_grant" or reason == :after_401 ->
            rejected!()

          true ->
            fail(
              "login",
              "the SuperGrok sign-in expired and could not be refreshed; run kogen provider login supergrok"
            )
        end
      end
    end)
  end

  defp wait(ms, deadline) do
    receive do
      {:proto, %{"type" => "cancel", "signal" => sig}} -> Bridge.cancelled(sig)
    after
      ms -> if deadline, do: Kogen.ChatGPT.remaining(deadline)
    end
  end

  defp post(endpoint, form, deadline \\ nil, device_deadline \\ nil) do
    req =
      {String.to_charlist(auth() <> endpoint),
       [{~c"accept", ~c"application/json"}, {~c"user-agent", String.to_charlist(user_agent())}],
       ~c"application/x-www-form-urlencoded", URI.encode_query(form)}

    {:ok, ref} =
      :httpc.request(:post, req, Kogen.ChatGPT.http_opts(deadline),
        sync: false,
        body_format: :binary
      )

    try do
      receive do
        {:http, {^ref, {{_, status, _}, _, body}}} ->
          {status,
           case JSON.decode(body) do
             {:ok, m} when is_map(m) -> m
             _ -> %{}
           end}

        {:http, {^ref, {:error, _}}} ->
          {0, %{}}

        {:proto, %{"type" => "cancel", "signal" => sig}} ->
          Bridge.cancelled(sig)
      after
        if(device_deadline,
          do: max(device_deadline - clock(), 0),
          else: Kogen.ChatGPT.remaining(deadline)
        ) ->
          if device_deadline, do: expired(), else: Kogen.ChatGPT.remaining(deadline)
      end
    after
      :httpc.cancel_request(ref)
    end
  end
end
