defmodule Kogen.CodexDiscoveryTest do
  use ExUnit.Case, async: true

  test "the hostile discovery fixture and native probe pass their synthetic suite" do
    script = Path.expand("../support/codex_discovery_test.py", __DIR__)
    assert {_output, 0} = System.cmd("python3", [script], stderr_to_stdout: true)
  end
end
