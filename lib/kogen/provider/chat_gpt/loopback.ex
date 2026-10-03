defmodule Kogen.Provider.ChatGPT.Loopback do
  @moduledoc false

  alias Kogen.Provider.ChatGPT.Callback

  defmodule Listener do
    @moduledoc false
    @enforce_keys [:socket, :port, :redirect_uri]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            socket: :gen_tcp.socket(),
            port: non_neg_integer(),
            redirect_uri: String.t()
          }
  end

  @path "/auth/callback"
  @timeout_ms 300_000

  @spec start(keyword()) :: {:ok, Listener.t()} | {:error, term()}
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 1455)

    with {:ok, socket} <- listen(port),
         {:ok, actual_port} <- actual_port(socket) do
      {:ok, %Listener{socket: socket, port: actual_port, redirect_uri: redirect_uri(actual_port)}}
    end
  end

  @spec await(Listener.t(), String.t(), :registration | :reauthorization, keyword()) ::
          {:ok, map()} | {:error, term()}
  def await(%Listener{} = listener, state, mode, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    try do
      with {:ok, socket} <- :gen_tcp.accept(listener.socket, timeout) do
        try do
          with {:ok, request} <- :gen_tcp.recv(socket, 0, 10_000),
               {:ok, query} <- request_query(request),
               result = Callback.validate(query, state, mode),
               :ok <- send_response(socket, result) do
            result
          end
        after
          :gen_tcp.close(socket)
        end
      end
    after
      close(listener)
    end
  end

  @spec close(Listener.t()) :: :ok
  def close(%Listener{socket: socket}) do
    _ = :gen_tcp.close(socket)
    :ok
  end

  @spec redirect_uri(non_neg_integer()) :: String.t()
  def redirect_uri(port), do: "http://127.0.0.1:#{port}#{@path}"

  defp listen(port) do
    :gen_tcp.listen(port, [
      :binary,
      active: false,
      ip: {127, 0, 0, 1},
      reuseaddr: false,
      backlog: 1
    ])
  end

  defp actual_port(listener) do
    case :inet.sockname(listener) do
      {:ok, {{127, 0, 0, 1}, port}} -> {:ok, port}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_query(request) do
    case request |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ", parts: 3) do
      ["GET", target, _version] -> callback_query(target)
      _other -> {:error, :invalid_callback_request}
    end
  end

  defp callback_query(target) do
    case URI.parse(target) do
      %URI{path: @path, query: query} when is_binary(query) -> {:ok, query}
      _other -> {:error, :invalid_callback_path}
    end
  end

  defp send_response(socket, {:ok, _callback}) do
    respond(socket, "HTTP/1.1 200 OK\r\n", "Kogen sign-in complete. You can close this tab.")
  end

  defp send_response(socket, {:error, _reason}) do
    respond(
      socket,
      "HTTP/1.1 400 Bad Request\r\n",
      "Kogen could not verify this sign-in callback."
    )
  end

  defp respond(socket, status, message) do
    body = "<!doctype html><title>Kogen</title><p>#{message}</p>"

    case :gen_tcp.send(
           socket,
           status <>
             "Content-Type: text/html; charset=utf-8\r\n" <>
             "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
