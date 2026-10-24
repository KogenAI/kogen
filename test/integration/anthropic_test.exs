defmodule Kogen.Integration.AnthropicTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Kogen.{Anthropic, Error, Lock}
  @moduletag :integration
  setup do
    home = Kogen.tmp_path("anthropic-test")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "VERSION"), "local fixture\n")
    old = :persistent_term.get(:kogen_caller, nil)
    release = System.get_env("RELEASE_ROOT")
    System.put_env("RELEASE_ROOT", home)
    :persistent_term.put(:kogen_caller, %{env: %{"HOME" => home}})

    on_exit(fn ->
      if old,
        do: :persistent_term.put(:kogen_caller, old),
        else: :persistent_term.erase(:kogen_caller)

      if release,
        do: System.put_env("RELEASE_ROOT", release),
        else: System.delete_env("RELEASE_ROOT")

      File.rm_rf!(home)
    end)

    %{home: home, path: Path.join(home, ".kogen/credentials/anthropic.json")}
  end

  defp supply(value),
    do: send(self(), {:proto, %{"type" => "secret_input", "ok" => true, "value" => value}})

  test "private login preserves bytes on invalid input, interruption, cancellation and contention",
       c do
    supply("  SYNTHETIC_LOCAL_KEY\t\r\n")
    output = capture_io(fn -> assert Anthropic.login() == 0 end)
    refute output =~ "SYNTHETIC_LOCAL_KEY"
    assert output =~ "anthropic: key saved (not verified)"
    bytes = File.read!(c.path)
    assert JSON.decode!(bytes) == %{"provider" => "anthropic", "api_key" => "SYNTHETIC_LOCAL_KEY"}

    for input <- ["", "\n", "a\nb\n", "a\n\n", "a\0b", "a\tb", "a\u0085b", <<255>>] do
      supply(input)
      capture_io(fn -> assert_raise Error, fn -> Anthropic.login() end end)
      assert File.read!(c.path) == bytes
    end

    send(self(), {:proto, %{"type" => "secret_input", "ok" => false}})
    capture_io(fn -> assert_raise Error, fn -> Anthropic.login() end end)
    assert File.read!(c.path) == bytes

    for sig <- ~w(SIGINT SIGTERM SIGHUP) do
      send(self(), {:proto, %{"type" => "cancel", "signal" => sig}})
      capture_io(fn -> assert catch_throw(Anthropic.login()) == {:cancel, sig} end)
      assert File.read!(c.path) == bytes
    end

    lock = Path.rootname(c.path) <> ".lock"
    assert Lock.acquire(lock) == :ok
    supply("new-key\n")
    capture_io(fn -> assert_raise Error, fn -> Anthropic.login() end end)
    assert File.read!(c.path) == bytes
    Lock.release(lock)
    File.write!(c.path, JSON.encode!(%{provider: "anthropic", api_key: "   "}))
    assert_raise Error, ~r/kogen provider login anthropic/, &Anthropic.require_login!/0
    assert capture_io(&Anthropic.status/0) =~ "anthropic: not signed in"
  end

  test "native errors and opaque identifiers cannot echo credentials and waits close the socket",
       c do
    File.mkdir_p!(Path.dirname(c.path))
    key = "SYNTHETIC_SOCKET_KEY"
    File.write!(c.path, JSON.encode!(%{provider: "anthropic", api_key: key}))

    for mode <- [:cancel, :deadline, :completed, 401, 429, 529, 400] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      owner = self()

      server =
        spawn(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, request} = :gen_tcp.recv(socket, 0, 2000)
          send(owner, {:request, request})

          cond do
            mode == :completed ->
              events = [
                %{"type" => "message_start", "message" => %{"id" => key, "model" => key}},
                %{
                  "type" => "content_block_start",
                  "index" => 0,
                  "content_block" => %{"type" => "text", "text" => "Answer"}
                },
                %{"type" => "content_block_stop", "index" => 0},
                %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
                %{"type" => "message_stop"}
              ]

              bytes =
                Enum.map_join(events, &"event: #{&1["type"]}\ndata: #{JSON.encode!(&1)}\n\n")

              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nrequest-id: #{key}\r\nTransfer-Encoding: chunked\r\n\r\n"
              )

              for chunk <- Enum.chunk_every(:binary.bin_to_list(bytes), 13),
                  do:
                    :gen_tcp.send(socket, [
                      Integer.to_string(length(chunk), 16),
                      "\r\n",
                      chunk,
                      "\r\n"
                    ])

            is_integer(mode) ->
              bytes = JSON.encode!(%{error: %{type: key, message: key}})

              :gen_tcp.send(
                socket,
                "HTTP/1.1 #{mode} Error\r\nContent-Type: application/json\r\nrequest-id: #{key}\r\nContent-Length: #{byte_size(bytes)}\r\nConnection: close\r\n\r\n#{bytes}"
              )

              :gen_tcp.close(socket)

            mode == :cancel ->
              send(owner, {:proto, %{"type" => "cancel", "signal" => "SIGINT"}})

            true ->
              :ok
          end

          unless is_integer(mode), do: send(owner, {:closed, :gen_tcp.recv(socket, 0, 2000)})
          :gen_tcp.close(socket)
        end)

      :persistent_term.put(:kogen_caller, %{
        env: %{"HOME" => c.home, "KOGEN_PROVIDER_URL" => "http://127.0.0.1:#{port}"}
      })

      try do
        invoke = fn ->
          Kogen.ChatGPT.respond(
            %{provider: "anthropic", model: "claude-opus-5-5", effort: "high"},
            "policy",
            [],
            [],
            response_budget_ms: 300
          )
        end

        case mode do
          :cancel ->
            assert catch_throw(invoke.()) == {:cancel, "SIGINT"}

          :completed ->
            assert %{items: [%{"content" => [%{"text" => "Answer"}]}]} = invoke.()

          _ ->
            e = assert_raise Error, invoke
            refute Error.render(e) =~ key
        end

        assert_receive {:request, request}
        assert request =~ "POST /v1/messages"
        assert String.downcase(request) =~ "anthropic-version: 2026-10-21"

        if mode != :cancel do
          metadata = Process.get(:provider_attempt_metadata)
          refute JSON.encode!(metadata) =~ key
          assert metadata.provider_request_id == nil
        end

        unless is_integer(mode), do: assert_receive({:closed, {:error, :closed}}, 1500)
      after
        :gen_tcp.close(listener)
        Process.exit(server, :kill)
      end
    end
  end
end
