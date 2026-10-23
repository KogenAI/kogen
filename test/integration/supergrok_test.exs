Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.SuperGrokTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Kogen.{Error, Provider, SuperGrok, Integration.FakeProvider}
  @moduletag :integration
  @credentials %{
    "client_id" => "synthetic-client",
    "referrer" => "kogen",
    "access_token" => "synthetic-access",
    "refresh_token" => "synthetic-refresh",
    "expires_at" => 0,
    "scope" => "api:access"
  }

  setup do
    home = Kogen.tmp_path("supergrok-test")
    dir = Path.join(home, ".kogen/credentials")
    File.mkdir_p!(dir)
    path = Path.join(dir, "supergrok.json")
    release_root = System.get_env("RELEASE_ROOT")
    System.put_env("RELEASE_ROOT", home)
    File.write!(Path.join(home, "VERSION"), "kogen dev+12345678 (test)\n")
    previous = :persistent_term.get(:kogen_caller, nil)

    on_exit(fn ->
      if release_root,
        do: System.put_env("RELEASE_ROOT", release_root),
        else: System.delete_env("RELEASE_ROOT")

      if previous,
        do: :persistent_term.put(:kogen_caller, previous),
        else: :persistent_term.erase(:kogen_caller)

      File.rm_rf!(home)
    end)

    {:ok, home: home, path: path}
  end

  defp connect(home, script) do
    server = FakeProvider.start(script)
    origin = "http://127.0.0.1:#{server.port}"

    :persistent_term.put(:kogen_caller, %{
      env: %{"HOME" => home, "KOGEN_AUTH_URL" => origin, "KOGEN_PROVIDER_URL" => origin}
    })

    on_exit(fn -> FakeProvider.stop(server) end)
    server
  end

  test "selected roles check only their own providers; saved borrowed login is refused offline",
       c do
    server = connect(c.home, [])
    role = %{provider: "supergrok", model: "grok-4.7", effort: "low"}
    error = assert_raise Error, fn -> Provider.require_roles!([role]) end
    assert error.detail == "not signed in; run kogen provider login supergrok"
    File.write!(c.path, JSON.encode!(@credentials))
    assert Provider.require_roles!([role]) == :ok

    error =
      assert_raise Error, fn ->
        Provider.require_roles!([role, %{model: "fixture", effort: "medium"}])
      end

    assert error.detail == "not signed in; run kogen provider login chatgpt"
    File.write!(c.path, JSON.encode!(%{@credentials | "referrer" => "borrowed"}))
    error = assert_raise Error, fn -> Provider.require_roles!([role]) end
    assert error.detail == "saved login cannot be used; run kogen provider login supergrok"
    assert FakeProvider.auth_requests(server) == []
    assert FakeProvider.provider_requests(server) == []
  end

  test "refresh rotates privately, re-reads newer credentials under the lock and defaults expiry",
       c do
    server =
      connect(c.home, [
        {:json, 200, %{"access_token" => "new-access", "refresh_token" => "new-refresh"}}
      ])

    File.write!(c.path, JSON.encode!(@credentials))
    before = System.system_time(:second)
    deadline = System.monotonic_time(:millisecond) + 3000
    assert SuperGrok.access_token(deadline) == "new-access"
    saved = c.path |> File.read!() |> JSON.decode!()
    assert saved["refresh_token"] == "new-refresh"
    assert saved["expires_at"] in (before + 3600)..(System.system_time(:second) + 3600)
    assert SuperGrok.refreshed("synthetic-access", :after_401, deadline) == "new-access"
    assert [%{json: form}] = FakeProvider.auth_requests(server)

    assert form == %{
             "grant_type" => "refresh_token",
             "refresh_token" => "synthetic-refresh",
             "client_id" => "synthetic-client"
           }

    assert Bitwise.band(File.stat!(c.path).mode, 0o777) == 0o600
    refute File.exists?(Path.rootname(c.path) <> ".lock")
  end

  for {reason, code, message} <- [
        {:proactive, "temporarily_unavailable",
         "the SuperGrok sign-in expired and could not be refreshed"},
        {:proactive, "invalid_grant", "the SuperGrok sign-in was rejected"},
        {:after_401, "temporarily_unavailable", "the SuperGrok sign-in was rejected"}
      ] do
    @reason reason
    @code code
    @message message
    test "refresh failure #{@reason}/#{@code} retains earlier bytes", c do
      connect(c.home, [{:json, 400, %{"error" => @code}}])
      bytes = JSON.encode!(@credentials)
      File.write!(c.path, bytes)

      error =
        assert_raise Error, fn ->
          SuperGrok.refreshed(
            "synthetic-access",
            @reason,
            System.monotonic_time(:millisecond) + 3000
          )
        end

      assert error.detail == @message <> "; run kogen provider login supergrok"
      assert File.read!(c.path) == bytes
      refute File.exists?(Path.rootname(c.path) <> ".lock")
    end
  end

  test "exact codeless generation errors require empty code and subtype on SuperGrok", c do
    File.write!(
      c.path,
      JSON.encode!(%{@credentials | "expires_at" => System.system_time(:second) + 3600})
    )

    message = "Internal error during token generation"

    cases = [
      {%{"message" => message}, "unavailable"},
      {%{"code" => nil, "type" => nil, "message" => message}, "unavailable"},
      {%{"code" => "", "type" => "", "message" => message}, "unavailable"},
      {%{"code" => "unknown_capacity", "message" => message}, "refused"},
      {%{"code" => %{}, "message" => message}, "refused"},
      {%{"type" => "service_unavailable_error", "message" => message}, "refused"},
      {%{"message" => message <> " later"}, "refused"}
    ]

    frames =
      Enum.flat_map(cases, fn {error, reason} ->
        failure = {:events, [%{"type" => "response.failed", "response" => %{"error" => error}}]}
        if reason == "unavailable", do: [failure, {:text, "recovered"}], else: [failure]
      end)

    server = connect(c.home, frames)

    for {_, reason} <- cases do
      call = fn ->
        Kogen.ChatGPT.respond(
          %{provider: "supergrok", model: "grok-4.7", effort: "low"},
          "policy",
          [],
          []
        )
      end

      if reason == "unavailable" do
        assert call.().items != []
      else
        error = assert_raise Error, call
        assert error.reason == reason
      end
    end

    assert length(FakeProvider.provider_requests(server)) == 10
  end

  test "SuperGrok workers refresh once after 401 and preserve routed attempt identity", c do
    server =
      connect(c.home, [
        {:http, 401, %{"error" => %{"code" => "unauthorized"}}},
        {:json, 200, %{"access_token" => "new-access", "expires_in" => 60}},
        {:text, "completed"}
      ])

    File.write!(
      c.path,
      JSON.encode!(%{@credentials | "expires_at" => System.system_time(:second) + 3600})
    )

    result =
      Kogen.ChatGPT.respond(
        %{provider: "supergrok", model: "grok-4.7", effort: "low"},
        "policy",
        [],
        [],
        single_attempt: true
      )

    assert result.items != []
    assert length(FakeProvider.provider_requests(server)) == 2
    assert length(FakeProvider.auth_requests(server)) == 1
    assert Process.get(:provider_attempt_metadata).provider == "supergrok"
    assert Process.get(:provider_attempt_metadata).cache.status == "unknown"
    assert (c.path |> File.read!() |> JSON.decode!())["refresh_token"] == "synthetic-refresh"
  end

  for {status, error} <- [
        {400, %{"message" => "Internal error during token generation"}},
        {400, %{"code" => "unknown_parameter", "param" => "other"}},
        {400, %{"code" => "invalid_parameter", "param" => "prompt_cache_key"}},
        {400, %{"message" => "unsupported prompt_cache_key"}},
        {402, %{"code" => "unknown_parameter", "param" => "prompt_cache_key"}},
        {403, %{"code" => "unsupported_parameter", "param" => "prompt_cache_key"}}
      ] do
    test "HTTP #{status} #{JSON.encode!(error)} does not permit changing cache requests", c do
      server =
        connect(c.home, [{:http, unquote(status), %{"error" => unquote(Macro.escape(error))}}])

      File.write!(
        c.path,
        JSON.encode!(%{@credentials | "expires_at" => System.system_time(:second) + 3600})
      )

      role = %{provider: "supergrok", model: "grok-4.7", effort: "high"}
      assert_raise Error, fn -> Kogen.ChatGPT.respond(role, "policy", [], []) end
      assert length(FakeProvider.provider_requests(server)) == 1
      assert FakeProvider.auth_requests(server) == []
      assert Kogen.ChatGPT.request_body(role, "policy", [], [])["prompt_cache_key"]
      assert Process.get(:provider_attempt_metadata).outcome == "failed"
      assert Process.get(:provider_attempt_metadata).usage_state == "unknown"
    end
  end

  test "device lifetime expires while a token poll is still in flight", c do
    server =
      connect(c.home, [
        {:json, 200,
         %{
           "device_code" => "synthetic-device",
           "user_code" => "USER",
           "verification_uri" => "https://example.test/verify",
           "expires_in" => 2,
           "interval" => 1
         }},
        {:open_events, self(), []}
      ])

    bytes = JSON.encode!(@credentials)
    File.write!(c.path, bytes)

    capture_io(fn ->
      error = assert_raise Error, fn -> SuperGrok.login() end
      assert error.reason == "login_failed"
      assert error.detail == "the SuperGrok sign-in code expired"
    end)

    assert_receive {:provider_open, _}
    assert_receive {:provider_closed, {:error, :closed}}, 1000
    assert length(FakeProvider.auth_requests(server)) == 2
    assert File.read!(c.path) == bytes
  end

  test "absent scope and interval use RFC defaults; id token never persists", c do
    server =
      connect(c.home, [
        {:json, 200,
         %{
           "device_code" => "synthetic-device",
           "user_code" => "USER",
           "verification_uri" => "https://example.test/verify",
           "expires_in" => 20
         }},
        {:json, 200,
         %{
           "access_token" => "synthetic-access",
           "refresh_token" => "synthetic-refresh",
           "id_token" =>
             "unused." <>
               Base.url_encode64(JSON.encode!(%{"email" => "test@example.com"}), padding: false) <>
               ".unused"
         }}
      ])

    before = System.monotonic_time(:millisecond)
    capture_io(fn -> assert SuperGrok.login() == 0 end)
    assert System.monotonic_time(:millisecond) - before >= 5000
    saved = c.path |> File.read!() |> JSON.decode!()
    assert saved["scope"] == "openid profile email offline_access grok-cli:access api:access"
    assert saved["email"] == "test@example.com"

    assert Enum.sort(Map.keys(saved)) ==
             ~w(access_token client_id email expires_at referrer refresh_token scope)

    assert length(FakeProvider.auth_requests(server)) == 2
  end
end
