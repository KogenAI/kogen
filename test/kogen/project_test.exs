defmodule Kogen.ProjectTest do
  use ExUnit.Case, async: false

  alias Kogen.EngineResources
  alias Kogen.Project

  @source_root Path.expand("../..", __DIR__)

  @first_config """
  setup:
    argv: [mise, install]
    requires:
      - executable: git
      - path: README.md
  checks:
    - name: unit
      argv: [git, status, --short]
    - name: history
      argv: [git, log, "-1", "--format=%s"]
  """

  test "projects keep canonical identities and their own resolved check commands" do
    base = area!("identities")
    on_exit(fn -> File.rm_rf(base) end)
    engine = engine!(base, "engine")
    first_root = project!(base, "first project", @first_config)

    second_config = """
    checks:
      - name: source-root
        argv: [git, rev-parse, --show-toplevel]
    """

    second_root = project!(base, "second project", second_config)
    first_alias = Path.join(base, "first alias")
    :ok = File.ln_s(first_root, first_alias)

    assert {:ok, first} = Project.open(first_alias, engine)
    assert {:ok, second} = Project.open(second_root, engine)
    assert first.root == Kogen.ProjectScope.canonical(first_root)
    assert first.root == Kogen.ProjectScope.canonical(first_alias)
    assert first.id == sha256(first.root)
    assert second.id == sha256(second.root)
    refute first.id == second.id
    assert first.config_sha256 == sha256(File.read!(first.config_path))
    assert first.commands_sha256 =~ ~r/^[0-9a-f]{64}$/
    refute first.commands_sha256 == second.commands_sha256
    assert first.setup["argv"] == ["mise", "install"]
    assert first.setup["command"] == "mise install"

    assert first.setup["requires"] == [
             %{
               "kind" => "executable",
               "value" => "git",
               "resolved" => Kogen.ProjectScope.canonical(System.find_executable("git"))
             },
             %{
               "kind" => "path",
               "value" => "README.md",
               "resolved" => Path.join(first.root, "README.md")
             }
           ]

    assert length(first.checks) == 2

    assert first.checks == [
             %{"name" => "unit", "argv" => [System.find_executable("git"), "status", "--short"]},
             %{
               "name" => "history",
               "argv" => [System.find_executable("git"), "log", "-1", "--format=%s"]
             }
           ]

    assert second.checks == [
             %{
               "name" => "source-root",
               "argv" => [System.find_executable("git"), "rev-parse", "--show-toplevel"]
             }
           ]

    assert Project.check_ready(first, :build) == :ok
  end

  test "Git discovery ignores ambient repository overrides" do
    base = area!("ambient git")
    on_exit(fn -> File.rm_rf(base) end)
    engine = engine!(base, "engine")
    selected = project!(base, "selected", @first_config)
    decoy = project!(base, "decoy", @first_config)
    plain = Path.join(base, "plain directory")
    File.mkdir_p!(plain)

    original = %{
      "GIT_DIR" => System.get_env("GIT_DIR"),
      "GIT_WORK_TREE" => System.get_env("GIT_WORK_TREE")
    }

    on_exit(fn -> Enum.each(original, &restore_env/1) end)
    System.put_env("GIT_DIR", Path.join(decoy, ".git"))
    System.put_env("GIT_WORK_TREE", decoy)

    assert {:ok, project} = Project.open(selected, engine)
    assert project.root == Kogen.ProjectScope.canonical(selected)
    assert project.id == sha256(project.root)
    assert {:error, reason} = Project.open(plain, engine)
    assert reason =~ "not a Git checkout"
  end

  test "missing prerequisites report the exact setup argv without running it" do
    base = area!("missing prerequisite")
    on_exit(fn -> File.rm_rf(base) end)
    engine = engine!(base, "engine")
    root = Path.join(base, "project")
    marker = Path.join(root, "setup-ran")
    setup_script = Path.join(root, "setup.sh")

    config = """
    setup:
      argv: [./setup.sh, "install now"]
      requires:
        - executable: kogen-definitely-missing-prerequisite-84291
    checks:
      - name: test
        argv: [git, status]
    """

    File.mkdir_p!(root)
    File.write!(setup_script, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(setup_script, 0o755)
    git_project!(root, config)

    assert {:error, reason} = Project.open(root, engine)
    assert reason =~ "kogen-definitely-missing-prerequisite-84291"
    assert reason =~ "setup command: ./setup.sh 'install now'"
    refute File.exists?(marker)
  end

  test "configuration rejects shell command fields and relative prerequisite escape" do
    base = area!("configuration safety")
    on_exit(fn -> File.rm_rf(base) end)
    engine = engine!(base, "engine")

    shell_config = """
    checks:
      - name: unit
        command: "make test"
    """

    shell_root = project!(base, "shell project", shell_config)
    assert {:error, shell_reason} = Project.open(shell_root, engine)
    assert shell_reason =~ "unsupported keys: command"

    escape_config = """
    setup:
      argv: [mise, install]
      requires:
        - path: ../outside-marker
    checks:
      - name: unit
        argv: [git, status]
    """

    escape_root = project!(base, "escape project", escape_config)
    File.write!(Path.join(base, "outside-marker"), "outside\n")
    assert {:error, escape_reason} = Project.open(escape_root, engine)
    assert escape_reason =~ "relative setup path escapes the project"

    check_escape_root =
      project!(
        base,
        "check escape project",
        "checks:\n  - name: outside\n    argv: [../outside-marker]\n"
      )

    assert {:error, check_escape_reason} = Project.open(check_escape_root, engine)
    assert check_escape_reason =~ "relative executable path escapes the project"
  end

  test "Build admission preserves attached branches and refuses linked worktrees" do
    base = area!("readiness")
    on_exit(fn -> File.rm_rf(base) end)
    engine = engine!(base, "engine")
    root = project!(base, "ready project", @first_config)
    assert {:ok, project} = Project.open(root, engine)
    assert Project.check_ready(project, :build) == :ok

    File.write!(Path.join(root, "README.md"), "modified\n")
    assert Project.check_ready(project, :shape) == :ok
    assert {:error, dirty} = Project.check_ready(project, :build)
    assert dirty =~ "clean project checkout"

    git!(root, ["checkout", "--", "README.md"])
    git!(root, ["checkout", "-b", "feature/shape"])
    assert Project.check_ready(project, :shape) == :ok
    assert Project.check_ready(project, :build) == :ok

    linked = Path.join(base, "linked project")
    git!(root, ["worktree", "add", "-b", "linked", linked])
    assert {:ok, linked_project} = Project.open(linked, engine)
    assert Project.check_ready(linked_project, :shape) == :ok
    assert {:error, worktree} = Project.check_ready(linked_project, :build)
    assert worktree =~ "not a linked worktree"
    git!(root, ["worktree", "remove", linked])

    git!(root, ["checkout", "--detach"])
    assert {:error, branch} = Project.check_ready(project, :build)
    assert branch =~ "HEAD is detached"

    unborn_root = Path.join(base, "unborn project")
    File.mkdir_p!(unborn_root)
    File.write!(Path.join(unborn_root, "README.md"), "fixture\n")
    write_project_config!(unborn_root, @first_config)
    git!(unborn_root, ["init", "--quiet", "-b", "main"])
    assert {:ok, unborn} = Project.open(unborn_root, engine)
    assert Project.check_ready(unborn, :shape) == :ok
    assert {:error, head} = Project.check_ready(unborn, :build)
    assert head =~ "committed HEAD"
  end

  test "same-root self-development is explicit in the opened project" do
    base = area!("self project")
    on_exit(fn -> File.rm_rf(base) end)
    root = engine!(base, "engine")
    File.write!(Path.join(root, "README.md"), "self fixture\n")
    write_project_config!(root, @first_config)
    git!(root, ["init", "--quiet", "-b", "main"])
    git!(root, ["add", "-A"])

    git!(root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    assert {:ok, project} = Project.open(root, root)
    assert project.self_project?
    assert project.root == project.engine_root
  end

  test "engine resources resolve from the application or supplied engine, never the target" do
    base = area!("engine resources")
    on_exit(fn -> File.rm_rf(base) end)
    engine = engine!(base, "custom engine")
    target = Path.join(base, "target")
    engine_file = Path.join([engine, "priv/kogen/prompts", "developer.md"])
    target_file = Path.join([target, "priv/kogen/prompts", "developer.md"])
    File.mkdir_p!(Path.dirname(engine_file))
    File.mkdir_p!(Path.dirname(target_file))
    File.write!(engine_file, "engine prompt\n")
    File.write!(target_file, "target prompt\n")

    assert {:ok, resolved_engine_file} =
             EngineResources.path("priv/kogen/prompts/developer.md", engine)

    assert resolved_engine_file == Kogen.ProjectScope.canonical(engine_file)
    assert File.read!(resolved_engine_file) == "engine prompt\n"

    assert {:error, escaped} =
             EngineResources.path("../target/priv/kogen/prompts/developer.md", engine)

    assert escaped =~ "escapes its checkout"

    File.cd!(target, fn ->
      assert EngineResources.root() == Kogen.ProjectScope.canonical(@source_root)
      assert {:ok, source_mix} = EngineResources.path("mix.exs")
      assert source_mix == Path.join(@source_root, "mix.exs")
    end)
  end

  defp area!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-project-test-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp engine!(base, name) do
    root = Path.join(base, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "mix.exs"), "defmodule Fixture.MixProject do end\n")
    root
  end

  defp project!(base, name, config) do
    root = Path.join(base, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "fixture\n")
    git_project!(root, config)
    root
  end

  defp git_project!(root, config) do
    write_project_config!(root, config)
    git!(root, ["init", "--quiet", "-b", "main"])
    git!(root, ["add", "-A"])

    git!(root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    root
  end

  defp write_project_config!(root, config) do
    config_path = Path.join(root, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, config)
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", ["-C", root] ++ args, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    output
  end

  defp restore_env({key, nil}), do: System.delete_env(key)
  defp restore_env({key, value}), do: System.put_env(key, value)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
