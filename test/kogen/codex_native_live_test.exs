defmodule Kogen.Codex.NativeLiveTest do
  use Kogen.IsolatedCase, async: true
  alias Kogen.Codex.{Environment, State}
  @moduletag :live
  @moduletag timeout: 1_200_000

  test "official initial distribution executes after promotion without personal Codex or Node" do
    root = Path.join(System.tmp_dir!(), "kogen-native-install-#{System.pid()}")
    System.put_env("KOGEN_CODEX_ROOT", root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, runtime} = Kogen.Codex.installer("install")
    assert runtime["version"] == "0.154.0"
    assert {:ok, ^runtime} = Kogen.Codex.installer("install")
    native_home = Path.join(root, "no-personal-home")
    File.mkdir_p!(native_home)
    native_env = ["-i", "HOME=#{native_home}", "CODEX_HOME=#{native_home}", "PATH=/usr/bin:/bin"]
    {version, 0} = System.cmd("/usr/bin/env", native_env ++ [runtime["executable"], "--version"])
    assert version =~ "0.154.0"

    {help, 0} =
      System.cmd("/usr/bin/env", native_env ++ [runtime["executable"], "login", "--help"])

    assert help =~ "login"
    refute File.exists?(Path.join(native_home, "auth.json"))
  end

  test "real native login help and synthetic stdin use separate Kogen stores" do
    assert {:ok, runtime} = Kogen.Codex.installed()
    {:ok, config} = Kogen.Intent.read_config()
    root = Path.join(System.tmp_dir!(), "kogen-native-auth-#{System.pid()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for name <- [:shared, :project] do
      scope = %{path: Path.join(root, to_string(name)), name: name}
      State.ensure_scope!(scope.path)
      operation = State.operation!(root)
      context = Environment.prepare(runtime, scope, config, File.cwd!(), operation)

      {help, 0} =
        System.cmd(context.executable, context.args ++ ["login", "--help"], env: context.env)

      assert help =~ "login"
      # Native's synthetic API-key input exercises native persistence, never a
      # provider request or OAuth refresh. Kogen does not interpret the value.
      script =
        "import subprocess,sys; p=subprocess.run(sys.argv[1:], input=b'synthetic-kogen-fixture-key\\n', stdout=subprocess.PIPE, stderr=subprocess.PIPE); sys.exit(p.returncode)"

      assert {"", 0} =
               System.cmd(
                 "python3",
                 ["-c", script, context.executable | context.args ++ ["login", "--with-api-key"]],
                 env: context.env
               )

      assert File.regular?(Path.join(scope.path, "auth.json"))
    end

    shared = Path.join([root, "shared", "auth.json"])
    retained = File.read!(shared)
    File.rm!(Path.join([root, "project", "auth.json"]))
    assert File.read!(shared) == retained
  end
end
