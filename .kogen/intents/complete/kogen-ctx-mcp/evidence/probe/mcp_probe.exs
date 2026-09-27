Code.require_file("test/support/ctx_fixture.ex")
alias Kogen.Test.CtxFixture
import ExUnit.Assertions
bin = System.get_env("BIN")
usage = "usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR] | kogen-ctx symbols <query> [--limit N] [--root DIR] | kogen-ctx refs <target> [--limit N] [--root DIR] | kogen-ctx map [--tokens N] [--focus PATH]... [--root DIR] | kogen-ctx mcp [--root DIR]\n"

mcp_file = fn root, home, lines ->
  dir = Path.join(System.tmp_dir!(), "kogen-ctx-mcp-req-#{System.unique_integer([:positive])}")
  File.mkdir_p!(dir)
  req = Path.join(dir, "requests.jsonl")
  File.write!(req, Enum.join(lines, "\n") <> "\n")
  {out, status} = System.cmd("/bin/sh", ["-c", ~S(exec "$0" mcp --root "$1" < "$2"), bin, root, req],
    cd: root, env: [{"PATH", "/usr/bin:/bin"}, {"KOGEN_CTX_HOME", home}])
  {String.split(out, "\n", trim: true), status}
end
req = fn id, method, params ->
  m = %{"jsonrpc" => "2.0", "method" => method}
  m = if id, do: Map.put(m, "id", id), else: m
  m = if params, do: Map.put(m, "params", params), else: m
  Jason.encode!(m)
end
call = fn id, name, args -> req.(id, "tools/call", %{"name" => name, "arguments" => args}) end

{root, home} = CtxFixture.create!()
# M1
lines = [
  req.(1, "initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}, "clientInfo" => %{"name" => "t", "version" => "0"}}),
  req.(nil, "notifications/initialized", nil),
  req.(2, "tools/list", nil),
  call.(3, "search", %{"query" => "the"}),
  call.(4, "symbols", %{"query" => "Shop.Cart.total"}),
  call.(5, "refs", %{"target" => "Shop.Tax.add"}),
  call.(6, "map", %{"tokens" => 25}),
  call.(7, "map", %{"focus" => ["test/shop_test.exs"]}),
  call.(8, "nope", %{}),
  req.(9, "nope/method", nil),
  "{not json",
  req.(10, "ping", nil),
  call.(11, "search", %{}),
  req.(12, "initialize", %{"protocolVersion" => "2099-01-01"})
]
{out, 0} = mcp_file.(root, home, lines)
r = Enum.map(out, &Jason.decode!/1)
assert length(out) == 13
assert Enum.all?(r, &(&1["jsonrpc"] == "2.0"))
assert Enum.map(r, & &1["id"]) == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil, 10, 11, 12]
by = fn i -> Enum.at(r, i) end
assert by.(0)["result"] == %{"protocolVersion" => "2025-06-18", "capabilities" => %{"tools" => %{"listChanged" => false}}, "serverInfo" => %{"name" => "kogen-ctx", "version" => "0.1.0"}}
assert by.(12)["result"]["protocolVersion"] == "2025-11-25"
tools = by.(1)["result"]["tools"]
assert Enum.map(tools, & &1["name"]) == ~w(search symbols refs map)
assert Enum.map(tools, &Map.get(&1["inputSchema"], "required", [])) == [["query"], ["query"], ["target"], []]
assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))
for i <- 2..6, do: assert(by.(i)["result"]["isError"] == false)
assert by.(7)["error"]["code"] == -32602
assert by.(8)["error"]["code"] == -32601
assert by.(9)["error"]["code"] == -32700
assert by.(10)["result"] == %{}
assert by.(11)["result"] == %{"content" => [%{"type" => "text", "text" => usage}], "isError" => true}
IO.puts("M1 ok")
# M2
{out, 0} = mcp_file.(root, home, ["[1,2]", ~s({"jsonrpc":"2.0","id":1,"method":"ping"})])
[a, b] = Enum.map(out, &Jason.decode!/1)
assert %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32600}} = a
assert b == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
IO.puts("M2 ok")
# M3
port = Port.open({:spawn_executable, bin}, [:binary, {:line, 1_048_576}, :exit_status, args: ["mcp", "--root", root], cd: root,
  env: [{~c"PATH", ~c"/usr/bin:/bin"}, {~c"KOGEN_CTX_HOME", String.to_charlist(home)}]])
