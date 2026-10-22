defmodule Kogen.Integration.OpenCodeGoTransportTest do
  use ExUnit.Case, async: false
  alias Kogen.OpenCodeGo
  @moduletag :integration

  test "a redirect cannot carry Go authentication to the paid route" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    owner = self()
    server = spawn(fn -> serve(listener, port, owner) end)
    previous = :persistent_term.get(:kogen_caller, nil)
    home = Kogen.tmp_path("go-transport")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "VERSION"), "kogen dev+12345678 (test)\n")
    release_root = System.get_env("RELEASE_ROOT")
    System.put_env("RELEASE_ROOT", home)

    on_exit(fn ->
      if release_root,
        do: System.put_env("RELEASE_ROOT", release_root),
        else: System.delete_env("RELEASE_ROOT")

      File.rm_rf!(home)
      :gen_tcp.close(listener)
      Process.exit(server, :kill)

      if previous,
        do: :persistent_term.put(:kogen_caller, previous),
        else: :persistent_term.erase(:kogen_caller)
    end)

    :persistent_term.put(:kogen_caller, %{
      env: %{"KOGEN_PROVIDER_URL" => "http://127.0.0.1:#{port}"}
    })

    Process.put(:opencode_go_session, "synthetic-session")

    assert {:go_error, "refused", %{status: 303}} =
             OpenCodeGo.transport(
               "{}",
               "SYNTHETIC_KEY",
               System.monotonic_time(:millisecond) + 3000
             )

    assert_receive {:request, "/inference/go/openai/v1/chat/completions"}
    refute_receive {:request, _}, 100
  end

  defp serve(listener, port, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, {:http_request, _method, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0, 1000)
        length = headers(socket, 0)
        :inet.setopts(socket, packet: :raw)
        if length > 0, do: :gen_tcp.recv(socket, length, 1000)
        send(owner, {:request, path})

        response =
          if path == "/inference/go/openai/v1/chat/completions" do
            "HTTP/1.1 303 See Other\r\nLocation: http://127.0.0.1:#{port}/inference/openai/v1/chat/completions\r\n"
          else
            "HTTP/1.1 403 Forbidden\r\n"
          end

        :gen_tcp.send(socket, response <> "Content-Length: 0\r\nConnection: close\r\n\r\n")
        :gen_tcp.close(socket)
        serve(listener, port, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, length) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, :http_eoh} ->
        length

      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        headers(socket, String.to_integer(value))

      {:ok, {:http_header, _, _, _, _}} ->
        headers(socket, length)
    end
  end
end
