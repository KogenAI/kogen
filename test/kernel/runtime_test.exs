defmodule Kogen.Kernel.RuntimeTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.Runtime

  test "project PATH keeps mise available alongside the target toolchain" do
    runtime = Runtime.new(%{"PATH" => "/system/bin"}, "/mise/bin/mise", nil, "/erts", "/erts/bin")
    environment = Runtime.process_env(runtime, %{"PATH" => "/target/bin"})

    assert environment["PATH"] == "/mise/bin:/target/bin"
  end

  test "escript path markers resolve symlinks to their immutable generation", %{
    tmp_dir: tmp_dir
  } do
    generation = Path.join([tmp_dir, "gen", "kogen"])
    link = Path.join([tmp_dir, "bin", "kogen"])
    File.mkdir_p!(Path.dirname(generation))
    File.mkdir_p!(Path.dirname(link))
    File.write!(generation, "escript")
    File.ln_s!(generation, link)

    assert {:ok, ^generation} = Runtime.resolve_script_path(link)
  end
end
