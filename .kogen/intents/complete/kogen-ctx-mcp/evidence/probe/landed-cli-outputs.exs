Code.require_file("test/support/ctx_fixture.ex")
alias Kogen.Test.CtxFixture
bin = System.get_env("BIN")
{root, home} = CtxFixture.create!()
cases = [
  ["search", "the"], ["symbols", "Shop.Cart.total"], ["refs", "Shop.Tax.add"], ["map", "--tokens", "25"],
  ["map", "--focus", "test/shop_test.exs"], ["search", "Mix lock"], ["search", "stray", "--limit", "2"],
  ["symbols", "Shop", "--limit", "1"], ["refs", "Shop.Cart", "--limit", "2"], ["map", "--tokens", "64", "--focus", "lib/shop/"],
  ["search"], ["refs"], ["map", "--focus", "nope.ex"], ["mcp"], ["search", "Mix", "lock"]
]
for c <- cases do
  {o, e, s} = CtxFixture.run(bin, root, home, c)
  IO.puts("### #{inspect(c)} status=#{s}\n--stdout--\n#{o}--stderr--\n#{e}")
end
ro = Path.join(System.tmp_dir!(), "ctx-ro-#{System.unique_integer([:positive])}")
File.mkdir_p!(ro); File.chmod!(ro, 0o500)
{o, e, s} = CtxFixture.run(bin, root, ro, ["search", "the"])
IO.puts("### ro status=#{s}\n#{inspect(o)}\n#{inspect(e)}")
File.chmod(ro, 0o700)
