defmodule Kogen.DocumentationTest do
  use ExUnit.Case, async: false

  test "a pinned base separates search from fetch and keeps honest failures" do
    parent = self()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"

    server =
      spawn(fn ->
        serve(listen, parent, port)
      end)

    search =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "search",
          "query" => "cache controls",
          "base" => base
        })
      )

    assert_receive {:request, request}
    version = Application.spec(:kogen, :vsn) |> to_string()
    assert request =~ "user-agent: kogen/#{version}\r\n"
    downcased = String.downcase(request)
    refute downcased =~ "authorization:"
    refute downcased =~ "cookie:"

    assert search["status"] == "retrieved"
    assert search["operation"] == "search"
    assert search["query"] == "cache controls"
    assert search["url"] == ""
    assert search["body"] == ""
    assert search["untrusted"] == false

    assert search["sources"] == [
             %{"url" => "#{base}/cache-controls", "title" => "Cache controls"}
           ]

    refute search["body"] =~ "DOC-FACT-7b9acb97"

    fetch =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "#{base}/cache-controls",
          "base" => base
        })
      )

    assert fetch["status"] == "retrieved"
    assert fetch["operation"] == "fetch"
    assert fetch["untrusted"] == true
    assert fetch["url"] == "#{base}/cache-controls"
    assert fetch["body"] =~ "DOC-FACT-7b9acb97"
    assert fetch["error"] == ""

    hostile =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "#{base}/hostile",
          "base" => base
        })
      )

    assert hostile["status"] == "untrusted"
    assert hostile["untrusted"] == true
    assert hostile["error"] == "documentation response untrusted"
    assert hostile["body"] =~ "UNTRUSTED-DIRECTIVE-7b9acb97"
    assert hostile["url"] == "#{base}/hostile"

    missing =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "search",
          "query" => "missing-provider",
          "base" => base
        })
      )

    assert missing["status"] == "unsupported"
    assert missing["error"] == "documentation source unsupported"
    assert missing["sources"] == []
    assert missing["body"] == ""

    send(server, :stop)
    :gen_tcp.close(listen)
  end

  test "a 200 search with no fixture sources stays retrieved" do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"
    server = spawn(fn -> serve(listen, parent, port) end)

    result =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "search",
          "query" => "empty",
          "base" => base
        })
      )

    assert result["status"] == "retrieved"
    assert result["untrusted"] == false
    assert result["sources"] == []
    assert result["body"] == ""
    assert result["error"] == ""
    send(server, :stop)
    :gen_tcp.close(listen)
  end

  test "connection refusal on the pinned origin is unreachable" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    base = "http://127.0.0.1:#{port}"

    result =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "#{base}/missing",
          "base" => base
        })
      )

    assert result["status"] == "unreachable"
    assert result["error"] == "documentation source unreachable"
    assert result["body"] == ""
    assert result["sources"] == []
    assert result["url"] == "#{base}/missing"
  end

  test "a fetch url outside the pinned origin is unsupported and not requested" do
    result =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "http://127.0.0.1:9999/secret",
          "base" => "http://127.0.0.1:9"
        })
      )

    assert result["status"] == "unsupported"
    assert result["error"] == "documentation source unsupported"
    assert result["body"] == ""
    assert result["url"] == "http://127.0.0.1:9999/secret"
  end

  test "a base-prefixed url whose host is carried in userinfo is not requested" do
    result =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "http://127.0.0.1:9@evil.example/secret",
          "base" => "http://127.0.0.1:9"
        })
      )

    assert result["status"] == "unsupported"
    assert result["error"] == "documentation source unsupported"
    assert result["body"] == ""
  end

  test "a redirect off the pinned origin is not followed" do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        off = "http://127.0.0.1:#{port}@127.0.0.1:1/secret"

        :gen_tcp.send(
          socket,
          "HTTP/1.1 302 Found\r\nlocation: #{off}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
        send(parent, :redirected)
        Process.sleep(:infinity)
      end)

    result =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "#{base}/start",
          "base" => base
        })
      )

    assert_receive :redirected, 2_000
    assert result["status"] == "unsupported"
    assert result["error"] == "documentation source unsupported"
    assert result["body"] == ""
    assert result["url"] == "#{base}/start"
    send(server, :stop)
    :gen_tcp.close(listen)
  end

  test "a same-origin redirect does not forward userinfo" do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"

    server =
      spawn(fn ->
        {:ok, first} = :gen_tcp.accept(listen, 2_000)
        {:ok, _request} = :gen_tcp.recv(first, 0, 2_000)

        :gen_tcp.send(
          first,
          "HTTP/1.1 302 Found\r\nlocation: http://user:secret@127.0.0.1:#{port}/landed\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        )

        :gen_tcp.close(first)
        {:ok, second} = :gen_tcp.accept(listen, 2_000)
        {:ok, followed} = :gen_tcp.recv(second, 0, 2_000)
        send(parent, {:followed, followed})

        :gen_tcp.send(
          second,
          "HTTP/1.1 200 OK\r\ncontent-length: 4\r\nconnection: close\r\n\r\nland"
        )

        :gen_tcp.close(second)
        Process.sleep(:infinity)
      end)

    result =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "#{base}/start",
          "base" => base
        })
      )

    assert_receive {:followed, followed}, 2_000
    refute followed =~ "secret"
    refute followed =~ "Authorization"
    assert followed =~ "/landed"
    assert result["status"] == "retrieved"
    assert result["body"] == "land"
    assert result["url"] == "#{base}/start"
    send(server, :stop)
    :gen_tcp.close(listen)
  end

  test "an invalid UTF-8 body that contains the untrusted marker stays untrusted" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"
    payload = <<0xFF, "UNTRUSTED-DIRECTIVE-7b9acb97", 0x80>>

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :gen_tcp.send(
          socket,
          [
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(payload)}\r\nconnection: close\r\n\r\n",
            payload
          ]
        )

        :gen_tcp.close(socket)
        Process.sleep(:infinity)
      end)

    result =
      decode(
        Kogen.Documentation.lookup(%{
          "operation" => "fetch",
          "url" => "#{base}/hostile",
          "base" => base
        })
      )

    assert result["status"] == "untrusted"
    assert result["untrusted"] == true
    assert result["error"] == "documentation response untrusted"
    assert result["body"] =~ "UNTRUSTED-DIRECTIVE-7b9acb97"
    send(server, :stop)
    :gen_tcp.close(listen)
  end

  test "a large untrusted body stays classified and fits the tool output" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    base = "http://127.0.0.1:#{port}"
    payload = String.duplicate("a", 20_000) <> "UNTRUSTED-DIRECTIVE-7b9acb97"

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :gen_tcp.send(
          socket,
          [
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(payload)}\r\nconnection: close\r\n\r\n",
            payload
          ]
        )

        :gen_tcp.close(socket)
        Process.sleep(:infinity)
      end)

    encoded =
      Kogen.Documentation.lookup(%{
        "operation" => "fetch",
        "url" => "#{base}/hostile",
        "base" => base
      })

    result = decode(encoded)
    assert result["status"] == "untrusted"
    assert result["body"] =~ "UNTRUSTED-DIRECTIVE-7b9acb97"
    assert result["truncated"] == true
    assert byte_size(encoded) <= 16_384
    send(server, :stop)
    :gen_tcp.close(listen)
  end

  test "an unknown operation and a non-http url are unsupported" do
    unknown =
      decode(
        Kogen.Documentation.lookup(%{"operation" => "browse", "base" => "http://127.0.0.1:9"})
      )

    assert unknown["status"] == "unsupported"
    assert unknown["error"] == "documentation source unsupported"

    fetch =
      decode(Kogen.Documentation.lookup(%{"operation" => "fetch", "url" => "file:///etc/passwd"}))

    assert fetch["status"] == "unsupported"
    assert fetch["url"] == "file:///etc/passwd"
  end

  test "public search copies only decoded anchors inside b_algo results" do
    good = Base.encode64("https://docs.example/cache")
    outside = Base.encode64("https://outside.example/no")
    other = Base.encode64("https://docs.example/other")

    html = """
    <li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1#{good}&amp;ntb=1">Cache controls</a></h2></li>
    <li class="b_algo">no result link</li>
    <h2><a href="https://www.bing.com/ck/a?u=a1#{outside}">Outside</a></h2>
    <div class="b_algo"><h2><a href="https://invented.example/doc">Invented</a></h2></div>
    <div class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1#{other}">Other</a></h2></div>
    """

    assert Kogen.Documentation.bing_sources(html) == [
             %{"url" => "https://docs.example/cache", "title" => "Cache controls"},
             %{"url" => "https://docs.example/other", "title" => "Other"}
           ]
  end

  defp decode(text), do: JSON.decode!(text)

  defp serve(listen, parent, port) do
    case :gen_tcp.accept(listen, 2_000) do
      {:ok, socket} ->
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        send(parent, {:request, request})
        response = response(request, port)
        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        serve(listen, parent, port)

      _ ->
        :ok
    end
  end

  defp response(request, port) do
    cond do
      String.contains?(request, "q=cache%20controls") ->
        url = "http://127.0.0.1:#{port}/cache-controls"
        body = JSON.encode!(%{"sources" => [%{"url" => url, "title" => "Cache controls"}]})

        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

      String.contains?(request, "q=empty") ->
        body = ~s({"sources":[]})

        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

      String.contains?(request, "q=missing-provider") ->
        "HTTP/1.1 415 Unsupported Media Type\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"

      String.contains?(request, "/cache-controls") ->
        body = "DOC-FACT-7b9acb97\n"

        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

      String.contains?(request, "/hostile") ->
        body = "UNTRUSTED-DIRECTIVE-7b9acb97\n"

        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

      true ->
        "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    end
  end

  test "a documentation lookup is retained without the document body" do
    dir = Kogen.tmp_path("kogen-documentation-evidence")
    on_exit(fn -> File.rm_rf!(dir) end)
    Kogen.ShapeEvidence.start(dir)

    search =
      Kogen.ShapeEvidence.retain_documentation(
        %{"operation" => "search", "query" => "cache controls"},
        JSON.encode!(%{
          "operation" => "search",
          "status" => "retrieved",
          "query" => "cache controls",
          "url" => nil,
          "sources" => [
            %{
              "url" => "http://127.0.0.1/cache-controls",
              "title" => "Cache controls",
              "rank" => 1
            },
            %{"url" => 1, "title" => "bad"},
            "malformed"
          ],
          "body" => "DOC-FACT-7b9acb97",
          "untrusted" => false,
          "truncated" => false,
          "error" => nil
        })
      )

    assert search["url"] == ""
    assert search["error"] == ""

    assert search["sources"] == [
             %{"url" => "http://127.0.0.1/cache-controls", "title" => "Cache controls"}
           ]

    refute Map.has_key?(search, "body")

    broken =
      Kogen.ShapeEvidence.retain_documentation(
        %{"operation" => "browse", "query" => "missing\nprovider", "url" => 4},
        "not json"
      )

    assert broken == %{
             "operation" => "search",
             "status" => "unsupported",
             "query" => "missing\nprovider",
             "url" => "",
             "sources" => [],
             "untrusted" => false,
             "truncated" => false,
             "error" => "documentation source unsupported"
           }

    {started, finished} = Kogen.ShapeEvidence.documentation_progress(broken)
    assert started == "kogen: documentation: search missing provider"
    assert finished == "kogen: documentation result: search unsupported"
    refute started =~ "DOC-FACT-7b9acb97"

    Kogen.ShapeEvidence.probe(fn -> "exit status: 0\nDOC-FACT-7b9acb97\n" end)
    Kogen.ShapeEvidence.finish()

    records =
      Path.join(dir, "documentation.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    events =
      Path.join(dir, "events.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&(&1["event"] == "documentation_lookup"))

    assert length(records) == 2
    assert Enum.map(events, &Map.drop(&1, ["event"])) == records
    assert Enum.all?(events, &(&1["event"] == "documentation_lookup"))
    refute File.read!(Path.join(dir, "documentation.ndjson")) =~ "DOC-FACT-7b9acb97"
    assert File.read!(Path.join(dir, "events.ndjson")) =~ "DOC-FACT-7b9acb97"
    assert Bitwise.band(File.stat!(Path.join(dir, "documentation.ndjson")).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700

    assert Kogen.Shape.discovery_policy() =~
             "Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record."
  end
end
