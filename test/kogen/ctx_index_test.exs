Code.require_file("../support/ctx_fixture.ex", __DIR__)

defmodule Kogen.CtxIndexTest do
  use ExUnit.Case, async: true
  alias Kogen.Test.CtxFixture

  defp lines(out), do: String.split(out, "\n", trim: true)

  defp initial(root, home, rebuilt) do
    index = CtxFixture.index_path(home, root)

    [
      "index " <> index,
      "project " <> CtxFixture.project_id(root),
      "rebuilt " <> rebuilt,
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
  end

  defp run_index(binary, root, home, args \\ ["index"]) do
    {out, err, status} = CtxFixture.run(binary, root, home, args)
    assert err == ""
    assert status == 0
    lines(out)
  end

  test "A1 indexes exactly the canonical fixture files and leaves git status unchanged" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()

    {before, 0} =
      System.cmd("git", ["status", "--porcelain", "--ignored", "--untracked-files=all"], cd: root)

    assert run_index(binary, root, home) == initial(root, home, "yes")
    assert File.regular?(CtxFixture.index_path(home, root))

    assert Enum.all?(CtxFixture.hashes(), fn {path, hash} ->
             bytes = File.read!(Path.join(root, path))
             :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == hash
           end)

    {after_status, 0} =
      System.cmd("git", ["status", "--porcelain", "--ignored", "--untracked-files=all"], cd: root)

    assert after_status == before
  end

  test "A2 symlinked roots and subdirectories reuse one index" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    _ = run_index(binary, root, home)
    link = Path.join(System.tmp_dir!(), "ctx-link-#{System.unique_integer([:positive])}")
    File.ln_s!(root, link)

    assert run_index(binary, root, home, ["index", "--root", link]) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "files 11 reindexed 0 removed 0"
           ]

    assert run_index(binary, Path.join(root, "lib"), home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "files 11 reindexed 0 removed 0"
           ]

    assert File.ls!(home) == [CtxFixture.project_id(root)]
  end

  test "A3 defaults to HOME when KOGEN_CTX_HOME is unset or empty" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()

    for {h, value} <- [
          {Path.join(System.tmp_dir!(), "ctx-home-#{System.unique_integer([:positive])}"), nil},
          {Path.join(System.tmp_dir!(), "ctx-home-#{System.unique_integer([:positive])}"), ""}
        ] do
      {out, err, status} =
        CtxFixture.run(binary, root, home, ["index"], [{"HOME", h}, {"KOGEN_CTX_HOME", value}])

      assert {err, status} == {"", 0}

      assert hd(lines(out)) ==
               "index " <>
                 Path.join([
                   h,
                   "Library/Caches/Kogen/ctx",
                   CtxFixture.project_id(root),
                   "index.sqlite"
                 ])

      assert File.regular?(
               Path.join([
                 h,
                 "Library/Caches/Kogen/ctx",
                 CtxFixture.project_id(root),
                 "index.sqlite"
               ])
             )
    end
  end

  test "A4 rebuilds deleted, corrupt, old-schema and foreign-root indexes identically" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    first = run_index(binary, root, home)
    {search, "", 0} = CtxFixture.run(binary, root, home, ["search", "the"])

    assert lines(search) == [
             ".kogen/intents/complete/stray-rework/INTENT.md:9-9 [intent] The Developer deletes each stray path and the guard passes.",
             ".kogen/intents/complete/stray-rework/scenarios.yaml:1-3 [intent] - id: stray-file-reworked given: A fixture with a stray file. then: The guard reworks the stray file.",
             ".kogen/intents/complete/stray-rework/INTENT.md:5-5 [intent] A stray Mix lock directory stopped the Build."
           ]

    index = CtxFixture.index_path(home, root)

    damages = [
      fn -> File.rm!(index) end,
      fn -> File.write!(index, "not a database") end,
      fn ->
        System.cmd("/usr/bin/sqlite3", [
          index,
          "update meta set value = '0' where key = 'schema_version'"
        ])
      end,
      fn ->
        System.cmd("/usr/bin/sqlite3", [
          index,
          "update meta set value = '/elsewhere' where key = 'root'"
        ])
      end
    ]

    for damage <- damages do
      damage.()
      assert run_index(binary, root, home) == first
      {out, "", 0} = CtxFixture.run(binary, root, home, ["search", "the"])
      assert lines(out) == lines(search)
    end
  end

  test "A5 validates usage before filesystem work and reports runtime paths exactly" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    outside = Path.join(System.tmp_dir!(), "ctx-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    {_, err, 1} = CtxFixture.run(binary, outside, home, ["index"])

    assert err ==
             "kogen-ctx: not a Git checkout: " <> Kogen.ProjectScope.canonical(outside) <> "\n"

    outside_home =
      Path.join(System.tmp_dir!(), "ctx-outside-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_home)

    for args <- [[], ["bogus"]] do
      {out, err, 2} = CtxFixture.run(binary, outside, outside_home, args)
      assert out == ""
      assert String.starts_with?(err, "usage: kogen-ctx")
    end

    assert File.ls!(outside_home) == []

    missing = Path.join(outside, "missing")
    {out, err, 1} = CtxFixture.run(binary, root, home, ["index", "--root", missing])
    assert {out, err} == {"", "kogen-ctx: not a directory: #{missing}\n"}

    usage_cases = [
      [],
      ["bogus"],
      ["index", "--root"],
      ["index", "extra"],
      ["index", "--bogus"],
      ["index", "--limit", "2"],
      ["index", "--root", root, "--root", root],
      ["search", "--limit", "2"],
      ["search", "stray", "--limit", "0"],
      ["search", "stray", "--limit", "-1"],
      ["search", "stray", "--limit", "abc"],
      ["search", "stray", "--limit"],
      ["search", "stray", "--bogus"]
    ]

    for args <- usage_cases do
      {out, err, 2} = CtxFixture.run(binary, root, home, args)
      assert out == ""
      assert String.starts_with?(err, "usage: kogen-ctx")
    end

    assert File.ls!(home) == []
  end

  test "A6 gives HOME and write failures actionable errors" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()

    for env <- [[{"HOME", nil}, {"KOGEN_CTX_HOME", nil}], [{"HOME", ""}, {"KOGEN_CTX_HOME", ""}]] do
      {out, err, 1} = CtxFixture.run(binary, root, home, ["index"], env)
      assert out == ""
      assert err == "kogen-ctx: HOME is not set; set KOGEN_CTX_HOME to a writable directory\n"
      refute File.exists?(Path.join(root, "Library"))
    end

    ro = Path.join(System.tmp_dir!(), "ctx-ro-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ro)
    File.chmod!(ro, 0o500)
    on_exit(fn -> File.chmod(ro, 0o700) end)
    {out, err, 1} = CtxFixture.run(binary, root, ro, ["index"])
    assert out == ""

    assert String.starts_with?(
             err,
             "kogen-ctx: cannot write index at #{CtxFixture.index_path(ro, root)}:"
           )

    assert err =~ "set KOGEN_CTX_HOME to a writable directory"

    _ = run_index(binary, root, home)
    index = CtxFixture.index_path(home, root)
    File.chmod!(index, 0o444)
    File.chmod!(Path.dirname(index), 0o500)

    on_exit(fn ->
      File.chmod(Path.dirname(index), 0o700)
      File.chmod(index, 0o600)
    end)

    File.write!(Path.join(root, "lib/shop/tax.ex"), "# edit\n", [:append])

    for args <- [["index"], ["search", "the"]] do
      {out, err, 1} = CtxFixture.run(binary, root, home, args)
      assert out == ""
      assert String.starts_with?(err, "kogen-ctx: cannot write index at #{index}:")
      assert err =~ "set KOGEN_CTX_HOME to a writable directory"
    end
  end

  test "B1 ignores unchanged and mtime-only changes" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    _ = run_index(binary, root, home)

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "files 11 reindexed 0 removed 0"
           ]

    File.touch!(Path.join(root, "lib/shop/cart.ex"), System.os_time(:second) + 120)

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "files 11 reindexed 0 removed 0"
           ]
  end

  test "B2 rehashes only an edited file with git blob id" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    _ = run_index(binary, root, home)
    path = Path.join(root, "lib/shop/tax.ex")
    bytes = File.read!(path) |> String.replace("  def rate", "  def vat, do: @rate\n  def rate")
    File.write!(path, bytes)

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "reindexed lib/shop/tax.ex",
             "files 11 reindexed 1 removed 0"
           ]

    {stored, 0} =
      System.cmd(
        "/usr/bin/sqlite3",
        [
          CtxFixture.index_path(home, root),
          "select blob from files where path = 'lib/shop/tax.ex'"
        ],
        cd: root
      )

    {actual, 0} = System.cmd("git", ["hash-object", "--no-filters", "lib/shop/tax.ex"], cd: root)
    assert String.trim(stored) == String.trim(actual)
  end

  test "B3 picks up added, deleted and ignored-draft changes" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    _ = run_index(binary, root, home)

    File.write!(
      Path.join(root, "lib/shop/extra.ex"),
      "defmodule Shop.Extra do\n  def go, do: Shop.Tax.add(1)\nend\n"
    )

    File.rm!(Path.join(root, "lib/shop/format.ex"))

    File.write!(
      Path.join(root, ".kogen/intents/drafts/cart-discounts/INTENT.md"),
      "# Add cart discounts\n\nDiscounts apply before tax in Shop.Pricing.\nAlso free shipping.\n"
    )

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "reindexed .kogen/intents/drafts/cart-discounts/INTENT.md",
             "reindexed lib/shop/extra.ex",
             "removed lib/shop/format.ex",
             "files 11 reindexed 2 removed 1"
           ]

    {out, "", 0} = CtxFixture.run(binary, root, home, ["search", "shipping"])

    assert lines(out) == [
             ".kogen/intents/drafts/cart-discounts/INTENT.md:3-4 [intent] Discounts apply before tax in Shop.Pricing. Also free shipping."
           ]

    {count, 0} =
      System.cmd("/usr/bin/sqlite3", [
        CtxFixture.index_path(home, root),
        "select count(*) from files where path = 'lib/shop/format.ex'"
      ])

    assert String.trim(count) == "0"
  end

  test "B4 search refreshes before answering and index reports no work after" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    _ = run_index(binary, root, home)
    draft = Path.join(root, ".kogen/intents/drafts/cart-discounts/INTENT.md")
    File.write!(draft, File.read!(draft) <> "Also free shipping.\n")
    {out, "", 0} = CtxFixture.run(binary, root, home, ["search", "shipping"])

    assert lines(out) == [
             ".kogen/intents/drafts/cart-discounts/INTENT.md:3-4 [intent] Discounts apply before tax in Shop.Pricing. Also free shipping."
           ]

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "files 11 reindexed 0 removed 0"
           ]

    File.rm!(draft)
    {out, "", 0} = CtxFixture.run(binary, root, home, ["search", "shipping"])
    assert out == ""

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "files 10 reindexed 0 removed 0"
           ]
  end

  test "B5 removes rows when an indexed file becomes non-UTF8" do
    {root, home} = CtxFixture.create!()
    binary = CtxFixture.binary()
    _ = run_index(binary, root, home)
    File.write!(Path.join(root, "lib/shop/format.ex"), <<0xE9, ?\n>>, [:append])

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "removed lib/shop/format.ex",
             "files 10 reindexed 0 removed 1"
           ]

    {count, 0} =
      System.cmd("/usr/bin/sqlite3", [
        CtxFixture.index_path(home, root),
        "select count(*) from files where path = 'lib/shop/format.ex'"
      ])

    assert String.trim(count) == "0"

    assert run_index(binary, root, home) == [
             "index #{CtxFixture.index_path(home, root)}",
             "project #{CtxFixture.project_id(root)}",
             "rebuilt no",
             "files 10 reindexed 0 removed 0"
           ]
  end
end
