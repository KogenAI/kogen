Code.require_file("../support/ctx_fixture.ex", __DIR__)

defmodule Kogen.CtxElixirTest do
  use ExUnit.Case, async: true
  alias Kogen.Test.CtxFixture

  defp run!(root, home, args) do
    {out, err, 0} = CtxFixture.run(CtxFixture.binary(), root, home, args)
    assert err == ""
    String.split(out, "\n", trim: true)
  end

  defp usage!(root, home, args) do
    {out, err, 2} = CtxFixture.run(CtxFixture.binary(), root, home, args)
    assert out == ""

    assert err ==
             "usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR] | kogen-ctx symbols <query> [--limit N] [--root DIR] | kogen-ctx refs <target> [--limit N] [--root DIR] | kogen-ctx map [--tokens N] [--focus PATH]... [--root DIR]\n"
  end

  test "E1 symbols lists every module and function by the specified rules" do
    {root, home} = CtxFixture.create!()

    for {path, _} <- CtxFixture.sources() do
      bytes = File.read!(Path.join(root, path))

      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
               CtxFixture.hashes()[path]
    end

    expected = [
      "lib/shop.ex:1 defmodule Shop",
      "lib/shop.ex:8 def Shop.checkout/2",
      "lib/shop.ex:16 def Shop.restock/1",
      "lib/shop.ex:18 defp Shop.audit/1",
      "lib/shop.ex:20 defmacro Shop.trace/1",
      "lib/shop.ex:22 defguard Shop.positive/1",
      "lib/shop/cart.ex:1 defmodule Shop.Cart",
      "lib/shop/cart.ex:2 def Shop.Cart.total/1",
      "lib/shop/cart.ex:3 def Shop.Cart.total/2",
      "lib/shop/cart.ex:5 def Shop.Cart.empty/0",
      "lib/shop/cart.ex:7 def Shop.Cart.merge/2",
      "lib/shop/format.ex:1 defmodule Shop.Format",
      "lib/shop/format.ex:2 def Shop.Format.money/1",
      "lib/shop/inventory.ex:1 defmodule Shop.Inventory",
      "lib/shop/inventory.ex:3 def Shop.Inventory.put/2",
      "lib/shop/inventory.ex:4 def Shop.Inventory.lookup/1",
      "lib/shop/inventory.ex:5 def Shop.Inventory.fetcher/0",
      "lib/shop/pricing.ex:1 defmodule Shop.Pricing",
      "lib/shop/pricing.ex:2 def Shop.Pricing.apply/2",
      "lib/shop/pricing.ex:4 defmodule Shop.Pricing.Rules",
      "lib/shop/pricing.ex:5 def Shop.Pricing.Rules.default/0",
      "lib/shop/pricing.ex:8 def Shop.Pricing.rules/0",
      "lib/shop/tax.ex:1 defmodule Shop.Tax",
      "lib/shop/tax.ex:3 def Shop.Tax.add/1",
      "lib/shop/tax.ex:4 def Shop.Tax.rate/0",
      "test/shop_test.exs:1 defmodule ShopTest"
    ]

    assert run!(root, home, ["index"]) |> then(fn _ -> run!(root, home, ["symbols", "Shop"]) end) ==
             expected
  end

  test "E2 symbols queries are case-sensitive substrings with a limit" do
    {root, home} = CtxFixture.create!()

    assert run!(root, home, ["symbols", "Shop.Cart.total"]) == [
             "lib/shop/cart.ex:2 def Shop.Cart.total/1",
             "lib/shop/cart.ex:3 def Shop.Cart.total/2"
           ]

    assert run!(root, home, ["symbols", "Shop.Pricing"]) == [
             "lib/shop/pricing.ex:1 defmodule Shop.Pricing",
             "lib/shop/pricing.ex:2 def Shop.Pricing.apply/2",
             "lib/shop/pricing.ex:4 defmodule Shop.Pricing.Rules",
             "lib/shop/pricing.ex:5 def Shop.Pricing.Rules.default/0",
             "lib/shop/pricing.ex:8 def Shop.Pricing.rules/0"
           ]

    assert run!(root, home, ["symbols", "Shop.checkout"]) == ["lib/shop.ex:8 def Shop.checkout/2"]
    assert run!(root, home, ["symbols", "Shop.audit"]) == ["lib/shop.ex:18 defp Shop.audit/1"]
    assert run!(root, home, ["symbols", "trace"]) == ["lib/shop.ex:20 defmacro Shop.trace/1"]

    assert run!(root, home, ["symbols", "positive"]) == [
             "lib/shop.ex:22 defguard Shop.positive/1"
           ]

    assert run!(root, home, ["symbols", "ShopTest"]) == [
             "test/shop_test.exs:1 defmodule ShopTest"
           ]

    assert run!(root, home, ["symbols", "Dep"]) == []

    assert run!(root, home, ["symbols", "Shop", "--limit", "1"]) == [
             "lib/shop.ex:1 defmodule Shop",
             "... 25 more"
           ]
  end

  test "E3 refs resolve aliases, pipes, captures and __MODULE__" do
    {root, home} = CtxFixture.create!()

    assert run!(root, home, ["refs", "Shop.Cart"]) == [
             "lib/shop.ex:2 alias Shop.Cart",
             "lib/shop.ex:10 call Shop.Cart.total/1",
             "lib/shop/cart.ex:7 call Shop.Cart.total/1",
             "test/shop_test.exs:3 alias Shop.Cart",
             "test/shop_test.exs:6 call Shop.Cart.total/1"
           ]

    assert run!(root, home, ["refs", "Shop.Cart", "--limit", "2"]) == [
             "lib/shop.ex:2 alias Shop.Cart",
             "lib/shop.ex:10 call Shop.Cart.total/1",
             "... 3 more"
           ]

    assert run!(root, home, ["refs", "Shop.Tax.add"]) == [
             "lib/shop.ex:12 call Shop.Tax.add/1",
             "lib/shop/inventory.ex:5 capture Shop.Tax.add/1"
           ]

    assert run!(root, home, ["refs", "Shop.Tax.add/1"]) == [
             "lib/shop.ex:12 call Shop.Tax.add/1",
             "lib/shop/inventory.ex:5 capture Shop.Tax.add/1"
           ]

    assert run!(root, home, ["refs", "Shop.Cart.total/2"]) == []

    assert run!(root, home, ["refs", "Shop.Inventory.put"]) == [
             "lib/shop.ex:16 call Shop.Inventory.put/2"
           ]

    assert run!(root, home, ["refs", "Stock"]) == []

    assert run!(root, home, ["refs", "Shop.Pricing"]) == [
             "lib/shop.ex:3 alias Shop.Pricing",
             "lib/shop.ex:11 call Shop.Pricing.apply/2"
           ]

    assert run!(root, home, ["refs", "Shop.Pricing.Rules.default"]) == [
             "lib/shop/pricing.ex:8 call Shop.Pricing.Rules.default/0"
           ]

    assert run!(root, home, ["refs", "Shop.Format"]) == ["lib/shop.ex:5 import Shop.Format"]

    assert run!(root, home, ["refs", "Agent"]) == [
             "lib/shop/inventory.ex:2 use Agent",
             "lib/shop/inventory.ex:3 call Agent.update/2",
             "lib/shop/inventory.ex:4 call Agent.get/2"
           ]

    assert run!(root, home, ["refs", "Logger"]) == [
             "lib/shop.ex:6 require Logger",
             "lib/shop.ex:18 call Logger.info/1"
           ]

    assert run!(root, home, ["refs", "Map.put"]) == ["lib/shop/inventory.ex:3 call Map.put/3"]
  end

  test "E4 malformed symbols, refs and map command lines are usage errors before any index work" do
    args = [
      ["symbols"],
      ["symbols", "a", "b"],
      ["symbols", "Shop", "--limit", "0"],
      ["symbols", "Shop", "--limit"],
      ["symbols", "Shop", "--limit", "1", "--limit", "2"],
      ["symbols", "Shop", "--tokens", "5"],
      ["symbols", "Shop", "--focus", "lib/"],
      ["symbols", "Shop", "--bogus"],
      ["refs"],
      ["refs", "a", "b"],
      ["refs", "Shop", "--limit", "x"],
      ["map", "extra"],
      ["map", "--limit", "2"],
      ["map", "--tokens"],
      ["map", "--tokens", "0"],
      ["map", "--tokens", "5", "--tokens", "6"],
      ["map", "--focus"],
      ["map", "--bogus"],
      ["search", "x", "--tokens", "5"],
      ["index", "--focus", "lib/"]
    ]

    {root, home} = CtxFixture.create!()
    for arg <- args, do: usage!(root, home, arg)
    assert File.ls!(home) == []
  end

  test "F1 a second fixture with unrelated names gets its symbols" do
    {root, home} = CtxFixture.create_alias!()

    for {path, bytes} <- CtxFixture.alias_sources() do
      assert File.read!(Path.join(root, path)) == bytes

      assert :crypto.hash(:sha256, bytes) ==
               Base.decode16!(CtxFixture.alias_hashes()[path], case: :lower)
    end

    assert run!(root, home, ["index"]) == [
             "index " <> CtxFixture.index_path(home, root),
             "project " <> CtxFixture.project_id(root),
             "rebuilt yes",
             "reindexed lib/acme/billing.ex",
             "reindexed lib/acme/report.ex",
             "reindexed lib/outer.ex",
             "files 3 reindexed 3 removed 0"
           ]

    assert run!(root, home, ["symbols", "Acme"]) == [
             "lib/acme/billing.ex:1 defmodule Acme.Billing",
             "lib/acme/billing.ex:2 def Acme.Billing.dispatch/1",
             "lib/acme/billing.ex:7 defmodule Acme.Billing.Invoice",
             "lib/acme/billing.ex:8 def Acme.Billing.Invoice.build/1",
             "lib/acme/billing.ex:11 def Acme.Billing.hook/0",
             "lib/acme/report.ex:1 defmodule Acme.Report",
             "lib/acme/report.ex:2 def Acme.Report.run/0"
           ]

    assert run!(root, home, ["symbols", "Outer"]) == [
             "lib/outer.ex:1 defmodule Outer",
             "lib/outer.ex:2 def Outer.f/1",
             "lib/outer.ex:3 def Outer.g/0",
             "lib/outer.ex:7 defmodule Outer.Inner",
             "lib/outer.ex:9 def Outer.Inner.h/0",
             "lib/outer.ex:11 def Outer.k/0"
           ]
  end

  test "F2 aliases resolve by lexical scope" do
    {root, home} = CtxFixture.create_alias!()

    assert run!(root, home, ["refs", "Acme.Mailer"]) == [
             "lib/acme/billing.ex:2 call Acme.Mailer.deliver/1",
             "lib/acme/billing.ex:5 alias Acme.Mailer",
             "lib/acme/billing.ex:11 capture Acme.Mailer.deliver/2"
           ]

    assert run!(root, home, ["refs", "Acme.Billing.Invoice.build"]) == [
             "lib/acme/billing.ex:2 call Acme.Billing.Invoice.build/1"
           ]

    assert run!(root, home, ["refs", "Acme.Ledger.Entry"]) == [
             "lib/acme/billing.ex:4 alias Acme.Ledger.Entry",
             "lib/acme/billing.ex:8 call Acme.Ledger.Entry.new/1"
           ]

    assert run!(root, home, ["refs", "Acme.Clock"]) == [
             "lib/acme/billing.ex:5 alias Acme.Clock",
             "lib/acme/billing.ex:8 call Acme.Clock.stamp/2"
           ]

    assert run!(root, home, ["refs", "Row"]) == ["lib/acme/report.ex:2 call Row.new/1"]
    assert run!(root, home, ["refs", "Invoice"]) == []
    assert run!(root, home, ["refs", "Mailer"]) == []

    assert run!(root, home, ["refs", "Kit.Box"]) == [
             "lib/outer.ex:2 call Kit.Box.new/0",
             "lib/outer.ex:4 alias Kit.Box",
             "lib/outer.ex:5 call Kit.Box.open/0",
             "lib/outer.ex:11 call Kit.Box.close/0"
           ]

    assert run!(root, home, ["refs", "Other.Thing"]) == [
             "lib/outer.ex:8 alias Other.Thing",
             "lib/outer.ex:9 call Other.Thing.open/0"
           ]
  end

  test "F3 the crate has no table of fixture names" do
    literals = [
      "Shop",
      "Cart",
      "Pricing",
      "Tax",
      "Stock",
      "Inventory",
      "Rules",
      "Format",
      "Acme",
      "Row",
      "Invoice",
      "Mailer",
      "Clock",
      "Kit",
      "Outer"
    ]

    for path <- Path.wildcard("native/kogen-ctx/src/**/*.rs"), literal <- literals do
      refute File.read!(path) =~ "\"#{literal}"
    end
  end

  test "G1 a query sees a code edit without index" do
    {root, home} = CtxFixture.create!()
    _ = run!(root, home, ["index"])
    path = Path.join(root, "lib/shop/tax.ex")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        "  def rate, do: @rate",
        "  def rate, do: @rate\n  def vat, do: @rate"
      )
    )

    assert run!(root, home, ["symbols", "Shop.Tax.vat"]) == [
             "lib/shop/tax.ex:5 def Shop.Tax.vat/0"
           ]

    assert run!(root, home, ["index"]) == [
             "index " <> CtxFixture.index_path(home, root),
             "project " <> CtxFixture.project_id(root),
             "rebuilt no",
             "files 11 reindexed 0 removed 0"
           ]
  end

  test "G2 added and deleted code files update symbols and refs" do
    {root, home} = CtxFixture.create!()
    _ = run!(root, home, ["index"])

    File.write!(
      Path.join(root, "lib/shop/extra.ex"),
      "defmodule Shop.Extra do\n  def go, do: Shop.Tax.add(1)\nend\n"
    )

    File.rm!(Path.join(root, "lib/shop/format.ex"))
    assert run!(root, home, ["refs", "Shop.Format"]) == ["lib/shop.ex:5 import Shop.Format"]
    assert run!(root, home, ["symbols", "Shop.Format"]) == []

    assert run!(root, home, ["symbols", "Shop.Extra"]) == [
             "lib/shop/extra.ex:1 defmodule Shop.Extra",
             "lib/shop/extra.ex:2 def Shop.Extra.go/0"
           ]

    assert run!(root, home, ["refs", "Shop.Tax.add"]) == [
             "lib/shop.ex:12 call Shop.Tax.add/1",
             "lib/shop/extra.ex:2 call Shop.Tax.add/1",
             "lib/shop/inventory.ex:5 capture Shop.Tax.add/1"
           ]
  end

  test "G3 an index written by the schema-1 binary is rebuilt" do
    {root, home} = CtxFixture.create!()
    _ = run!(root, home, ["index"])
    index = CtxFixture.index_path(home, root)

    {_, 0} =
      System.cmd("/usr/bin/sqlite3", [
        index,
        "drop table symbols; drop table refs; update meta set value = '1' where key = 'schema_version'"
      ])

    assert run!(root, home, ["index"]) == [
             "index " <> index,
             "project " <> CtxFixture.project_id(root),
             "rebuilt yes",
             "reindexed .kogen/intents/complete/stray-rework/INTENT.md",
             "reindexed .kogen/intents/complete/stray-rework/scenarios.yaml",
             "reindexed .kogen/intents/drafts/cart-discounts/INTENT.md",
             "reindexed .kogen/memory/lesson/lesson-stray-rework.md",
             "reindexed lib/shop.ex",
             "reindexed lib/shop/cart.ex",
             "reindexed lib/shop/format.ex",
             "reindexed lib/shop/inventory.ex",
             "reindexed lib/shop/pricing.ex",
             "reindexed lib/shop/tax.ex",
             "reindexed test/shop_test.exs",
             "files 11 reindexed 11 removed 0"
           ]

    {version, 0} =
      System.cmd("/usr/bin/sqlite3", [
        index,
        "select value from meta where key = 'schema_version'"
      ])

    assert version == "2\n"

    assert run!(root, home, ["symbols", "Shop.Cart.total"]) == [
             "lib/shop/cart.ex:2 def Shop.Cart.total/1",
             "lib/shop/cart.ex:3 def Shop.Cart.total/2"
           ]
  end

  test "G4 a rebuilt index answers byte-identically" do
    {root, home} = CtxFixture.create!()
    _ = run!(root, home, ["index"])
    index = CtxFixture.index_path(home, root)
    s = run!(root, home, ["symbols", "Shop"])
    r = run!(root, home, ["refs", "Shop.Cart"])
    m = run!(root, home, ["map"])

    assert s == [
             "lib/shop.ex:1 defmodule Shop",
             "lib/shop.ex:8 def Shop.checkout/2",
             "lib/shop.ex:16 def Shop.restock/1",
             "lib/shop.ex:18 defp Shop.audit/1",
             "lib/shop.ex:20 defmacro Shop.trace/1",
             "lib/shop.ex:22 defguard Shop.positive/1",
             "lib/shop/cart.ex:1 defmodule Shop.Cart",
             "lib/shop/cart.ex:2 def Shop.Cart.total/1",
             "lib/shop/cart.ex:3 def Shop.Cart.total/2",
             "lib/shop/cart.ex:5 def Shop.Cart.empty/0",
             "lib/shop/cart.ex:7 def Shop.Cart.merge/2",
             "lib/shop/format.ex:1 defmodule Shop.Format",
             "lib/shop/format.ex:2 def Shop.Format.money/1",
             "lib/shop/inventory.ex:1 defmodule Shop.Inventory",
             "lib/shop/inventory.ex:3 def Shop.Inventory.put/2",
             "lib/shop/inventory.ex:4 def Shop.Inventory.lookup/1",
             "lib/shop/inventory.ex:5 def Shop.Inventory.fetcher/0",
             "lib/shop/pricing.ex:1 defmodule Shop.Pricing",
             "lib/shop/pricing.ex:2 def Shop.Pricing.apply/2",
             "lib/shop/pricing.ex:4 defmodule Shop.Pricing.Rules",
             "lib/shop/pricing.ex:5 def Shop.Pricing.Rules.default/0",
             "lib/shop/pricing.ex:8 def Shop.Pricing.rules/0",
             "lib/shop/tax.ex:1 defmodule Shop.Tax",
             "lib/shop/tax.ex:3 def Shop.Tax.add/1",
             "lib/shop/tax.ex:4 def Shop.Tax.rate/0",
             "test/shop_test.exs:1 defmodule ShopTest"
           ]

    assert r == [
             "lib/shop.ex:2 alias Shop.Cart",
             "lib/shop.ex:10 call Shop.Cart.total/1",
             "lib/shop/cart.ex:7 call Shop.Cart.total/1",
             "test/shop_test.exs:3 alias Shop.Cart",
             "test/shop_test.exs:6 call Shop.Cart.total/1"
           ]

    assert m == [
             "lib/shop/tax.ex",
             "  defmodule Shop.Tax",
             "  def Shop.Tax.add/1",
             "  def Shop.Tax.rate/0",
             "lib/shop/cart.ex",
             "  defmodule Shop.Cart",
             "  def Shop.Cart.total/1",
             "  def Shop.Cart.total/2",
             "  def Shop.Cart.empty/0",
             "  def Shop.Cart.merge/2",
             "lib/shop/inventory.ex",
             "  defmodule Shop.Inventory",
             "  def Shop.Inventory.put/2",
             "  def Shop.Inventory.lookup/1",
             "  def Shop.Inventory.fetcher/0",
             "lib/shop/pricing.ex",
             "  defmodule Shop.Pricing",
             "  def Shop.Pricing.apply/2",
             "  defmodule Shop.Pricing.Rules",
             "  def Shop.Pricing.Rules.default/0",
             "  def Shop.Pricing.rules/0",
             "lib/shop/format.ex",
             "  defmodule Shop.Format",
             "  def Shop.Format.money/1",
             "lib/shop.ex",
             "  defmodule Shop",
             "  def Shop.checkout/2",
             "  def Shop.restock/1",
             "  defmacro Shop.trace/1",
             "  defguard Shop.positive/1",
             "test/shop_test.exs",
             "  defmodule ShopTest"
           ]

    for damage <- [:deleted, :corrupt, :old] do
      case damage do
        :deleted ->
          File.rm!(index)

        :corrupt ->
          File.write!(index, "not a database")

        :old ->
          {_, 0} =
            System.cmd("/usr/bin/sqlite3", [
              index,
              "update meta set value = '0' where key = 'schema_version'"
            ])
      end

      assert Enum.at(run!(root, home, ["index"]), 2) == "rebuilt yes"
      assert run!(root, home, ["symbols", "Shop"]) == s
      assert run!(root, home, ["refs", "Shop.Cart"]) == r
      assert run!(root, home, ["map"]) == m
    end
  end
end
