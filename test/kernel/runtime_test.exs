defmodule Kogen.Kernel.RuntimeTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.Runtime

  test "project PATH keeps mise available alongside the target toolchain" do
    runtime = Runtime.new(%{"PATH" => "/system/bin"}, "/mise/bin/mise", nil, "/erts", "/erts/bin")
    environment = Runtime.process_env(runtime, %{"PATH" => "/target/bin"})

    assert environment["PATH"] == "/mise/bin:/target/bin"
  end
end
