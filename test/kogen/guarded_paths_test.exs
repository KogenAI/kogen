defmodule Kogen.GuardedPathsTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.GuardedPaths

  test "rejects an unguarded executable-bit change when core.filemode is false" do
    root =
      Path.join(System.tmp_dir!(), "kogen-guarded-paths-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "fixture@example.invalid"])
    git!(root, ["config", "user.name", "Fixture"])
    git!(root, ["config", "core.filemode", "false"])

    guarded = Path.join(root, "guarded.txt")
    unguarded = Path.join(root, "unguarded.sh")
    File.write!(guarded, "guarded\n")
    File.write!(unguarded, "#!/bin/sh\n")
    File.chmod!(unguarded, 0o644)
    git!(root, ["add", "guarded.txt", "unguarded.sh"])
    git!(root, ["commit", "-qm", "fixture"])

    assert {:ok, snapshot} = GuardedPaths.capture(root)
    File.chmod!(unguarded, 0o755)

    assert {:error, reason} = GuardedPaths.check(snapshot, ["guarded.txt"])
    assert reason =~ "unguarded.sh"
  end

  defp git!(root, args) do
    assert {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end
end
