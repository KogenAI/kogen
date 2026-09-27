defmodule Kogen.Test.CtxFixture do
  @moduledoc "Self-contained git fixture for kogen-ctx tests."
  alias Kogen.Build.Workspace

  @sources %{
    "lib/shop/cart.ex" => ~S"""
    defmodule Shop.Cart do
      def total(cart), do: Enum.sum(cart.items)
      def total(cart, discount) when discount > 0, do: total(cart) - discount
      def total(cart, _discount), do: total(cart)
      def empty, do: %__MODULE__{}
      defstruct items: []
      def merge(a, b), do: __MODULE__.total(a) + total(b)
    end
    """,
    "lib/shop/format.ex" => ~S"""
    defmodule Shop.Format do
      def money(value), do: "$" <> Float.to_string(value)
    end
    """,
    "lib/shop/inventory.ex" => ~S"""
    defmodule Shop.Inventory do
      use Agent
      def put(item, count), do: Agent.update(__MODULE__, &Map.put(&1, item, count))
      def lookup(item), do: Agent.get(__MODULE__, &Map.get(&1, item))
      def fetcher, do: &Shop.Tax.add/1
    end
    """,
    "lib/shop/pricing.ex" => ~S"""
    defmodule Shop.Pricing do
      def apply(total, opts), do: total - Keyword.get(opts, :discount, 0)

      defmodule Rules do
        def default, do: []
      end

      def rules, do: Rules.default()
    end
    """,
    "lib/shop/tax.ex" => ~S"""
    defmodule Shop.Tax do
      @rate 0.2
      def add(total), do: total * (1 + @rate)
      def rate, do: @rate
    end
    """,
    "lib/shop.ex" => ~S"""
    defmodule Shop do
      alias Shop.Cart
      alias Shop.{Pricing, Tax}
      alias Shop.Inventory, as: Stock
      import Shop.Format
      require Logger

      def checkout(cart, opts \\ []) do
        cart
        |> Cart.total()
        |> Pricing.apply(opts)
        |> Tax.add()
        |> money()
      end

      def restock(item), do: Stock.put(item, 1)

      defp audit(event), do: Logger.info(inspect(event))

      defmacro trace(expr), do: expr

      defguard positive(n) when n > 0
    end
    """,
    "test/shop_test.exs" => ~S"""
    defmodule ShopTest do
      use ExUnit.Case
      alias Shop.Cart

      test "total" do
        assert Cart.total(%{items: [1, 2]}) == 3
      end
    end
    """
  }
  @hashes %{
    "lib/shop/cart.ex" => "95c4253dc537f22bd5da4b240e578e8450e7dad888debb45dded3b3247c9dedc",
    "lib/shop/format.ex" => "969cbe862d666d2f15330ec6f964e829fedbaea60de800e5b3573f2435612b7a",
    "lib/shop/inventory.ex" => "e85ff40c86d85b5a856dd89b985ba78863eb75d626c1abda6b7847f112653338",
    "lib/shop/pricing.ex" => "153b97be6681c8b5b7e5772c38fd12f3adb0ea28709925acc6567e07f473c602",
    "lib/shop/tax.ex" => "ccd8a1bdbbb04ba37ac2fe94e5379909f33a81f8e594b08e396729d264186fba",
    "lib/shop.ex" => "f935965dfac50cd7de8a8bc79f3f50882558f965897414e1f95dae870a9ad347",
    "test/shop_test.exs" => "59f23a5513964b133c5496d1c8953d6e1d8790ade8caf75f0d65c6ed83793200"
  }
  def sources, do: @sources
  def hashes, do: @hashes

  def project_id(root), do: Workspace.project_id(root)

  def index_path(home, root), do: Path.join([home, project_id(root), "index.sqlite"])

  def binary do
    key = {__MODULE__, :binary}

    case :persistent_term.get(key, nil) do
      nil ->
        root = File.cwd!()

        case Kogen.Ctx.build(root) do
          {:ok, path} ->
            :persistent_term.put(key, path)
            path

          {:error, reason} ->
            raise reason
        end

      path ->
        path
    end
  end

  def create! do
    nonce = "#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "kogen-ctx-#{nonce}")
    File.mkdir_p!(root)
    for {path, bytes} <- @sources, do: write!(root, path, bytes)

    write!(
      root,
      ".gitignore",
      "/_build/\n/deps/\n.kogen/intents/drafts/\n.kogen/intents/approved/\n*-raw/\n"
    )

    write!(
      root,
      ".kogen/intents/complete/stray-rework/INTENT.md",
      "# Rework stray paths\n\n## Why\n\nA stray Mix lock directory stopped the Build.\n\n## Outcome\n\nThe Developer deletes each stray path and the guard passes.\n"
    )

    write!(
      root,
      ".kogen/intents/complete/stray-rework/scenarios.yaml",
      "- id: stray-file-reworked\n  given: A fixture with a stray file.\n  then: The guard reworks the stray file.\n"
    )

    write!(
      root,
      ".kogen/memory/lesson/lesson-stray-rework.md",
      "---\nid: \"lesson-stray-rework\"\nkind: \"lesson\"\nclaim: \"stray-rework published after 2 stopped Builds: stray Mix lock directories\"\n---\n"
    )

    {_, 0} = System.cmd("git", ["init", "-q", root])
    File.write!(Path.join(root, ".git/empty-excludes"), "")
    git!(root, ["config", "core.excludesFile", Path.join(root, ".git/empty-excludes")])
    git!(root, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "add", "."])

    git!(root, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "-qm",
      "fixture"
    ])

    write!(
      root,
      ".kogen/intents/drafts/cart-discounts/INTENT.md",
      "# Add cart discounts\n\nDiscounts apply before tax in Shop.Pricing.\n"
    )

    write!(
      root,
      ".kogen/intents/complete/stray-rework/evidence/codex-raw/stream.md",
      "stray stray stray\n"
    )

    write!(root, "deps/dep/lib/dep.ex", "defmodule Dep do def x, do: 1 end\n")
    write!(root, "lib/shop/latin1.ex", <<35, 32, 99, 97, 102, 233, 10>>)

    write!(
      root,
      ".kogen/intents/complete/stray-rework/evidence/big.md",
      String.duplicate("stray\n", 102_400)
    )

    :ok = :file.make_symlink(~c"tax.ex", String.to_charlist(Path.join(root, "lib/shop/link.ex")))
    home = Path.join(System.tmp_dir!(), "kogen-ctx-home-#{nonce}")
    File.mkdir_p!(home)
    {root, home}
  end

  def run(binary, root, home, args, extra_env \\ []) do
    err = Path.join(System.tmp_dir!(), "kogen-ctx-stderr-#{System.unique_integer([:positive])}")

    base_env = %{"PATH" => "/usr/bin:/bin", "KOGEN_CTX_HOME" => home}

    env =
      Enum.reduce(extra_env, base_env, fn {key, value}, acc ->
        Map.put(acc, key, value || "")
      end)

    {out, status} =
      System.cmd(
        "/bin/sh",
        ["-c", "err=\"$1\"; shift; exec \"$@\" 2>\"$err\"", "kogen-ctx", err, binary | args],
        cd: root,
        env: Map.to_list(env)
      )

    stderr = if File.exists?(err), do: File.read!(err), else: ""
    File.rm(err)
    {out, stderr, status}
  end

  defp write!(root, rel, bytes) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end
end
