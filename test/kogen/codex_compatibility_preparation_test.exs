defmodule Kogen.Codex.CompatibilityPreparationTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Codex.Compatibility

  test "compatibility fixture preparation seeds discovery without model work" do
    root = Path.join(System.tmp_dir!(), "compatibility-preparation-#{System.pid()}")
    System.put_env("KOGEN_CODEX_ROOT", root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, config} = Kogen.Intent.read_config()

    assert {:ok, fixture, _evidence, discovery} =
             Compatibility.prepare_fixture(File.cwd!(), config)

    assert File.regular?(Path.join(fixture, ".agents/skills/project-context/SKILL.md"))
    assert File.dir?(discovery["home"])
  end

  test "PTY trust response is limited to the explicitly selected compatibility fixture" do
    root = temporary_root("pty-trust")
    on_exit(fn -> File.rm_rf!(root) end)

    program =
      "import sys, termios, time; print('1. Yes, continue\\nPress enter to continue', flush=True); time.sleep(.2); termios.tcflush(0, termios.TCIFLUSH); sys.stdin.readline(); print('TRUST_MARKER', flush=True)"

    for {selected, expected} <- [{root, true}, {root <> "-other", false}, {nil, false}] do
      receipt = Path.join(root, "receipt-#{System.unique_integer([:positive])}.json")

      {_, status} =
        System.cmd(python(), [pty_driver(), python(), receipt, "TRUST_MARKER", "-c", program],
          cd: root,
          env: [
            {"KOGEN_COMPATIBILITY_TRUST_FIXTURE", selected},
            {"KOGEN_PROJECT_ROOT", root},
            {"KOGEN_PTY_EXECUTION_TIMEOUT", if(expected, do: "4", else: "1")},
            {"KOGEN_PTY_CLEANUP_TIMEOUT", "1"}
          ],
          stderr_to_stdout: true
        )

      result = receipt!(receipt)
      assert result["trust_answered"] == expected
      assert result["marker"] == expected
      assert result["cleanup"]["ok"]
      assert status == if(expected, do: 0, else: 1)
    end
  end

  test "PTY driver records a natural marker exit and verified cleanup" do
    root = temporary_root("pty-natural")
    on_exit(fn -> File.rm_rf!(root) end)

    for attempt <- 1..5 do
      attempt_receipt = Path.join(root, "receipt-#{attempt}.json")

      {_, status} =
        System.cmd(
          python(),
          [
            pty_driver(),
            python(),
            attempt_receipt,
            "PTY_MARKER",
            "-c",
            "print('PTY_MARKER', flush=True)"
          ],
          stderr_to_stdout: true
        )

      assert status == 0

      assert %{
               "marker" => true,
               "native_exit" => native_exit,
               "cleanup" => %{"ok" => true, "attempts" => attempts}
             } =
               receipt!(attempt_receipt)

      assert native_exit in [0, -2]
      assert is_list(attempts)
    end
  end

  test "PTY driver fails without a marker while still writing bounded cleanup evidence" do
    root = temporary_root("pty-no-marker")
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join(root, "receipt.json")

    {_, status} =
      System.cmd(
        python(),
        [pty_driver(), python(), receipt, "PTY_MARKER", "-c", "print('other', flush=True)"],
        stderr_to_stdout: true
      )

    assert status == 1
    assert %{"marker" => false, "cleanup" => %{"ok" => true}} = receipt!(receipt)
  end

  test "PTY driver reports a receipt persistence failure as failure after cleanup" do
    root = temporary_root("pty-unwritable")
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join([root, "missing", "receipt.json"])

    {output, status} =
      System.cmd(
        python(),
        [pty_driver(), python(), receipt, "PTY_MARKER", "-c", "print('PTY_MARKER', flush=True)"],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "receipt write failed"
  end

  test "PTY startup failure exits its child safely and still leaves a cleanup receipt" do
    root = temporary_root("pty-startup")
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join(root, "receipt.json")

    {_, status} =
      System.cmd(
        python(),
        [pty_driver(), "/definitely/not/a/kogen-executable", receipt, "PTY_MARKER"],
        stderr_to_stdout: true
      )

    assert status == 1

    assert %{"marker" => false, "native_exit" => 127, "cleanup" => %{"ok" => true}} =
             receipt!(receipt)
  end

  test "PTY signal fallback records group permission denial and total signal denial" do
    source = """
    import importlib.util, json, os, signal, sys
    spec = importlib.util.spec_from_file_location('driver', sys.argv[1])
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    attempts = []
    driver.wait_nonblocking = lambda _: ('running', None)
    driver.os.killpg = lambda *_: (_ for _ in ()).throw(PermissionError('group denied'))
    driver.os.kill = lambda *_: None
    driver.signal_owned(os.getpid(), signal.SIGTERM, attempts)
    group_fallback = attempts[:]
    attempts = []
    driver.os.kill = lambda *_: (_ for _ in ()).throw(PermissionError('child denied'))
    driver.signal_owned(os.getpid(), signal.SIGKILL, attempts)
    print(json.dumps({'fallback': group_fallback, 'denied': attempts}))
    """

    {output, 0} = System.cmd(python(), ["-c", source, pty_driver()], stderr_to_stdout: true)
    %{"fallback" => fallback, "denied" => denied} = Jason.decode!(output)

    assert Enum.any?(fallback, &(&1["target"] == "group" and &1["outcome"] == "failed"))
    assert Enum.any?(fallback, &(&1["target"] == "child" and &1["outcome"] == "sent"))
    assert Enum.any?(denied, &(&1["target"] == "group" and &1["outcome"] == "failed"))
    assert Enum.any?(denied, &(&1["target"] == "child" and &1["outcome"] == "failed"))
  end

  test "PTY driver bounds a quiet child that ignores terminal and group termination" do
    root = temporary_root("pty-ignore")
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join(root, "receipt.json")

    program =
      "import signal, time; signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"

    {_, status} =
      System.cmd(python(), [pty_driver(), python(), receipt, "PTY_MARKER", "-c", program],
        stderr_to_stdout: true,
        env: [{"KOGEN_PTY_EXECUTION_TIMEOUT", "0.2"}, {"KOGEN_PTY_CLEANUP_TIMEOUT", "3"}]
      )

    assert status == 1

    assert %{
             "marker" => false,
             "timed_out" => true,
             "cleanup" => %{"ok" => true, "attempts" => attempts}
           } = receipt!(receipt)

    assert Enum.any?(attempts, &(&1["signal"] == "SIGKILL" and &1["target"] == "group"))
  end

  test "PTY cleanup drains and hangs up a flooding child without waiting for timeout" do
    root = temporary_root("pty-flood")
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join(root, "receipt.json")

    program =
      "import sys\nchunk='x'*65536\nwhile True:\n sys.stdout.write(chunk)\n sys.stdout.flush()"

    started = System.monotonic_time(:millisecond)

    {_, status} =
      System.cmd(
        python(),
        [pty_driver(), python(), receipt, "PTY_MARKER", "-c", program],
        stderr_to_stdout: true,
        env: [
          {"KOGEN_PTY_EXECUTION_TIMEOUT", "0.2"},
          {"KOGEN_PTY_CLEANUP_TIMEOUT", "5"}
        ]
      )

    elapsed = System.monotonic_time(:millisecond) - started
    assert status == 1
    assert elapsed < 3_000
    assert %{"timed_out" => true, "cleanup" => %{"ok" => true}} = receipt!(receipt)
  end

  test "bounded wrapper kills an ignored turn and its descendant within its own process group" do
    root = temporary_root("bounded-descendant")
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join(root, "receipt.json")

    program =
      "import signal, subprocess, sys, time; " <>
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); " <>
        "subprocess.Popen([sys.executable, '-c', \"import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)\"]); " <>
        "time.sleep(30)"

    {_, status} =
      System.cmd(python(), [bounded_exec(), python(), "-c", program],
        stderr_to_stdout: true,
        env: [
          {"KOGEN_BOUNDED_EXEC_RECEIPT", receipt},
          {"KOGEN_BOUNDED_EXEC_TIMEOUT", "0.2"},
          {"KOGEN_BOUNDED_EXEC_CLEANUP_TIMEOUT", "3"}
        ]
      )

    assert status == 124

    assert %{"timed_out" => true, "cleanup" => %{"ok" => true, "attempts" => attempts}} =
             receipt!(receipt)

    assert Enum.any?(attempts, &(&1["signal"] == "SIGKILL" and &1["target"] == "group"))
  end

  test "bounded wrapper performs owned cleanup when it receives SIGTERM" do
    root = temporary_root("bounded-cancel")
    on_exit(fn -> File.rm_rf!(root) end)
    receipt = Path.join(root, "receipt.json")

    source = """
    import json, os, signal, subprocess, sys, time
    env = os.environ.copy()
    env.update({'KOGEN_BOUNDED_EXEC_RECEIPT': sys.argv[2], 'KOGEN_BOUNDED_EXEC_TIMEOUT': '30', 'KOGEN_BOUNDED_EXEC_CLEANUP_TIMEOUT': '3'})
    command = [sys.executable, sys.argv[1], sys.executable, '-c', 'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)']
    child = subprocess.Popen(command, env=env)
    time.sleep(.2)
    os.kill(child.pid, signal.SIGTERM)
    print(json.dumps({'status': child.wait(), 'receipt': json.load(open(sys.argv[2]))}))
    """

    {output, 0} =
      System.cmd(python(), ["-c", source, bounded_exec(), receipt], stderr_to_stdout: true)

    %{"status" => 143, "receipt" => %{"cancelled" => true, "cleanup" => %{"ok" => true}}} =
      Jason.decode!(output)
  end

  defp receipt!(path), do: path |> File.read!() |> Jason.decode!()
  defp pty_driver, do: Application.app_dir(:kogen, "priv/kogen/codex/compatibility/pty_driver.py")

  defp bounded_exec,
    do: Application.app_dir(:kogen, "priv/kogen/codex/compatibility/bounded_exec.py")

  defp python, do: System.find_executable("python3") || raise("python3 unavailable")

  defp temporary_root(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "#{label}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end
end
