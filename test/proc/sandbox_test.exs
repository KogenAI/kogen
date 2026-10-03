defmodule Kogen.Proc.SandboxTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Proc.Sandbox

  test "Seatbelt confines writes and denies credential access", %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    project = Path.join(tmp_dir, "project")
    origin = Path.join(tmp_dir, "origin.git")
    workspace = Path.join([home, ".kogen", "workspaces", "demo", "run-1"])
    run_dir = Path.join([home, ".kogen", "workspaces", "demo", "runs", "run-1"])
    credential = Path.join([home, ".codex", "auth.json"])
    kogen_credential = Path.join([home, ".kogen", "credentials-test.json"])

    for path <- [home, project, origin, workspace, run_dir, Path.dirname(credential)] do
      File.mkdir_p!(path)
    end

    File.write!(credential, "fake-token")
    File.write!(kogen_credential, "fake-kogen-token")

    sandbox = %Sandbox{
      enabled: true,
      home: home,
      project_root: project,
      origin: origin,
      workspace: workspace,
      run_dir: run_dir,
      tmp_dir: tmp_dir
    }

    env = %{
      "PATH" => "/usr/bin:/bin",
      "HOME" => home,
      "PROJECT_ROOT" => project,
      "ORIGIN_ROOT" => origin,
      "KOGEN_CREDENTIAL" => kogen_credential
    }

    assert {:ok, profile} = Sandbox.profile(sandbox)
    assert profile =~ "(allow file-write*"
    assert profile =~ ".codex"
    assert profile =~ "(deny file-write*"

    if :os.type() == {:unix, :darwin} do
      assert_sandbox_denies(
        ["/bin/sh", "-c", "printf escaped > \"$PROJECT_ROOT/outside.txt\""],
        workspace,
        env,
        sandbox
      )

      refute File.exists?(Path.join(project, "outside.txt"))

      assert_sandbox_denies(
        ["/bin/sh", "-c", "printf escaped > \"$ORIGIN_ROOT/outside.txt\""],
        workspace,
        env,
        sandbox
      )

      refute File.exists?(Path.join(origin, "outside.txt"))

      assert_sandbox_denies(["/bin/cat", credential], workspace, env, sandbox)
      assert_sandbox_denies(["/bin/cat", kogen_credential], workspace, env, sandbox)

      assert_sandbox_denies(
        ["/bin/sh", "-c", "printf escaped > \"$KOGEN_CREDENTIAL\""],
        workspace,
        env,
        sandbox
      )

      assert File.read!(kogen_credential) == "fake-kogen-token"

      assert {:ok, %ProcResult{exit_status: 0, timed_out: false}} =
               Proc.run(["/bin/sh", "-c", "printf allowed > workspace-write.txt"],
                 cd: workspace,
                 env: env,
                 sandbox: sandbox
               )

      assert File.read!(Path.join(workspace, "workspace-write.txt")) == "allowed"

      assert {:ok, %ProcResult{exit_status: 0, timed_out: false}} =
               Proc.run(["/bin/sh", "-c", "printf allowed > \"$RUN_DIR/run-output.log\""],
                 cd: workspace,
                 env: Map.put(env, "RUN_DIR", run_dir),
                 sandbox: sandbox
               )

      assert File.read!(Path.join(run_dir, "run-output.log")) == "allowed"
    else
      assert Sandbox.command(["/bin/true"], sandbox) == {:ok, ["/bin/true"]}
    end
  end

  defp assert_sandbox_denies(argv, workspace, env, sandbox) do
    assert {:ok, %ProcResult{exit_status: status, timed_out: false, output_tail: output}} =
             Proc.run(argv, cd: workspace, env: env, sandbox: sandbox)

    assert status != 0
    refute output =~ "fake-token"
  end
end
