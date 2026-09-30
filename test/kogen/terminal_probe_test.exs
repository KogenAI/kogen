defmodule Kogen.TerminalProbeTest do
  use ExUnit.Case, async: true

  # Subprocesses run from this checkout, never the shared VM's mutable cwd.
  @project_root Path.expand("../..", __DIR__)

  @probe Path.expand("../support/terminal_probe.py", __DIR__)

  test "readiness separates delayed startup from completion in pipe and pty modes" do
    for mode <- ["pipe", "pty"] do
      marker = fresh_marker()

      on_exit(fn -> File.rm(marker) end)

      {message, status} =
        run(
          mode,
          marker,
          "import os,threading; threading.Event().wait(.1); open(os.environ['KOGEN_READY_MARKER'],'w').close()"
        )

      assert status == 0, message

      assert File.exists?(marker)
    end
  end

  test "readiness reports early failure and missing marker distinctly" do
    early = run("pipe", fresh_marker(), "import sys; sys.exit(7)")
    assert {message, 1} = early
    assert message =~ "exited before readiness (status 7)"

    missing =
      run("pipe", fresh_marker(), "import threading; threading.Event().wait(1)", [
        "--startup-timeout",
        "0.1"
      ])

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
        "import os,subprocess,threading; " <>
          "p=subprocess.Popen(['sleep','60']); " <>
          "open(os.environ['PROBE_DESCENDANT_PID'],'w').write(str(p.pid)); " <>
          "open(os.environ['KOGEN_READY_MARKER'],'w').close(); threading.Event().wait(.2)" <>
          suffix

      {message, status} =
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
          stderr_to_stdout: true,
          cd: @project_root
        )

      if name == "success", do: assert(status == 0, message), else: assert(status == 1, message)
      pid = pid_path |> File.read!() |> String.trim()
      assert {_, kill_status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
      assert kill_status != 0, "#{name} descendant #{pid} survived terminal probe cleanup"
      File.rm(marker)
      File.rm(pid_path)
    end
  end

  test "signal delivery to an exiting or zombie-only group is tolerated, anything else is not" do
    program = ~S'''
    import signal, sys
    sys.path.insert(0, sys.argv[1])
    import terminal_probe as probe

    def raising(error):
        def send(target, sig):
            raise error
        return send

    for tolerated in (ProcessLookupError, PermissionError):
        probe.signal_tolerating_reap(raising(tolerated()), 1, signal.SIGKILL)
    delivered = []
    probe.signal_tolerating_reap(lambda target, sig: delivered.append((target, sig)), 7, signal.SIGTERM)
    assert delivered == [(7, signal.SIGTERM)], delivered
    try:
        probe.signal_tolerating_reap(raising(OSError("other")), 1, signal.SIGKILL)
    except OSError:
        print("unrelated-error-propagated")
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, Path.dirname(@probe)],
        stderr_to_stdout: true,
        cd: @project_root
      )

    assert output =~ "unrelated-error-propagated"
  end

  test "a screen model finds text drawn at absolute cursor positions between unrelated redraws" do
    driver = Path.expand("../../priv/kogen/codex/compatibility/pty_driver.py", __DIR__)

    # Condition-based and deterministic: no PTY, no sleeps. Fragments of the
    # answer are painted at absolute positions with status-line and title
    # redraws between them, exactly the interleaving that defeated searching
    # the escape-stripped byte stream. Bytes are fed in awkward chunks so a
    # split escape sequence is also exercised.
    program = ~S'''
    import importlib.util, re, sys
    spec = importlib.util.spec_from_file_location("pty_driver", sys.argv[1])
    driver = importlib.util.module_from_spec(spec); spec.loader.exec_module(driver)
    stream = (b"\x1b[2J\x1b[3;1HANS" b"\x1b]0;codex title\x07" b"\x1b[24;1Hstatus line redraw"
              b"\x1b[3;4HWER_" b"\x1b[24;1H\x1b[2Kworking" b"\x1b[3;8HK7\x1b[1;1H")
    screen = driver.Screen()
    for start in range(0, len(stream), 5):
        screen.feed(stream[start:start + 5])
    stripped = re.sub(rb"\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07]*\x07)", b"", stream).decode()
    print("screen=" + str(screen.contains("ANSWER_K7")))
    print("stripped=" + str("ANSWER_K7" in stripped))
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, driver],
        stderr_to_stdout: true,
        cd: @project_root
      )

    assert output =~ "screen=True"
    assert output =~ "stripped=False"
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
      stderr_to_stdout: true,
      cd: @project_root
    )
  end
end