Port.command(port, req.(1, "initialize", %{"protocolVersion" => "2025-06-18"}) <> "\n")
assert_receive {^port, {:data, {:eol, l1}}}, 10_000
assert Jason.decode!(l1)["id"] == 1
Port.command(port, req.(2, "tools/list", nil) <> "\n")
assert_receive {^port, {:data, {:eol, l2}}}, 10_000
assert Jason.decode!(l2)["id"] == 2
Port.close(port)
IO.puts("M3 ok")
# T1/T2
pairs = [
  {"search", %{"query" => "the"}, ["search", "the"]},
  {"symbols", %{"query" => "Shop.Cart.total"}, ["symbols", "Shop.Cart.total"]},
  {"refs", %{"target" => "Shop.Tax.add"}, ["refs", "Shop.Tax.add"]},
  {"map", %{"tokens" => 25}, ["map", "--tokens", "25"]},
  {"map", %{"focus" => ["test/shop_test.exs"]}, ["map", "--focus", "test/shop_test.exs"]},
  {"search", %{"query" => "Mix lock"}, ["search", "Mix lock"]},
  {"search", %{"query" => "stray", "limit" => 2}, ["search", "stray", "--limit", "2"]},
  {"symbols", %{"query" => "Shop", "limit" => 1}, ["symbols", "Shop", "--limit", "1"]},
  {"refs", %{"target" => "Shop.Cart", "limit" => 2}, ["refs", "Shop.Cart", "--limit", "2"]},
  {"map", %{"tokens" => 64, "focus" => ["lib/shop/"]}, ["map", "--tokens", "64", "--focus", "lib/shop/"]},
  {"symbols", %{"query" => "Shop Cart"}, ["symbols", "Shop Cart"]}
]
clis = for {_, _, argv} <- pairs, do: CtxFixture.run(bin, root, home, argv)
{out, 0} = mcp_file.(root, home, pairs |> Enum.with_index(1) |> Enum.map(fn {{n, a, _}, i} -> call.(i, n, a) end))
for {{cli, "", 0}, line} <- Enum.zip(clis, out) do
  assert Jason.decode!(line)["result"] == %{"content" => [%{"type" => "text", "text" => cli}], "isError" => false}
end
IO.inspect(List.last(clis), label: "symbols 'Shop Cart'")
IO.puts("T1/T2 ok")
# T3
errs = [{"search", %{}, ["search"]}, {"refs", %{}, ["refs"]}, {"map", %{"focus" => ["nope.ex"]}, ["map", "--focus", "nope.ex"]}]
clis = for {_, _, argv} <- errs, do: CtxFixture.run(bin, root, home, argv)
{out, 0} = mcp_file.(root, home, errs |> Enum.with_index(1) |> Enum.map(fn {{n, a, _}, i} -> call.(i, n, a) end))
for {{"", err, 2}, line} <- Enum.zip(clis, out) do
  assert err == usage
  assert Jason.decode!(line)["result"] == %{"content" => [%{"type" => "text", "text" => err}], "isError" => true}
end
ro = Path.join(System.tmp_dir!(), "ctx-ro-#{System.unique_integer([:positive])}")
File.mkdir_p!(ro); File.chmod!(ro, 0o500)
{"", err, 1} = CtxFixture.run(bin, root, ro, ["search", "the"])
assert String.starts_with?(err, "kogen-ctx: cannot write index at ")
{out, 0} = mcp_file.(root, ro, [call.(1, "search", %{"query" => "the"}), req.(2, "ping", nil)])
[a, b] = Enum.map(out, &Jason.decode!/1)
assert a["result"] == %{"content" => [%{"type" => "text", "text" => err}], "isError" => true}
assert b["result"] == %{}
File.chmod(ro, 0o700)
IO.puts("T3 ok")
# M4 command-line errors
{root2, home2} = CtxFixture.create!()
for args <- [["mcp", "extra"], ["mcp", "--limit", "2"], ["mcp", "--tokens", "5"], ["mcp", "--focus", "lib/"], ["mcp", "--root"], ["mcp", "--bogus"]] do
  assert {"", ^usage, 2} = CtxFixture.run(bin, root2, home2, args)
end
assert File.ls!(home2) == []
outside = Path.join(System.tmp_dir!(), "ctx-outside-#{System.unique_integer([:positive])}")
File.mkdir_p!(outside)
{o, e, s} = CtxFixture.run(bin, outside, home2, ["mcp"])
IO.inspect({o, e, s, Kogen.ProjectScope.canonical(outside)}, label: "outside")
assert File.ls!(home2) == []
# landed commands still give usage with new string
{"", ^usage, 2} = CtxFixture.run(bin, root2, home2, ["map", "--tokens", "x"])
IO.puts("M4 ok")
