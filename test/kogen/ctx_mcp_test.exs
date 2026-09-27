Code.require_file("../support/ctx_fixture.ex", __DIR__)

defmodule Kogen.CtxMcpTest do
  use ExUnit.Case, async: true

  alias Kogen.Test.CtxFixture

  @usage "usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR] | kogen-ctx symbols <query> [--limit N] [--root DIR] | kogen-ctx refs <target> [--limit N] [--root DIR] | kogen-ctx map [--tokens N] [--focus PATH]... [--root DIR] | kogen-ctx mcp [--root DIR]"

  defp request(method, id, params \\ nil) do
    base = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    if is_nil(params), do: base, else: Map.put(base, "params", params)
  end

  defp mcp_file(root, home, lines) do
    nonce = "#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "kogen-ctx-mcp-#{nonce}")
    File.mkdir_p!(dir)
    request_file = Path.join(dir, "requests.jsonl")
    File.write!(request_file, Enum.join(lines, "\n") <> "\n")

    {out, status} =
      System.cmd(
        "/bin/sh",
        ["-c", ~S(exec "$0" mcp --root "$1" < "$2"), CtxFixture.binary(), root, request_file],
        cd: root,
        env: [{"PATH", "/usr/bin:/bin"}, {"KOGEN_CTX_HOME", home}]
      )

    File.rm_rf!(dir)
    {String.split(out, "\n", trim: true), status}
  end

  defp mcp_port(root, home) do
    Port.open(
      {:spawn_executable, CtxFixture.binary()},
      [
        :binary,
        {:line, 1_048_576},
        :exit_status,
        args: ["mcp", "--root", root],
        cd: root,
        env: [{~c"PATH", ~c"/usr/bin:/bin"}, {~c"KOGEN_CTX_HOME", String.to_charlist(home)}]
      ]
    )
  end

  defp tool_call(id, name, arguments) do
    request("tools/call", id, %{"name" => name, "arguments" => arguments})
  end

  defp text_result(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}

  defp error_text(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}

  test "M1 a scripted session gets one reply per request, in order" do
    {root, home} = CtxFixture.create!()

    requests = [
      Jason.encode!(request("initialize", 1, %{"protocolVersion" => "2025-06-18"})),
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
      Jason.encode!(request("tools/list", 2)),
      Jason.encode!(tool_call(3, "search", %{"query" => "the"})),
      Jason.encode!(tool_call(4, "symbols", %{"query" => "Shop.Cart.total"})),
      Jason.encode!(tool_call(5, "refs", %{"target" => "Shop.Tax.add"})),
      Jason.encode!(tool_call(6, "map", %{"tokens" => 25})),
      Jason.encode!(tool_call(7, "map", %{"focus" => ["test/shop_test.exs"]})),
      Jason.encode!(tool_call(8, "nope", %{})),
      Jason.encode!(request("nope/method", 9)),
      "{not json",
      Jason.encode!(request("ping", 10)),
      Jason.encode!(tool_call(11, "search", %{})),
      Jason.encode!(request("initialize", 12, %{"protocolVersion" => "2099-01-01"}))
    ]

    {lines, 0} = mcp_file(root, home, requests)
    replies = Enum.map(lines, &Jason.decode!/1)
    assert length(lines) == 13
    assert Enum.all?(replies, &(&1["jsonrpc"] == "2.0"))
    assert Enum.map(replies, & &1["id"]) == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil, 10, 11, 12]

    by_id = Map.new(replies, &{&1["id"], &1})

    assert by_id[1]["result"] == %{
             "protocolVersion" => "2025-06-18",
             "capabilities" => %{"tools" => %{"listChanged" => false}},
             "serverInfo" => %{"name" => "kogen-ctx", "version" => "0.1.0"}
           }

    assert by_id[12]["result"]["protocolVersion"] == "2025-11-25"
    tools = by_id[2]["result"]["tools"]
    assert Enum.map(tools, & &1["name"]) == ["search", "symbols", "refs", "map"]

    assert Enum.map(tools, & &1["inputSchema"]["type"]) == [
             "object",
             "object",
             "object",
             "object"
           ]

    assert Enum.map(tools, &Map.get(&1["inputSchema"], "required", [])) == [
             ["query"],
             ["query"],
             ["target"],
             []
           ]

    for id <- 3..7, do: assert(by_id[id]["result"]["isError"] == false)
    assert by_id[8]["error"]["code"] == -32_602
    assert by_id[9]["error"]["code"] == -32_601
    assert by_id[nil]["error"]["code"] == -32_700
    assert by_id[10]["result"] == %{}
    assert by_id[11]["result"] == error_text(@usage <> "\n")
  end

  test "M2 a JSON value that is not a request object is -32600" do
    {root, home} = CtxFixture.create!()
    ping = Jason.encode!(request("ping", 1))
    {lines, 0} = mcp_file(root, home, ["[1,2]", ping])

    [bad, pong] = Enum.map(lines, &Jason.decode!/1)
    assert bad["jsonrpc"] == "2.0"
    assert bad["id"] == nil
    assert bad["error"]["code"] == -32_600
    assert pong == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
  end

  test "M2 edge cases ignore blank lines and preserve invalid id" do
    {root, home} = CtxFixture.create!()
    no_method = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 9})
    ping = Jason.encode!(request("ping", 1))
    {lines, 0} = mcp_file(root, home, ["", no_method, "", ping])
    [missing_method, pong] = Enum.map(lines, &Jason.decode!/1)
    assert missing_method["jsonrpc"] == "2.0"
    assert missing_method["id"] == 9
    assert missing_method["error"]["code"] == -32_600
    assert pong == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
  end

  test "M3 replies are written while stdin stays open" do
    {root, home} = CtxFixture.create!()
    port = mcp_port(root, home)

    on_exit(fn ->
      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end
    end)

    Port.command(
      port,
      Jason.encode!(request("initialize", 1, %{"protocolVersion" => "2025-06-18"})) <> "\n"
    )

    assert_receive {^port, {:data, {:eol, line1}}}, 10_000
    assert Jason.decode!(line1)["id"] == 1

    Port.command(port, Jason.encode!(request("tools/list", 2)) <> "\n")
    assert_receive {^port, {:data, {:eol, line2}}}, 10_000
    assert Jason.decode!(line2)["id"] == 2
    Port.close(port)
  end

  test "M4 mcp command-line errors exit before reading stdin" do
    {root, home} = CtxFixture.create!()

    for args <- [
          ["mcp", "extra"],
          ["mcp", "--limit", "2"],
          ["mcp", "--tokens", "5"],
          ["mcp", "--focus", "lib/"],
          ["mcp", "--root"],
          ["mcp", "--bogus"]
        ] do
      assert CtxFixture.run(CtxFixture.binary(), root, home, args) == {"", @usage <> "\n", 2}
    end

    assert File.ls!(home) == []

    outside =
      CtxFixture.tmp_path("kogen-ctx-outside")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert CtxFixture.run(CtxFixture.binary(), outside, home, ["mcp"]) ==
             {"",
              "kogen-ctx: not a Git checkout: " <> Kogen.ProjectScope.canonical(outside) <> "\n",
              1}

    assert File.ls!(home) == []

    assert CtxFixture.run(CtxFixture.binary(), root, home, ["mcp"], [
             {"HOME", ""},
             {"KOGEN_CTX_HOME", ""}
           ]) ==
             {"", "kogen-ctx: HOME is not set; set KOGEN_CTX_HOME to a writable directory\n", 1}

    assert File.ls!(home) == []
  end

  test "T1 tool text is byte-identical to the pinned CLI output" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()

    expected = [
      ["search", "the"],
      ["symbols", "Shop.Cart.total"],
      ["refs", "Shop.Tax.add"],
      ["map", "--tokens", "25"],
      ["map", "--focus", "test/shop_test.exs"]
    ]

    cli =
      Enum.map(expected, fn argv ->
        {out, "", 0} = CtxFixture.run(binary, root, home, argv)
        out
      end)

    assert Enum.at(cli, 0) ==
             ".kogen/intents/complete/stray-rework/INTENT.md:9-9 [intent] The Developer deletes each stray path and the guard passes.\n" <>
               ".kogen/intents/complete/stray-rework/scenarios.yaml:1-3 [intent] - id: stray-file-reworked given: A fixture with a stray file. then: The guard reworks the stray file.\n" <>
               ".kogen/intents/complete/stray-rework/INTENT.md:5-5 [intent] A stray Mix lock directory stopped the Build.\n"

    assert Enum.at(cli, 1) ==
             "lib/shop/cart.ex:2 def Shop.Cart.total/1\nlib/shop/cart.ex:3 def Shop.Cart.total/2\n"

    assert Enum.at(cli, 2) ==
             "lib/shop.ex:12 call Shop.Tax.add/1\nlib/shop/inventory.ex:5 capture Shop.Tax.add/1\n"

    assert Enum.at(cli, 3) ==
             "lib/shop/tax.ex\n  defmodule Shop.Tax\n  def Shop.Tax.add/1\n  def Shop.Tax.rate/0\n... 6 more files\n"

    focus =
      Enum.flat_map(
        [
          "test/shop_test.exs",
          "lib/shop/cart.ex",
          "lib/shop.ex",
          "lib/shop/format.ex",
          "lib/shop/inventory.ex",
          "lib/shop/pricing.ex",
          "lib/shop/tax.ex"
        ],
        fn path ->
          case path do
            "test/shop_test.exs" ->
              ["test/shop_test.exs", "  defmodule ShopTest"]

            "lib/shop/cart.ex" ->
              [
                "lib/shop/cart.ex",
                "  defmodule Shop.Cart",
                "  def Shop.Cart.total/1",
                "  def Shop.Cart.total/2",
                "  def Shop.Cart.empty/0",
                "  def Shop.Cart.merge/2"
              ]

            "lib/shop.ex" ->
              [
                "lib/shop.ex",
                "  defmodule Shop",
                "  def Shop.checkout/2",
                "  def Shop.restock/1",
                "  defmacro Shop.trace/1",
                "  defguard Shop.positive/1"
              ]

            "lib/shop/format.ex" ->
              ["lib/shop/format.ex", "  defmodule Shop.Format", "  def Shop.Format.money/1"]

            "lib/shop/inventory.ex" ->
              [
                "lib/shop/inventory.ex",
                "  defmodule Shop.Inventory",
                "  def Shop.Inventory.put/2",
                "  def Shop.Inventory.lookup/1",
                "  def Shop.Inventory.fetcher/0"
              ]

            "lib/shop/pricing.ex" ->
              [
                "lib/shop/pricing.ex",
                "  defmodule Shop.Pricing",
                "  def Shop.Pricing.apply/2",
                "  defmodule Shop.Pricing.Rules",
                "  def Shop.Pricing.Rules.default/0",
                "  def Shop.Pricing.rules/0"
              ]

            "lib/shop/tax.ex" ->
              [
                "lib/shop/tax.ex",
                "  defmodule Shop.Tax",
                "  def Shop.Tax.add/1",
                "  def Shop.Tax.rate/0"
              ]
          end
        end
      )

    assert Enum.at(cli, 4) == Enum.join(focus, "\n") <> "\n"

    reqs =
      Enum.with_index(
        [
          tool_call(1, "search", %{"query" => "the"}),
          tool_call(2, "symbols", %{"query" => "Shop.Cart.total"}),
          tool_call(3, "refs", %{"target" => "Shop.Tax.add"}),
          tool_call(4, "map", %{"tokens" => 25}),
          tool_call(5, "map", %{"focus" => ["test/shop_test.exs"]})
        ],
        1
      )

    {lines, 0} = mcp_file(root, home, Enum.map(reqs, fn {req, _} -> Jason.encode!(req) end))

    for {line, text} <- Enum.zip(lines, cli) do
      assert Jason.decode!(line)["result"] == text_result(text)
    end
  end

  test "T2 arguments map to the CLI's flags" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()

    pairs = [
      {tool_call(1, "search", %{"query" => "Mix lock"}), ["search", "Mix lock"]},
      {tool_call(2, "search", %{"query" => "stray", "limit" => 2}),
       ["search", "stray", "--limit", "2"]},
      {tool_call(3, "symbols", %{"query" => "Shop", "limit" => 1}),
       ["symbols", "Shop", "--limit", "1"]},
      {tool_call(4, "refs", %{"target" => "Shop.Cart", "limit" => 2}),
       ["refs", "Shop.Cart", "--limit", "2"]},
      {tool_call(5, "map", %{"tokens" => 64, "focus" => ["lib/shop/"]}),
       ["map", "--tokens", "64", "--focus", "lib/shop/"]},
      {tool_call(6, "symbols", %{"query" => "Shop Cart"}), ["symbols", "Shop Cart"]}
    ]

    cli =
      Enum.map(pairs, fn {_req, argv} ->
        {out, "", 0} = CtxFixture.run(binary, root, home, argv)
        out
      end)

    assert Enum.at(cli, 0) ==
             ".kogen/intents/complete/stray-rework/INTENT.md:5-5 [intent] A stray Mix lock directory stopped the Build.\n" <>
               ".kogen/memory/lesson/lesson-stray-rework.md:1-5 [memory] --- id: \"lesson-stray-rework\" kind: \"lesson\" claim: \"stray-rework published after 2 stopped Builds: stray Mix lock directories\" ---\n"

    assert Enum.at(cli, 1) ==
             ".kogen/intents/complete/stray-rework/INTENT.md:1-1 [intent] # Rework stray paths\n.kogen/intents/complete/stray-rework/scenarios.yaml:1-3 [intent] - id: stray-file-reworked given: A fixture with a stray file. then: The guard reworks the stray file.\n... 3 more\n"

    assert Enum.at(cli, 2) == "lib/shop.ex:1 defmodule Shop\n... 25 more\n"

    assert Enum.at(cli, 3) ==
             "lib/shop.ex:2 alias Shop.Cart\nlib/shop.ex:10 call Shop.Cart.total/1\n... 3 more\n"

    assert Enum.at(cli, 4) ==
             "lib/shop/tax.ex\n  defmodule Shop.Tax\n  def Shop.Tax.add/1\n  def Shop.Tax.rate/0\nlib/shop/cart.ex\n  defmodule Shop.Cart\n  def Shop.Cart.total/1\n  def Shop.Cart.total/2\n  def Shop.Cart.empty/0\n  def Shop.Cart.merge/2\n... 5 more files\n"

    assert Enum.at(cli, 5) == ""

    requests = Enum.map(pairs, fn {req, _} -> Jason.encode!(req) end)
    {lines, 0} = mcp_file(root, home, requests)

    for {line, expected} <- Enum.zip(lines, cli) do
      assert Jason.decode!(line)["result"] == text_result(expected)
    end
  end

  test "T3 argument and runtime errors are tool errors with the CLI's message" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    args = [["search"], ["refs"], ["map", "--focus", "nope.ex"]]

    for argv <- args do
      {"", err, 2} = CtxFixture.run(binary, root, home, argv)
      assert err == @usage <> "\n"
    end

    ro = CtxFixture.tmp_path("kogen-ctx-read-only")
    File.mkdir_p!(ro)
    File.chmod!(ro, 0o500)

    on_exit(fn ->
      File.chmod(ro, 0o700)
      File.rm_rf!(ro)
    end)

    {"", err, 1} = CtxFixture.run(binary, root, ro, ["search", "the"])

    assert String.starts_with?(
             err,
             "kogen-ctx: cannot write index at " <> CtxFixture.index_path(ro, root) <> ":"
           )

    assert String.ends_with?(err, "; set KOGEN_CTX_HOME to a writable directory\n")

    requests = [
      Jason.encode!(tool_call(1, "search", %{"query" => "the"})),
      Jason.encode!(request("ping", 2))
    ]

    {lines, 0} = mcp_file(root, ro, requests)
    [first, second] = Enum.map(lines, &Jason.decode!/1)
    assert first["result"] == error_text(err)
    assert second["result"] == %{}
  end
end
