defmodule Kh.Http do
  @moduledoc "Streaming POST over :httpc (no deps). Secrets only ever live in the headers list; errors never echo it."

  @doc """
  post_stream(url, headers, body, on_data, deadline_ms) ->
    :ok | {:error, {:http, status, body, headers}} | {:error, :timeout} | {:error, {:network, reason}}
  `deadline_ms` is a monotonic-clock deadline; idle timeout is 300s.
  """
  def post_stream(url, headers, body, on_data, deadline_ms) do
    ensure_started()

    req =
      {String.to_charlist(url), Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
       ~c"application/json", body}

    http_opts = [timeout: :infinity, connect_timeout: 30_000, ssl: ssl_opts(url)]

    case :httpc.request(:post, req, http_opts, sync: false, stream: :self, body_format: :binary) do
      {:ok, ref} -> receive_loop(ref, on_data, deadline_ms)
      {:error, reason} -> {:error, {:network, inspect(reason)}}
    end
  end

  defp receive_loop(ref, on_data, deadline) do
    remaining = min(deadline - Kh.Util.now_ms(), Application.get_env(:kh, :idle_ms, 300_000))

    if remaining <= 0 do
      :httpc.cancel_request(ref)
      {:error, :timeout}
    else
      receive do
        {:http, {^ref, :stream_start, _h}} ->
          receive_loop(ref, on_data, deadline)

        {:http, {^ref, :stream_start, _h, _pid}} ->
          receive_loop(ref, on_data, deadline)

        {:http, {^ref, :stream, bin}} ->
          on_data.(bin)
          receive_loop(ref, on_data, deadline)

        {:http, {^ref, :stream_end, _h}} ->
          :ok

        {:http, {^ref, {{_v, status, _r}, h, resp_body}}} ->
          if status in 200..299, do: (on_data.(resp_body); :ok), else: {:error, {:http, status, to_string(resp_body), h}}

        {:http, {^ref, {:error, reason}}} ->
          {:error, {:network, inspect(reason)}}
      after
        remaining ->
          :httpc.cancel_request(ref)
          {:error, :timeout}
      end
    end
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    configure_proxy(System.get_env())
    :ok
  end

  @doc """
  :httpc ignores proxy variables, but the bench egress control (Seatbelt denies direct outbound, an allowlist CONNECT proxy is the only way out)
  needs them. Reads HTTPS_PROXY / ALL_PROXY / HTTP_PROXY (either case) and NO_PROXY from `env` and returns
  {host, port, no_proxy_hosts} | nil. Only `http://host:port` proxies are supported (that is what the runner sets).
  """
  def proxy_from_env(env) do
    raw = Enum.find_value(~w(HTTPS_PROXY https_proxy ALL_PROXY all_proxy HTTP_PROXY http_proxy), fn k -> env[k] not in [nil, ""] && env[k] end)

    with true <- is_binary(raw),
         %URI{scheme: "http", host: host, port: port} when is_binary(host) and is_integer(port) <- URI.parse(raw) do
      no = (env["NO_PROXY"] || env["no_proxy"] || "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      {host, port, no}
    else
      _ -> nil
    end
  end

  defp configure_proxy(env) do
    case proxy_from_env(env) do
      nil ->
        :ok

      {host, port, no} ->
        no = Enum.map(no, &String.to_charlist/1)
        target = {{String.to_charlist(host), port}, no}
        :httpc.set_options(proxy: target, https_proxy: target)
    end
  end

  defp ssl_opts("https" <> _ = url) do
    host = URI.parse(url).host |> String.to_charlist()

    [
      verify: :verify_peer,
      cacerts: cacerts(),
      depth: 4,
      server_name_indication: host,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ssl_opts(_), do: []

  defp cacerts do
    with {:ok, pem} <- File.read("/etc/ssl/cert.pem"),
         certs when certs != [] <- for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      certs
    else
      _ -> :public_key.cacerts_get()
    end
  end
end
