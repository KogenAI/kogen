Code.require_file("../support/ctx_fixture.ex", __DIR__)

defmodule Kogen.CtxMapTest do
  use ExUnit.Case, async: true
  alias Kogen.Test.CtxFixture

  defp run!(root, home, args) do
    {out, err, 0} = CtxFixture.run(CtxFixture.binary(), root, home, args)
    assert err == ""
    String.split(out, "\n", trim: true)
  end

  defp blocks do
    %{
      "lib/shop/tax.ex" => [
        "lib/shop/tax.ex",
        "  defmodule Shop.Tax",
        "  def Shop.Tax.add/1",
        "  def Shop.Tax.rate/0"
      ],
      "lib/shop/cart.ex" => [
        "lib/shop/cart.ex",
        "  defmodule Shop.Cart",
        "  def Shop.Cart.total/1",
        "  def Shop.Cart.total/2",
        "  def Shop.Cart.empty/0",
        "  def Shop.Cart.merge/2"
      ],
      "lib/shop/inventory.ex" => [
        "lib/shop/inventory.ex",
        "  defmodule Shop.Inventory",
        "  def Shop.Inventory.put/2",
        "  def Shop.Inventory.lookup/1",
        "  def Shop.Inventory.fetcher/0"
      ],
      "lib/shop/pricing.ex" => [
        "lib/shop/pricing.ex",
        "  defmodule Shop.Pricing",
        "  def Shop.Pricing.apply/2",
        "  defmodule Shop.Pricing.Rules",
        "  def Shop.Pricing.Rules.default/0",
        "  def Shop.Pricing.rules/0"
      ],
      "lib/shop/format.ex" => [
        "lib/shop/format.ex",
        "  defmodule Shop.Format",
        "  def Shop.Format.money/1"
      ],
      "lib/shop.ex" => [
        "lib/shop.ex",
        "  defmodule Shop",
        "  def Shop.checkout/2",
        "  def Shop.restock/1",
        "  defmacro Shop.trace/1",
        "  defguard Shop.positive/1"
      ],
      "test/shop_test.exs" => ["test/shop_test.exs", "  defmodule ShopTest"]
    }
  end

  test "H1 map prints every block in PageRank order" do
    {root, home} = CtxFixture.create!()

    expected = [
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

    assert run!(root, home, ["map"]) == expected
    assert blocks()["lib/shop/tax.ex"] == Enum.take(expected, 4)
  end

  test "H2 the budget stops at the first block that does not fit" do
    {root, home} = CtxFixture.create!()

    assert run!(root, home, ["map", "--tokens", "25"]) == [
             "lib/shop/tax.ex",
             "  defmodule Shop.Tax",
             "  def Shop.Tax.add/1",
             "  def Shop.Tax.rate/0",
             "... 6 more files"
           ]

    assert run!(root, home, ["map", "--tokens", "64"]) == [
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
             "... 5 more files"
           ]

    assert run!(root, home, ["map", "--tokens", "10"]) == ["... 7 more files"]
  end

  test "H3 focus personalizes the ranking" do
    {root, home} = CtxFixture.create!()

    assert run!(root, home, ["map", "--focus", "test/shop_test.exs"]) ==
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
               &blocks()[&1]
             )

    assert run!(root, home, ["map", "--focus", "lib/shop/"]) ==
             Enum.flat_map(
               [
                 "lib/shop/tax.ex",
                 "lib/shop/cart.ex",
                 "lib/shop/format.ex",
                 "lib/shop/inventory.ex",
                 "lib/shop/pricing.ex",
                 "lib/shop.ex",
                 "test/shop_test.exs"
               ],
               &blocks()[&1]
             )
  end

  test "H4 bad map arguments are usage errors" do
    {root, home} = CtxFixture.create!()

    for args <- [
          ["map", "--focus", "nope.ex"],
          ["map", "--focus", "lib/nope/"],
          ["map", "--tokens", "x"],
          ["map", "--focus", "lib/shop/tax.ex", "--focus", "nope.ex"]
        ] do
      {out, err, 2} = CtxFixture.run(CtxFixture.binary(), root, home, args)
      assert out == ""

      assert err ==
               "usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR] | kogen-ctx symbols <query> [--limit N] [--root DIR] | kogen-ctx refs <target> [--limit N] [--root DIR] | kogen-ctx map [--tokens N] [--focus PATH]... [--root DIR] | kogen-ctx mcp [--root DIR]\n"
    end
  end

  test "H5 the rank values are the specified formula" do
    root = File.cwd!()

    {out, status} =
      System.cmd(
        "cargo",
        [
          "test",
          "--release",
          "--locked",
          "--offline",
          "--manifest-path",
          "native/kogen-ctx/Cargo.toml",
          "--target-dir",
          "_build/cargo",
          "map_rank_values"
        ],
        cd: root,
        stderr_to_stdout: true
      )

    assert status == 0
    assert out =~ ~r/^test (\S+::)?map_rank_values \.\.\. ok$/m
  end
end
