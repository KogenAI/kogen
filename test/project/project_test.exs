defmodule Kogen.Project.ProjectTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project

  test "loads all declared project data and converts timeout strings", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks:
      - name: test
        argv: [mix, test]
        timeout_ms: 60000
    fix:
      - name: format
        argv: [mix, format, --force]
        timeout_ms: 12000
    setup:
      - name: assets
        argv: [npm, ci]
        timeout_ms: 120000
    diagnose:
      - glob: "lib/**/*.ex"
        argv: [mix, compile]
    protected_paths: [mix.exs, .kogen/project.yaml]
    domains:
      intent: [lib/kogen/intent, test/intent]
    """)

    assert {:ok, %Project{} = project} = Kogen.Project.load(root)
    assert project.root == root
    assert project.name == "tiny-app"
    assert project.checks == [%CheckSpec{name: "test", argv: ["mix", "test"], timeout_ms: 60_000}]

    assert project.setup == [
             %CheckSpec{name: "assets", argv: ["npm", "ci"], timeout_ms: 120_000}
           ]

    assert project.fix == [
             %CheckSpec{name: "format", argv: ["mix", "format", "--force"], timeout_ms: 12_000}
           ]

    assert project.diagnose == [%{glob: "lib/**/*.ex", argv: ["mix", "compile"]}]
    assert project.protected_paths == ["mix.exs", ".kogen/project.yaml"]
    assert project.domains == %{"intent" => ["lib/kogen/intent", "test/intent"]}
  end

  test "omitted optional collections are empty and checks is required", %{tmp_dir: root} do
    write_config(root, "name: tiny-app\nchecks: []\n")
    assert {:ok, project} = Kogen.Project.load(root)
    assert project.fix == []
    assert project.setup == []
    assert project.diagnose == []
    assert project.protected_paths == []
    assert project.domains == %{}

    write_config(root, "name: tiny-app\n")
    assert {:error, [%{message: message}]} = Kogen.Project.load(root)
    assert message =~ "missing required key `checks`"
  end

  test "reports a missing project file", %{tmp_dir: root} do
    assert {:error, [%{message: message}]} = Kogen.Project.load(root)
    assert message =~ ".kogen/project.yaml"
  end

  test "rejects unknown top-level and nested keys", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks:
      - name: test
        argv: [mix, test]
        timeout_ms: 1000
        shell: true
    extra: value
    """)

    assert {:error, errors} = Kogen.Project.load(root)
    messages = Enum.map(errors, & &1.message)
    assert Enum.any?(messages, &String.contains?(&1, "project has unknown key \"extra\""))
    assert Enum.any?(messages, &String.contains?(&1, "checks[1] has unknown key \"shell\""))
  end

  test "fix entries reject tier fields and require a complete CheckSpec", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks: []
    fix:
      - name: format
        argv: [mix, format]
        timeout_ms: 1000
        tier: safe
    """)

    assert {:error, [%{message: message}]} = Kogen.Project.load(root)
    assert message =~ "fix[1] has unknown key \"tier\""

    write_config(root, """
    name: tiny-app
    checks: []
    fix:
      - name: format
        argv: [mix, format]
    """)

    assert {:error, errors} = Kogen.Project.load(root)
    assert Enum.any?(errors, &(&1.message =~ "fix[1] is missing required key `timeout_ms`"))
  end

  test "setup entries use the CheckSpec format and reject unknown keys", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks: []
    setup:
      - name: assets
        argv: [npm, ci]
        timeout_ms: 1000
        shell: true
    """)

    assert {:error, [%{message: message}]} = Kogen.Project.load(root)
    assert message =~ "setup[1] has unknown key \"shell\""

    write_config(root, """
    name: tiny-app
    checks: []
    setup:
      - name: assets
        argv: []
        timeout_ms: 1000
    """)

    assert {:error, [%{message: message}]} = Kogen.Project.load(root)
    assert message =~ "setup[1].argv must not be empty"
  end

  test "validates argv, timeout, protected paths, diagnoses, and domain roots", %{tmp_dir: root} do
    write_config(root, """
    name: tiny-app
    checks:
      - name: test
        argv: []
        timeout_ms: zero
    protected_paths: ["", mix.exs]
    diagnose:
      - glob: ""
        argv: [mix]
    domains: intent
    """)

    assert {:error, errors} = Kogen.Project.load(root)
    messages = Enum.map(errors, & &1.message)
    assert Enum.any?(messages, &String.contains?(&1, "checks[1].argv must not be empty"))
    assert Enum.any?(messages, &String.contains?(&1, "timeout_ms must be a positive integer"))

    assert Enum.any?(
             messages,
             &String.contains?(&1, "protected_paths must contain only non-empty strings")
           )

    assert Enum.any?(
             messages,
             &String.contains?(&1, "diagnose[1].glob must be a non-empty string")
           )

    assert Enum.any?(messages, &String.contains?(&1, "`domains` must be a map"))
  end

  test "rejects non-map project roots and non-list checks", %{tmp_dir: root} do
    write_config(root, "[one, two]\n")
    assert {:error, [%{message: message}]} = Kogen.Project.load(root)
    assert message =~ "document root"

    write_config(root, "name: tiny-app\nchecks: test\n")
    assert {:error, [%{message: message}]} = Kogen.Project.load(root)
    assert message =~ "`checks` must be a list"
  end

  defp write_config(root, source) do
    config = Path.join([root, ".kogen", "project.yaml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, source)
  end
end
