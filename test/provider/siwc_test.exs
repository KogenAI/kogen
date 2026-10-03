defmodule Kogen.Provider.ChatGPT.SIWCTest do
  use Kogen.Testkit.Case

  alias Kogen.Provider.ChatGPT.Callback
  alias Kogen.Provider.ChatGPT.CredentialStore
  alias Kogen.Provider.ChatGPT.FileStore
  alias Kogen.Provider.ChatGPT.HostId
  alias Kogen.Provider.ChatGPT.PKCE
  alias Kogen.Provider.ChatGPT.Refresh
  alias Kogen.Provider.ChatGPT.SIWC
  alias Kogen.Testkit.FakeOAuthServer

  test "creates a valid PKCE verifier and S256 challenge" do
    %{verifier: verifier, challenge: challenge} = PKCE.generate()

    assert byte_size(verifier) >= 43
    assert byte_size(verifier) <= 128

    assert challenge ==
             verifier
             |> then(&:crypto.hash(:sha256, &1))
             |> Base.url_encode64(padding: false)
  end

  test "rejects a callback whose state does not match the login attempt" do
    assert {:error, :state_mismatch} =
             Callback.validate(
               "code=sample-code&state=wrong-state&client_id=oaiapp_sample",
               "expected-state",
               :registration
             )
  end

  test "constructs the documented registration parameters" do
    pkce = %{challenge: "challenge-value", nonce: "nonce-value"}

    url =
      SIWC.authorization_url(
        "http://127.0.0.1:1455/auth/callback",
        "urn:uuid:stable-host-id",
        "state-value",
        pkce,
        :registration
      )

    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert URI.parse(url).host == "auth.openai.com"
    assert params["client_id"] == "dynamic_agent_client"
    assert params["agent_name_hint"] == "Kogen"
    assert params["ext_agent_host_id"] == "urn:uuid:stable-host-id"
    assert params["redirect_uri"] == "http://127.0.0.1:1455/auth/callback"
    assert params["response_type"] == "code"
    assert params["code_challenge_method"] == "S256"
    assert params["code_challenge"] == "challenge-value"
    assert params["resource"] == "https://api.openai.com/v1"

    assert params["scope"] ==
             "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  end

  test "file credential storage round trips with owner-only permissions", %{tmp_dir: tmp_dir} do
    credentials = %CredentialStore{
      client_id: "oaiapp_test",
      access_token: "access-test",
      refresh_token: "refresh-test",
      id_token: "id-test",
      expires_at: 4_102_444_800,
      scopes: ["chatgpt.tokens.use.direct", "offline_access"],
      subject: "subject-test",
      email: "test@example.invalid",
      host_id: "urn:uuid:host-test"
    }

    assert :ok = CredentialStore.save(tmp_dir, :file, "personal", credentials)
    assert {:ok, ^credentials} = CredentialStore.load(tmp_dir, :file, "personal")
    assert {:ok, stat} = File.stat(FileStore.path(tmp_dir, "personal"))
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "completes sign in against local authorization and token servers", %{tmp_dir: tmp_dir} do
    {state, server, port, counter} = start_fake_login_server()

    on_exit(fn ->
      FakeOAuthServer.stop({server, port, counter})
    end)

    authorize = fn url -> authorize_loopback(url, state) end
    endpoint = "http://127.0.0.1:#{port}"

    options = [
      callback_port: 0,
      discovery_url: endpoint <> "/discovery",
      token_endpoint: endpoint <> "/token",
      authorize: authorize
    ]

    assert {:ok, %{label: "personal", email: "offline@example.invalid", first_notice?: true}} =
             SIWC.login(tmp_dir, :file, "personal", options)

    assert_receive {:callback_result, :ok}

    assert {:ok, first_host_id} = HostId.get_or_create(tmp_dir)

    assert {:ok, %CredentialStore{client_id: "oaiapp_offline", subject: "offline-subject"}} =
             CredentialStore.load(tmp_dir, :file, "personal")

    assert {:ok, %{first_notice?: false}} = SIWC.login(tmp_dir, :file, "personal", options)
    assert_receive {:callback_result, :ok}
    assert {:ok, ^first_host_id} = HostId.get_or_create(tmp_dir)
    assert Agent.get(counter, & &1) == 6
  end

  test "refresh locking rereads the rotated credential before a second refresh", %{
    tmp_dir: tmp_dir
  } do
    now = System.system_time(:second)

    credentials = %CredentialStore{
      client_id: "oaiapp_refresh",
      access_token: "access-old",
      refresh_token: "refresh-old",
      id_token: "id-old",
      expires_at: now - 10,
      scopes: ["chatgpt.tokens.use.direct"],
      subject: "subject-refresh",
      email: nil,
      host_id: "urn:uuid:host-refresh"
    }

    assert :ok = CredentialStore.save(tmp_dir, :file, "work", credentials)

    {server, port, counter} =
      FakeOAuthServer.start(fn request ->
        receive do
        after
          100 -> :ok
        end

        assert request.method == "POST"
        assert request.path == "/token"
        assert request.form["grant_type"] == "refresh_token"
        assert request.form["client_id"] == "oaiapp_refresh"
        assert request.form["refresh_token"] == "refresh-old"
        assert request.form["resource"] == "https://api.openai.com/v1"
        refute Map.has_key?(request.form, "scope")

        {200,
         json(%{
           "access_token" => "access-new",
           "refresh_token" => "refresh-new",
           "expires_in" => 3600
         })}
      end)

    on_exit(fn -> FakeOAuthServer.stop({server, port, counter}) end)
    endpoint = "http://127.0.0.1:#{port}/token"

    results =
      1..2
      |> Task.async_stream(
        fn _ -> Refresh.access_token(tmp_dir, :file, "work", token_endpoint: endpoint) end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, fn
             {:ok, %CredentialStore{access_token: "access-new", refresh_token: "refresh-new"}} ->
               true

             _other ->
               false
           end)

    assert Agent.get(counter, & &1) == 1
    assert {:ok, %{access_token: "access-new"}} = CredentialStore.load(tmp_dir, :file, "work")
  end

  defp json(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  defp start_fake_login_server do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:ok, state} = Agent.start_link(fn -> %{} end)
    jwk = jwk(private_key)

    {server, port, counter} =
      FakeOAuthServer.start(fn request ->
        fake_login_response(request, state, private_key, jwk)
      end)

    endpoint = "http://127.0.0.1:#{port}"
    Agent.update(state, &Map.put(&1, :endpoint, endpoint))
    {state, server, port, counter}
  end

  defp fake_login_response(%{method: "GET", path: "/discovery"}, state, _private_key, _jwk) do
    endpoint = Agent.get(state, & &1.endpoint)

    {200,
     json(%{
       "issuer" => "https://auth.openai.com",
       "jwks_uri" => endpoint <> "/jwks",
       "revocation_endpoint" => endpoint <> "/revoke"
     })}
  end

  defp fake_login_response(%{method: "GET", path: "/jwks"}, _state, _private_key, jwk),
    do: {200, json(%{"keys" => [jwk]})}

  defp fake_login_response(
         %{method: "POST", path: "/token", form: form},
         state,
         private_key,
         _jwk
       ) do
    auth = Agent.get(state, & &1)
    assert form["client_id"] == "oaiapp_offline"
    assert form["code"] == "offline-code"
    assert form["resource"] == "https://api.openai.com/v1"

    assert Base.url_encode64(:crypto.hash(:sha256, form["code_verifier"]), padding: false) ==
             auth.challenge

    {200,
     json(%{
       "access_token" => "offline-access-token",
       "refresh_token" => "offline-refresh-token",
       "id_token" => signed_id_token(private_key, auth.nonce),
       "expires_in" => 3600,
       "scope" => "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
     })}
  end

  defp authorize_loopback(url, state) do
    caller = self()
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert URI.parse(url).host == "auth.openai.com"

    assert params["agent_name_hint"] ==
             if(params["client_id"] == "dynamic_agent_client", do: "Kogen")

    Agent.update(state, fn current ->
      Map.merge(current, %{nonce: params["nonce"], challenge: params["code_challenge"]})
    end)

    client =
      if params["client_id"] == "dynamic_agent_client",
        do: [{"client_id", "oaiapp_offline"}],
        else: []

    callback =
      params["redirect_uri"] <>
        "?" <> URI.encode_query([{"code", "offline-code"}, {"state", params["state"]} | client])

    {:ok, _apps} = Application.ensure_all_started(:inets)

    {:ok, _pid} =
      Task.start(fn -> send(caller, {:callback_result, callback_request(callback)}) end)

    :ok
  end

  defp callback_request(callback) do
    case :httpc.request(:get, {String.to_charlist(callback), []}, [timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_version, 200, _reason}, _headers, _body}} -> :ok
      _failure -> {:error, :callback_failed}
    end
  end

  defp jwk(private_key) do
    modulus = elem(private_key, 2)
    exponent = elem(private_key, 3)

    %{
      "kty" => "RSA",
      "kid" => "offline-key",
      "n" => Base.url_encode64(:binary.encode_unsigned(modulus), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(exponent), padding: false)
    }
  end

  defp signed_id_token(private_key, nonce) do
    header = %{"alg" => "RS256", "kid" => "offline-key"}

    claims = %{
      "iss" => "https://auth.openai.com",
      "aud" => "oaiapp_offline",
      "exp" => System.system_time(:second) + 3600,
      "nonce" => nonce,
      "sub" => "offline-subject",
      "email" => "offline@example.invalid"
    }

    signing_input =
      Enum.map_join([header, claims], ".", &(&1 |> json() |> Base.url_encode64(padding: false)))

    signature = :public_key.sign(signing_input, :sha256, private_key)
    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end
end
