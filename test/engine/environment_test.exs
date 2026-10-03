defmodule Kogen.Engine.EnvironmentTest do
  use Kogen.Testkit.Case

  alias Kogen.Engine.Environment
  alias Kogen.Engine.Runtime

  test "includes mise failure output in the toolchain error", %{tmp_dir: tmp_dir} do
    mise = Path.join(tmp_dir, "mise")
    File.write!(mise, "#!/bin/sh\nprintf '%s\\n' 'mise diagnostic output'\nexit 17\n")
    File.chmod!(mise, 0o755)

    runtime = Runtime.new(%{"PATH" => "/usr/bin:/bin"}, mise, nil, "/runtime", "/runtime/bin")

    assert {:error, {:toolchain_failed, detail}} = Environment.project(tmp_dir, runtime)
    assert detail =~ "mise env failed"
    assert detail =~ "mise diagnostic output"
  end
end
