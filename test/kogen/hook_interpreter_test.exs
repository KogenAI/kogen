defmodule Kogen.Harness.HookInterpreterTest do
  @moduledoc """
  Claude role hooks run under an absolute interpreter resolved in the
  controller, so a shim-first PATH inside a project with an untrusted
  `mise.toml` cannot make the verification-policy guard silently not run.
  """
  use ExUnit.Case, async: true

  alias Kogen.Harness.Claude
  alias Kogen.Harness.HookInterpreter

  @root Path.expand("../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kogen-hook-interp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "shim"))
    File.mkdir_p!(Path.join(dir, "project/.codex/hooks"))
    on_exit(fn -> File.rm_rf!(dir) end)

    # Simulates mise's shim inside an untrusted project.
    File.write!(Path.join(dir, "shim/python3"), """
    #!/bin/sh
    echo "mise ERROR Config files in $PWD/mise.toml are not trusted" >&2
    exit 1
    """)

    File.chmod!(Path.join(dir, "shim/python3"), 0o755)
    File.write!(Path.join(dir, "project/mise.toml"), "[tools]\npython = \"3.14.7\"\n")
    {_, 0} = System.cmd("git", ["init", "-q"], cd: Path.join(dir, "project"))
    {:ok, dir: dir}
  end

  defp settings, do: Claude.launch_settings() |> Jason.decode!()

  defp commands(settings, event) do
    for %{"hooks" => hooks} <- settings["hooks"][event], %{"command" => c} <- hooks, do: c
  end

  test "generated Claude hook commands use an absolute interpreter, never bare python3" do
    [pre] = commands(settings(), "PreToolUse")
    assert {:ok, python} = HookInterpreter.resolve()
    assert String.starts_with?(pre, "'" <> python <> "' ")
    refute pre =~ ~r/(^|\s)python3 "/
    assert pre =~ ".codex/hooks/verification_policy.py"

    [stop] = commands(settings(), "Stop")
    assert stop =~ ~r/^PATH='[^']*kogen-hook-python-[0-9a-f]+':"\$PATH" sh /
    assert stop =~ ".codex/hooks/check.sh"
  end

  test "the guard still runs, and a crash blocks, under a shim-first PATH in an untrusted mise dir",
       %{dir: dir} do
    project = Path.join(dir, "project")

    for file <- [".codex/hooks/verification_policy.py", ".codex/hooks.json"],
        do: File.cp!(Path.join(@root, file), Path.join(project, file))

    path = Path.join(dir, "shim") <> ":" <> System.get_env("PATH", "")
    [pre] = commands(settings(), "PreToolUse")

    # Sanity: the bare command is exactly what silently failed.
    assert {_, 1} =
             System.cmd("sh", ["-c", "python3 -c 1"],
               cd: project,
               env: [{"PATH", path}],
               stderr_to_stdout: true
             )

    input = Jason.encode!(%{"tool_name" => "Bash", "tool_input" => %{"command" => "make check"}})
    File.write!(Path.join(dir, "in.json"), input)

    {out, status} =
      System.cmd("sh", ["-c", "exec < \"$1\"; " <> pre, "--", Path.join(dir, "in.json")],
        cd: project,
        env: [{"PATH", path}, {"KOGEN_ROLE", "developer"}],
        stderr_to_stdout: true
      )

    # The script really ran (no mise error) and did not crash.
    refute out =~ "not trusted"
    assert status == 0

    # A crashing guard fails closed with exit 2 instead of a non-blocking exit 1.
    broken = String.replace(pre, "verification_policy.py", "missing_guard.py")

    assert {bout, 2} =
             System.cmd("sh", ["-c", broken],
               cd: project,
               env: [{"PATH", path}],
               stderr_to_stdout: true
             )

    assert bout =~ "hook failed"
  end

  test "the Stop hook's nested python3 resolves to the absolute interpreter, not the shim",
       %{dir: dir} do
    project = Path.join(dir, "project")
    path = Path.join(dir, "shim") <> ":" <> System.get_env("PATH", "")
    [stop] = commands(settings(), "Stop")

    File.write!(
      Path.join(project, ".codex/hooks/check.sh"),
      "#!/bin/sh\npython3 -c 'print(42)'\n"
    )

    assert {"42\n", 0} = System.cmd("sh", ["-c", stop], cd: project, env: [{"PATH", path}])
  end

  test "a missing or too-old interpreter is a clear error, not a silent fallback", %{dir: dir} do
    assert {:error, msg} = HookInterpreter.resolve(nil)
    assert msg =~ "no python3 found"

    old = Path.join(dir, "old-python")
    File.write!(old, "#!/bin/sh\nprintf '3 9\\n#{old}\\n'\n")
    File.chmod!(old, 0o755)
    assert {:error, msg} = HookInterpreter.resolve(old)
    assert msg =~ "requires Python 3.11 or newer"
  end
end
