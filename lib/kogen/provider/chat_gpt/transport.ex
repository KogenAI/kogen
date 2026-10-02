defmodule Kogen.Provider.ChatGPT.Transport do
  @moduledoc false

  defmodule Response do
    @moduledoc false
    @enforce_keys [:status, :body, :chunks]
    defstruct @enforce_keys

    @type t :: %__MODULE__{status: pos_integer(), body: binary(), chunks: [binary()]}
  end

  defmodule State do
    @moduledoc false
    defstruct status: nil, chunks: [], size: 0
  end

  @max_response_bytes 16_000_000

  @spec post_stream(String.t(), [{String.t(), String.t()}], binary(), pos_integer()) ::
          {:ok, Response.t()} | {:error, :timeout | :transport | :too_large}
  def post_stream(url, headers, body, timeout_ms)
      when is_binary(url) and is_list(headers) and is_binary(body) and is_integer(timeout_ms) do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      request(url, headers, body, timeout_ms)
    else
      _ -> {:error, :transport}
    end
  end

  defp request(url, headers, body, timeout_ms) do
    request = {String.to_charlist(url), charlist_headers(headers), ~c"application/json", body}

    case :httpc.request(:post, request, http_options(url),
           sync: false,
           stream: :self,
           full_result: true
         ) do
      {:ok, ref} ->
        receive_response(
          ref,
          System.monotonic_time(:millisecond) + timeout_ms,
          %State{}
        )

      {:error, _reason} ->
        {:error, :transport}
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp http_options(url) do
    [
      timeout: :infinity,
      connect_timeout: 30_000,
      autoredirect: false,
      autoretry: 0,
      ssl: ssl_options(url)
    ]
  end

  defp ssl_options(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 4,
          server_name_indication: String.to_charlist(host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

      _ ->
        []
    end
  end

  defp receive_response(ref, deadline, %State{} = state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      cancel(ref)
      {:error, :timeout}
    else
      receive do
        {:http, {^ref, :stream_start, _headers}} ->
          receive_response(ref, deadline, %{state | status: 200})

        {:http, {^ref, :stream_start, _headers, _handler}} ->
          receive_response(ref, deadline, %{state | status: 200})

        {:http, {^ref, :stream, chunk}} when is_binary(chunk) ->
          append_chunk(ref, deadline, state, chunk)

        {:http, {^ref, :stream_end, _headers}} ->
          finish_stream(state)

        {:http, {^ref, {{_version, status, _reason}, _headers, body}}} ->
          full_response(status, body)

        {:http, {^ref, {:error, reason}}} ->
          transport_error(reason)
      after
        remaining ->
          cancel(ref)
          {:error, :timeout}
      end
    end
  end

  defp append_chunk(ref, deadline, state, chunk) do
    size = state.size + byte_size(chunk)

    if size > @max_response_bytes do
      cancel(ref)
      {:error, :too_large}
    else
      receive_response(ref, deadline, %{state | chunks: [chunk | state.chunks], size: size})
    end
  end

  defp finish_stream(state) do
    chunks = Enum.reverse(state.chunks)

    {:ok,
     %Response{status: state.status || 200, body: IO.iodata_to_binary(chunks), chunks: chunks}}
  end

  defp full_response(status, body)
       when is_binary(body) and byte_size(body) <= @max_response_bytes do
    {:ok, %Response{status: status, body: body, chunks: [body]}}
  end

  defp full_response(_status, _body), do: {:error, :too_large}

  defp transport_error(reason) do
    if timeout_reason?(reason), do: {:error, :timeout}, else: {:error, :transport}
  end

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?(:connect_timeout), do: true

  defp timeout_reason?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&timeout_reason?/1)

  defp timeout_reason?(list) when is_list(list), do: Enum.any?(list, &timeout_reason?/1)
  defp timeout_reason?(_reason), do: false

  defp cancel(ref) do
    :httpc.cancel_request(ref)
    :ok
  end
end
