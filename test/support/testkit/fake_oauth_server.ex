defmodule Kogen.Testkit.FakeOAuthServer do
  @moduledoc false

  @spec start((map() -> {pos_integer(), binary()})) :: {pid(), pos_integer(), pid()}
  def start(response_fun) when is_function(response_fun, 1) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true,
        backlog: 5
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    {:ok, count} = Agent.start_link(fn -> 0 end)
    server = spawn_link(fn -> accept(listener, response_fun, count) end)
    {server, port, count}
  end

  @spec stop({pid(), pos_integer(), pid()}) :: :ok
  def stop({server, _port, count}) do
    send(server, :stop)
    Process.exit(count, :normal)
    :ok
  end

  defp accept(listener, response_fun, count) do
    receive do
      :stop -> :gen_tcp.close(listener)
    after
      0 ->
        case :gen_tcp.accept(listener, 100) do
          {:ok, socket} ->
            serve(socket, response_fun, count)
            accept(listener, response_fun, count)

          {:error, :timeout} ->
            accept(listener, response_fun, count)

          {:error, :closed} ->
            :ok
        end
    end
  end

  defp serve(socket, response_fun, count) do
    with {:ok, request} <- read_request(socket, <<>>),
         :ok <- Agent.update(count, &(&1 + 1)),
         {status, body} <- response_fun.(request) do
      response =
        "HTTP/1.1 #{status} Test\r\n" <>
          "Content-Type: application/json\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n" <>
          "Connection: close\r\n\r\n" <> body

      :gen_tcp.send(socket, response)
    end
  after
    :gen_tcp.close(socket)
  end

  defp read_request(socket, data) do
    case :binary.match(data, "\r\n\r\n") do
      {header_end, 4} ->
        headers = binary_part(data, 0, header_end)
        body_start = header_end + 4
        body = binary_part(data, body_start, byte_size(data) - body_start)
        length = content_length(headers)

        if byte_size(body) >= length do
          {:ok, request_map(headers, binary_part(body, 0, length))}
        else
          receive_more(socket, data)
        end

      :nomatch ->
        receive_more(socket, data)
    end
  end

  defp receive_more(socket, data) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_request(socket, data <> chunk)
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "content-length" do
            value |> String.trim() |> String.to_integer()
          end

        _other ->
          nil
      end
    end)
  end

  defp request_map(headers, body) do
    [request_line | _header_lines] = String.split(headers, "\r\n")
    [method, path, _version] = String.split(request_line, " ", parts: 3)

    %{
      method: method,
      path: path,
      body: body,
      form: URI.decode_query(body)
    }
  end
end
