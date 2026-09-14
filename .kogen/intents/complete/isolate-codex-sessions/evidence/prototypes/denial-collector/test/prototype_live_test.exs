defmodule Kogen.PrototypeLiveTest do
  use Kogen.IsolatedCase, async: false
  @tag :live
  @tag timeout: 900_000
  test "Intent-local prototype completes native compatibility" do
    {:ok, config} = Kogen.Intent.read_config()
    {:ok, runtime} = Kogen.Codex.installed()
    {:ok, scope} = Kogen.Codex.effective_scope(File.cwd!())
    System.put_env("KOGEN_CODEX_ROOT", Path.expand(".kogen/runtime/native-prototype"))
    result = Kogen.Codex.Compatibility.run(runtime, scope, config)
    File.write!(".kogen/prototype-result.txt", inspect(result))
    assert {:ok, _evidence} = result
  end
end
