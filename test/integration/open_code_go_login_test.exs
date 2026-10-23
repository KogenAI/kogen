Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.OpenCodeGoLoginTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Kogen.{Error, Lock, OpenCodeGo}
  @moduletag :integration
  @moduletag timeout: 300_000
  setup_all do
    suite = Kogen.Integration.Helpers.setup_suite!()
    on_exit(fn -> Kogen.Integration.Helpers.cleanup_suite(suite) end)
    %{suite: suite}
  end

  setup do
    home = Kogen.tmp_path("go-login")
    previous = :persistent_term.get(:kogen_caller, nil)
    :persistent_term.put(:kogen_caller, %{env: %{"HOME" => home}})

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(:kogen_caller, previous),
        else: :persistent_term.erase(:kogen_caller)

      File.rm_rf!(home)
    end)

    %{home: home, path: Path.join(home, ".kogen/credentials/opencode-go.json")}
  end

  defp supply(value),
    do: send(self(), {:proto, %{"type" => "secret_input", "value" => value, "ok" => true}})

  test "own input trims whitespace without requiring a vendor prefix; invalid and interrupted input preserve exact old bytes",
       c do
    supply("  arbitrary-key\t\r\n")
    text = capture_io(fn -> assert OpenCodeGo.login() == 0 end)
    assert text =~ "key saved (not verified)"
    refute text =~ "arbitrary-key"
    before = File.read!(c.path)
    assert JSON.decode!(before) == %{"provider" => "opencode-go", "api_key" => "arbitrary-key"}

    for input <- ["\n", "a\nb\n", "a\n\n", "a\0b", "a\tb", "a\u0085b", <<255>>] do
      supply(input)

      capture_io(fn ->
        e = assert_raise Error, fn -> OpenCodeGo.login() end
        assert e.reason == "login_failed"
        assert e.exit == 4
        refute Exception.message(e) =~ "arbitrary-key"
      end)

      assert File.read!(c.path) == before
    end

    for signal <- ~w(SIGINT SIGTERM SIGHUP) do
      send(self(), {:proto, %{"type" => "cancel", "signal" => signal}})
      capture_io(fn -> assert catch_throw(OpenCodeGo.login()) == {:cancel, signal} end)
      assert File.read!(c.path) == before
    end

    assert capture_io(fn -> OpenCodeGo.status() end) =~ "key saved (not verified)"
    File.write!(c.path, "malformed")
    assert capture_io(fn -> OpenCodeGo.status() end) =~ "saved login cannot be used"
  end

  test "failed atomic replacement leaves existing bytes and cleans temporary files", c do
    supply("old-key\n")
    capture_io(fn -> OpenCodeGo.login() end)
    before = File.read!(c.path)
    # A competing holder must not replace the old credential.
    lock = Path.rootname(c.path) <> ".lock"
    assert Lock.acquire(lock) == :ok
    supply("new-key\n")
    capture_io(fn -> assert_raise Error, fn -> OpenCodeGo.login() end end)
    assert File.read!(c.path) == before
    Lock.release(lock)
    # A real filesystem rename failure must not leak exception content or abandon a temp.
    File.rm!(c.path)
    File.mkdir!(c.path)
    File.write!(Path.join(c.path, "old"), before)
    supply("new-key\n")

    capture_io(fn ->
      e = assert_raise Error, fn -> OpenCodeGo.login() end
      assert e.detail == "could not save OpenCode Go key; saved login unchanged"
    end)

    assert File.read!(Path.join(c.path, "old")) == before
    assert File.ls!(Path.dirname(c.path)) == ["opencode-go.json"]
  end

  test "installed piped login rejects invalid UTF-8 instead of saving a replacement key", c do
    python = System.get_env("KOGEN_TEST_PYTHON_BIN") || "python3"

    script = ~S"""
    import os, subprocess, sys
    binary, home = sys.argv[1:]
    env = {**os.environ, 'HOME': home}
    path = os.path.join(home, '.kogen/credentials/opencode-go.json')
    command = [binary, 'provider', 'login', 'opencode-go']
    first = subprocess.run(command, input=b'SYNTHETIC_ORIGINAL_KEY\n', capture_output=True, env=env, timeout=15)
    assert first.returncode == 0, (first.stdout, first.stderr)
    before = open(path, 'rb').read()
    invalid = subprocess.run(command, input=b'SYNTHETIC_INVALID_\xff\n', capture_output=True, env=env, timeout=15)
    assert invalid.returncode == 4, (invalid.returncode, invalid.stdout, invalid.stderr)
    assert b'provider/login_failed' in invalid.stdout + invalid.stderr
    assert b'SYNTHETIC_INVALID_' not in invalid.stdout + invalid.stderr
    assert open(path, 'rb').read() == before
    print('invalid piped input preserved login')
    """

    {output, status} =
      System.cmd(python, ["-c", script, c.suite.release, c.home], stderr_to_stdout: true)

    assert status == 0, output
    assert output == "invalid piped input preserved login\n"
  end

  test "installed terminal input never echoes and restores state on success, error and each signal",
       c do
    python = System.get_env("KOGEN_TEST_PYTHON_BIN") || "python3"

    script = ~S"""
    import os, pty, signal, subprocess, sys, termios, time, select
    binary, home = sys.argv[1:]
    env = {**os.environ, 'HOME': home}
    path = os.path.join(home, '.kogen/credentials/opencode-go.json')
    for mode, expected in [('success',0),('empty',4),('SIGINT',130),('SIGTERM',143),('SIGHUP',129)]:
        master, slave = pty.openpty()
        before = termios.tcgetattr(slave)
        saved = open(path,'rb').read() if os.path.exists(path) else None
        p = subprocess.Popen([binary,'provider','login','opencode-go'], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            deadline = time.monotonic()+10
            while termios.tcgetattr(slave)[3] & termios.ECHO:
                assert p.poll() is None, 'login exited before private input'
                assert time.monotonic() < deadline, 'login never disabled echo'
                time.sleep(.01)
            if mode == 'success': os.write(master,b'SYNTHETIC_TERMINAL_KEY\n')
            elif mode == 'empty': os.write(master,b'\n')
            else: p.send_signal(getattr(signal,mode))
            out, err = p.communicate(timeout=15)
            assert p.returncode == expected, (mode,p.returncode,out,err)
            assert termios.tcgetattr(slave) == before, 'terminal was not restored'
            assert b'SYNTHETIC_TERMINAL_KEY' not in out+err
            if select.select([master],[],[],.05)[0]:
                assert b'SYNTHETIC_TERMINAL_KEY' not in os.read(master,4096), 'key was echoed'
            if mode != 'success': assert open(path,'rb').read() == saved
        finally:
            if p.poll() is None: p.kill(); p.wait()
            termios.tcsetattr(slave,termios.TCSANOW,before)
            os.close(master); os.close(slave)
    print('terminal custody passed')
    """

    {output, status} =
      System.cmd(python, ["-c", script, c.suite.release, c.home], stderr_to_stdout: true)

    assert status == 0, output
    assert output == "terminal custody passed\n"
  end
end
