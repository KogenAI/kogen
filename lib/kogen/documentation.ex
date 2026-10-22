defmodule Kogen.Documentation do
  @moduledoc false

  @timeout 20_000
  @marker "UNTRUSTED-DIRECTIVE-7b9acb97"
  @output_limit 16_384

  def lookup(arguments) when is_map(arguments) do
    operation = operation_name(arguments["operation"])
    query = blank(arguments["query"])
    url = blank(arguments["url"])
    base = blank(arguments["base"])

    dispatch(operation, query, url, base)
    |> fit()
    |> JSON.encode!()
  end

  def lookup(_arguments) do
    result(
      "search",
      "unsupported",
      "",
      "",
      [],
      "",
      false,
      false,
      "documentation source unsupported"
    )
    |> JSON.encode!()
  end

  @doc false
  def bing_sources(html) when is_binary(html) do
    Regex.scan(
      ~r/<([a-zA-Z0-9]+)\b[^>]*class="[^"]*\bb_algo\b[^"]*"[^>]*>([\s\S]*?)<\/\1>/i,
      html
    )
    |> Enum.flat_map(fn [_, _tag, block] ->
      case Regex.run(~r/<h2\b[^>]*>\s*<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/i, block) do
        [_, href, title] ->
          case decode_bing_href(href) do
            {:ok, url} -> [%{"url" => url, "title" => collapse(title)}]
            :skip -> []
          end

        _ ->
          []
      end
    end)
  end

  defp dispatch(operation, query, url, "") do
    case operation do
      "search" ->
        public_search(query)

      "fetch" ->
        public_fetch(query, url)

      _ ->
        result(
          operation,
          "unsupported",
          query,
          url,
          [],
          "",
          false,
          false,
          "documentation source unsupported"
        )
    end
  end

  defp dispatch(operation, query, url, base) do
    base = String.trim_trailing(base, "/")

    case operation do
      "search" ->
        based("search", query, url, base)

      "fetch" ->
        based("fetch", query, url, base)

      _ ->
        result(
          operation,
          "unsupported",
          query,
          url,
          [],
          "",
          false,
          false,
          "documentation source unsupported"
        )
    end
  end

  defp public_search(query) do
    url =
      "https://www.bing.com/search?q=" <>
        URI.encode(query, &URI.char_unreserved?/1) <> "&setlang=en"

    case get(url, nil) do
      {:ok, 200, body} ->
        sources = bing_sources(body)

        if sources == [] do
          result(
            "search",
            "unsupported",
            query,
            "",
            [],
            "",
            false,
            false,
            "documentation source unsupported"
          )
        else
          result("search", "retrieved", query, "", sources, "", false, false, "")
        end

      {:ok, _status, _body} ->
        result(
          "search",
          "unsupported",
          query,
          "",
          [],
          "",
          false,
          false,
          "documentation source unsupported"
        )

      {:error, _reason} ->
        result(
          "search",
          "unreachable",
          query,
          "",
          [],
          "",
          false,
          false,
          "documentation source unreachable"
        )
    end
  end

  defp public_fetch(query, url) do
    if http_url?(url) do
      classify_fetch(query, url, get(url, nil))
    else
      result(
        "fetch",
        "unsupported",
        query,
        url,
        [],
        "",
        false,
        false,
        "documentation source unsupported"
      )
    end
  end

  defp based("search", query, _url, base) do
    case get(search_url(base, query), base) do
      {:ok, 200, body} ->
        result("search", "retrieved", query, "", fixture_sources(body), "", false, false, "")

      {:ok, _status, _body} ->
        result(
          "search",
          "unsupported",
          query,
          "",
          [],
          "",
          false,
          false,
          "documentation source unsupported"
        )

      {:error, _reason} ->
        result(
          "search",
          "unreachable",
          query,
          "",
          [],
          "",
          false,
          false,
          "documentation source unreachable"
        )
    end
  end

  defp based("fetch", query, url, base) do
    if String.starts_with?(url, base) and same_origin?(url, base) do
      classify_fetch(query, url, get(url, base))
    else
      result(
        "fetch",
        "unsupported",
        query,
        url,
        [],
        "",
        false,
        false,
        "documentation source unsupported"
      )
    end
  end

  defp classify_fetch(query, url, {:ok, 200, raw}) do
    text = text_with_marker(raw, marker?(raw))

    if marker?(raw) do
      result(
        "fetch",
        "untrusted",
        query,
        url,
        [],
        text,
        true,
        false,
        "documentation response untrusted"
      )
    else
      result("fetch", "retrieved", query, url, [], text, true, false, "")
    end
  end

  defp classify_fetch(query, url, {:ok, _status, _body}) do
    result(
      "fetch",
      "unsupported",
      query,
      url,
      [],
      "",
      false,
      false,
      "documentation source unsupported"
    )
  end

  defp classify_fetch(query, url, {:error, _reason}) do
    result(
      "fetch",
      "unreachable",
      query,
      url,
      [],
      "",
      false,
      false,
      "documentation source unreachable"
    )
  end

  defp search_url(base, query) do
    base <> "/search?q=" <> URI.encode(query, &URI.char_unreserved?/1)
  end

  defp get(url, base), do: follow(canonical(url), base, 5)

  defp follow(url, base, left) do
    cond do
      left < 1 ->
        {:ok, 0, ""}

      is_binary(base) and not allowed?(url, base) ->
        {:ok, 0, ""}

      true ->
        case get_once(url, base) do
          {:ok, status, headers, body} when status in [301, 302, 303, 307, 308] ->
            case redirect_target(url, headers, base) do
              {:ok, next} -> follow(next, base, left - 1)
              :stop -> {:ok, status, body}
            end

          {:ok, status, _headers, body} ->
            {:ok, status, body}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp redirect_target(current, headers, base) do
    case location(headers) do
      nil ->
        :stop

      location ->
        next = canonical(resolve(current, String.trim(location)))

        cond do
          not http_url?(next) -> :stop
          is_binary(base) and not allowed?(next, base) -> :stop
          true -> {:ok, next}
        end
    end
  end

  defp allowed?(url, base) do
    String.starts_with?(url, base) and same_origin?(url, base)
  end

  defp resolve(current, location) do
    URI.to_string(URI.merge(current, location))
  end

  defp canonical(url) when is_binary(url) do
    uri = URI.parse(url)
    host = if is_binary(uri.host), do: String.downcase(uri.host), else: uri.host
    URI.to_string(%{uri | host: host, userinfo: nil})
  end

  defp same_origin?(url, base) when is_binary(url) and is_binary(base) do
    same_origin?(URI.parse(url), URI.parse(base))
  end

  defp same_origin?(%URI{} = target, %URI{} = origin) do
    scheme(target) == scheme(origin) and scheme(target) in ["http", "https"] and
      host(target) == host(origin) and host(target) != "" and
      effective_port(target) == effective_port(origin)
  end

  defp scheme(%URI{scheme: scheme}) when is_binary(scheme), do: String.downcase(scheme)
  defp scheme(_uri), do: ""

  defp host(%URI{host: host}) when is_binary(host), do: String.downcase(host)
  defp host(_uri), do: ""

  defp effective_port(%URI{scheme: scheme, port: port}) do
    cond do
      is_integer(port) -> port
      scheme in ["https", "HTTPS"] -> 443
      true -> 80
    end
  end

  defp location(headers) do
    Enum.find_value(headers, fn
      {name, value} ->
        if String.downcase(to_string(name)) == "location", do: to_string(value), else: nil
    end)
  end

  defp get_once(url, base) do
    uri = URI.parse(url)
    profile = profile()
    :inets.start()
    :ssl.start()
    :ok = :httpc.set_options([{:max_keep_alive_length, 0}], profile)

    if is_binary(base) do
      case origin(base) do
        {:ok, host, port} -> :httpc.set_options([{:proxy, {{host, port}, []}}], profile)
        :error -> :ok
      end
    end

    headers = [
      {~c"user-agent", String.to_charlist(user_agent())},
      {~c"accept", ~c"text/html"},
      {~c"accept-language", ~c"en"}
    ]

    request = {String.to_charlist(url), headers}
    ssl = ssl_options(uri.host)

    http_options = [
      timeout: @timeout,
      connect_timeout: @timeout,
      autoredirect: false,
      ssl: ssl
    ]

    try do
      case :httpc.request(:get, request, http_options, [{:body_format, :binary}], profile) do
        {:ok, {{_version, status, _reason}, response_headers, body}} ->
          {:ok, status, header_pairs(response_headers), body}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      _ -> {:error, :request}
    after
      :inets.stop(:httpc, profile)
    end
  end

  defp ssl_options(host) when is_binary(host) and host != "" do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      server_name_indication: String.to_charlist(host)
    ]
  end

  defp ssl_options(_host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp origin(base) do
    uri = URI.parse(base)

    if is_binary(uri.host) and uri.host != "" and is_integer(uri.port) do
      {:ok, String.to_charlist(uri.host), uri.port}
    else
      :error
    end
  end

  defp profile do
    name =
      String.to_atom(
        "kogen_documentation_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    {:ok, _pid} = :inets.start(:httpc, profile: name)
    name
  end

  defp header_pairs(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp fixture_sources(body) do
    case JSON.decode(utf8(body)) do
      {:ok, %{"sources" => sources}} when is_list(sources) ->
        Enum.flat_map(sources, fn
          %{"url" => url, "title" => title} when is_binary(url) and is_binary(title) ->
            [%{"url" => url, "title" => title}]

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp decode_bing_href(href) do
    decoded = html_unescape(href)

    with {:ok, uri} <- {:ok, URI.parse(decoded)},
         query when is_binary(query) <- uri.query,
         %{"u" => value} <- URI.decode_query(query),
         true <- is_binary(value) and value != "",
         {:ok, target} <- decode_u(value),
         true <- http_url?(target) do
      {:ok, target}
    else
      _ -> :skip
    end
  end

  defp decode_u(value) do
    encoded = value |> String.replace_prefix("a1", "") |> String.trim_trailing("=")
    padded = encoded <> String.duplicate("=", rem(4 - rem(byte_size(encoded), 4), 4))

    case Base.decode64(padded) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :error
    end
  end

  defp html_unescape(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
  end

  defp collapse(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")
    |> html_unescape()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp http_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp http_url?(_url), do: false

  defp marker?(body) when is_binary(body), do: :binary.match(body, @marker) != :nomatch
  defp marker?(_body), do: false

  defp text_with_marker(raw, true) do
    text = utf8(raw)
    if String.contains?(text, @marker), do: text, else: @marker <> text
  end

  defp text_with_marker(raw, false), do: utf8(raw)

  defp utf8(body) when is_binary(body), do: utf8(body, "")
  defp utf8(_body), do: ""

  defp utf8(body, acc) do
    case :unicode.characters_to_binary(body) do
      text when is_binary(text) ->
        acc <> text

      {:error, good, <<_bad, rest::binary>>} ->
        utf8(rest, acc <> good <> "\uFFFD")

      {:incomplete, good, _rest} ->
        acc <> good <> "\uFFFD"
    end
  end

  defp fit(result) do
    shrink(result, 24)
  end

  defp shrink(result, 0) do
    body = if result["untrusted"], do: @marker, else: ""
    %{result | "body" => body, "sources" => [], "truncated" => true}
  end

  defp shrink(result, left) do
    if byte_size(JSON.encode!(result)) <= @output_limit do
      result
    else
      shrink(smaller(result), left - 1)
    end
  end

  defp smaller(result) do
    body = result["body"]
    sources = result["sources"]

    cond do
      sources != [] and byte_size(body) <= 64 ->
        %{result | "sources" => Enum.drop(sources, -1), "truncated" => true}

      byte_size(body) > 0 ->
        keep = max(div(byte_size(body), 2), 0)
        next = keep_marker(utf8_prefix(body, keep), result["untrusted"])
        %{result | "body" => next, "truncated" => true}

      true ->
        %{result | "sources" => [], "truncated" => true}
    end
  end

  defp keep_marker(text, true) do
    if String.contains?(text, @marker), do: text, else: @marker <> text
  end

  defp keep_marker(text, _untrusted), do: text

  defp utf8_prefix(text, max) do
    if byte_size(text) <= max do
      text
    else
      cut = binary_part(text, 0, max)

      case :unicode.characters_to_binary(cut) do
        ok when is_binary(ok) -> ok
        {:incomplete, good, _} -> good
        {:error, good, _} -> good
      end
    end
  end

  defp user_agent, do: "kogen/" <> version()

  defp version do
    case Application.spec(:kogen, :vsn) do
      vsn when is_list(vsn) ->
        List.to_string(vsn)

      vsn when is_binary(vsn) and vsn != "" ->
        vsn

      _ ->
        _ = Application.load(:kogen)

        case Application.spec(:kogen, :vsn) do
          vsn when is_list(vsn) -> List.to_string(vsn)
          vsn when is_binary(vsn) and vsn != "" -> vsn
          _ -> "0.1.0"
        end
    end
  end

  defp operation_name(operation) when is_binary(operation), do: operation
  defp operation_name(_operation), do: "search"

  defp blank(value) when is_binary(value), do: value
  defp blank(_value), do: ""

  defp result(operation, status, query, url, sources, body, untrusted, truncated, error) do
    %{
      "operation" => operation,
      "status" => status,
      "query" => query,
      "url" => url,
      "sources" => sources,
      "body" => body,
      "untrusted" => untrusted,
      "truncated" => truncated,
      "error" => error
    }
  end
end
