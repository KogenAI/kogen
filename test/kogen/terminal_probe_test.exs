defmodule Kogen.TerminalProbeTest do
  use ExUnit.Case, async: true

  @probe Path.expand("../support/terminal_probe.py", __DIR__)

  test "readiness separates delayed startup from completion in pipe and pty modes" do
    for mode <- ["pipe", "pty"] do
      marker = fresh_marker()

      on_exit(fn -> File.rm(marker) end)

      assert {"", 0} =
               run(
                 mode,
                 marker,
                 "import os,time; time.sleep(.1); open(os.environ['KOGEN_READY_MARKER'],'w').close()"
               )

      assert File.exists?(marker)
    end
  end

  test "readiness reports early failure and missing marker distinctly" do
    early = run("pipe", fresh_marker(), "import sys; sys.exit(7)")
    assert {message, 1} = early
    assert message =~ "exited before readiness (status 7)"

    missing =
      run("pipe", fresh_marker(), "import time; time.sleep(1)", ["--startup-timeout", "0.1"])

    assert {message, 1} = missing
    assert message =~ "startup deadline"
  end

  test "a stale readiness marker is rejected and preserved" do
    marker = fresh_marker()
    File.write!(marker, "foreign\n")

    assert {message, 1} = run("pipe", marker, "import sys; sys.exit(0)")
    assert message =~ "readiness marker already exists"
    assert File.read!(marker) == "foreign\n"
    File.rm!(marker)
  end

  test "an EOF-waiting child fails after readiness while stdin stays open" do
    marker = fresh_marker()

    {message, status} =
      run(
        "pipe",
        marker,
        "import os,sys; open(os.environ['KOGEN_READY_MARKER'],'w').close(); sys.stdin.read()",
        ["--timeout", "0.1"]
      )

    assert status == 1
    assert message =~ "did not complete after readiness deadline"
  end

  test "owned background processes are gone after success and failure" do
    for {name, suffix} <- [{"success", ""}, {"failure", "; raise RuntimeError('after ready')"}] do
      marker = fresh_marker()
      pid_path = marker <> ".pid"

      code =
        "import os,subprocess,time; " <>
          "p=subprocess.Popen(['sleep','60']); " <>
          "open(os.environ['PROBE_DESCENDANT_PID'],'w').write(str(p.pid)); " <>
          "open(os.environ['KOGEN_READY_MARKER'],'w').close(); time.sleep(.2)" <> suffix

      {_message, status} =
        System.cmd(
          "python3",
          [
            @probe,
            "--mode",
            "pipe",
            "--ready-marker",
            marker,
            "--owned-pid-file",
            pid_path,
            "--",
            "python3",
            "-c",
            code
          ],
          env: [{"PROBE_DESCENDANT_PID", pid_path}],
          stderr_to_stdout: true
        )

      if name == "success", do: assert(status == 0), else: assert(status == 1)
      pid = pid_path |> File.read!() |> String.trim()
      assert {_, kill_status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      assert kill_status != 0, "#{name} descendant #{pid} survived terminal probe cleanup"
      File.rm(marker)
      File.rm(pid_path)
    end
  end

  defp fresh_marker do
    Path.join(
      System.tmp_dir!(),
      "kogen-terminal-ready-#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    )
  end

  defp run(mode, marker, code, extra \\ []) do
    System.cmd(
      "python3",
      [@probe, "--mode", mode, "--startup-timeout", "1", "--ready-marker", marker] ++
        extra ++ ["--", "python3", "-c", code],
      stderr_to_stdout: true
    )
  end
end
