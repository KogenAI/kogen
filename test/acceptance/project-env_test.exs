defmodule Kogen.Acceptance.ProjectEnvTest do
  use Kogen.Testkit.Case

  alias Kogen.Engine.Runtime

  @moduletag :acceptance

  @base_yaml """
  name: env-probe
  checks:
    - name: test
      argv: [mix, test]
      timeout_ms: 1000
  """

  @tag intent: "project-env/A1"
  test "loads the env map and defaults to an empty map", %{tmp_dir: tmp_dir} do
    with_env =
      write_project!(
        Path.join(tmp_dir, "with"),
        env_yaml(~s(  PGPORT: "55432"\n  APP_MODE: "test"))
      )

    assert {:ok, project} = Kogen.Project.load(with_env)
    assert project.env == %{"PGPORT" => "55432", "APP_MODE" => "test"}

    without_env = write_project!(Path.join(tmp_dir, "without"), @base_yaml)
    assert {:ok, project} = Kogen.Project.load(without_env)
    assert project.env == %{}
  end

  @tag intent: "project-env/A2"
  test "rejects invalid env names and non-string values", %{tmp_dir: tmp_dir} do
    bad_name = write_project!(Path.join(tmp_dir, "name"), env_yaml(~s(  1BAD-NAME: "x")))
    assert {:error, errors} = Kogen.Project.load(bad_name)
    assert Enum.any?(errors, &(&1.message =~ "1BAD-NAME"))

    bad_value = write_project!(Path.join(tmp_dir, "value"), env_yaml("  RETRIES: [1, 2]"))
    assert {:error, errors} = Kogen.Project.load(bad_value)
    assert Enum.any?(errors, &(&1.message =~ "RETRIES"))
  end

  @tag intent: "project-env/A3"
  test "adds project env to the toolchain env with project values winning", %{tmp_dir: tmp_dir} do
    workdir =
      write_project!(
        Path.join(tmp_dir, "work"),
        env_yaml(~s(  PGPORT: "55432"\n  SHARED: "from-project"))
      )

    mise = Path.join(tmp_dir, "mise")

    File.write!(mise, """
    #!/bin/sh
    printf '%s' '{"PATH":"/usr/bin:/bin","SHARED":"from-mise","TOOL_ONLY":"kept"}'
    """)

    File.chmod!(mise, 0o755)
    runtime = Runtime.new(%{"PATH" => "/usr/bin:/bin"}, mise, nil, "/runtime", "/runtime/bin")
    assert {:ok, project} = Kogen.Project.load(workdir)

    assert {:ok, env} = Kogen.Kernel.candidate_environment(workdir, runtime, project)
    assert env["PGPORT"] == "55432"
    assert env["SHARED"] == "from-project"
    assert env["TOOL_ONLY"] == "kept"
  end

  defp env_yaml(entries), do: @base_yaml <> "env:\n" <> entries <> "\n"

  defp write_project!(root, yaml) do
    File.mkdir_p!(Path.join(root, ".kogen"))
    File.write!(Path.join([root, ".kogen", "project.yaml"]), yaml)
    root
  end
end
