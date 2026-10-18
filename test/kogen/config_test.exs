defmodule Kogen.ConfigTest do
  use ExUnit.Case, async: true

  alias Kogen.{Config, Error}

  test "SET-8: generated settings use block collections and preserve long command values" do
    input = %{
      setup: ["mix deps.get", "npm ci --no-audit --no-fund"],
      fix: ["mix format"],
      checks: [
        %{
          name: "format",
          run: "mix format --check-formatted && npx prettier --check '**/*.{js,css,json,yaml}'"
        },
        %{name: "test", run: "mix test && printf '%s\\n' 'checks passed'"}
      ],
      protect: [
        ".formatter.exs",
        "config/checks/very-long-path-to-project-formatting-configuration.yaml"
      ],
      acceptance: %{
        run:
          ~s(node "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --format message:"$KOGEN_ACCEPTANCE_REPORT"),
        steps_dir: "features/steps"
      }
    }

    text = Config.render(input)
    assert text =~ "  checks:\n    - name: format\n      run:"
    assert text =~ "protect:\n  - '.formatter.exs'\n"
    assert text =~ "models:\n  shape:\n    model: gpt-6.1-sol\n    effort: high\n"

    long_model = "gpt-6.1-sol-with-a-long-explicit-model-identifier-for-formatting-regression"
    text = String.replace(text, "gpt-6.1-sol", long_model)
    config = Config.parse!(text, "/project/.kogen/project.yaml")
    assert config.setup == input.setup
    assert config.fix == input.fix
    assert config.checks == Enum.map(input.checks, &{&1.name, &1.run})
    assert config.protect == input.protect
    assert config.acceptance_run == input.acceptance.run
    assert config.steps_dir == input.acceptance.steps_dir

    for role <- ["shape", "plan", "review"] do
      assert config.models[role] == %{model: long_model, effort: "high"}
    end

    assert config.models["build"] == Config.default_models()["build"]
  end

  test "SET-8: empty generated settings retain the template's nulls and empty lists" do
    text = Config.render(%{setup: [], fix: [], checks: [], protect: [], acceptance: nil})
    assert Config.parse!(text, "generated") == Config.parse!(Config.template(), "template")
  end

  test "SET-8: commands, checks, acceptance, protect, and model defaults are interpreted" do
    config =
      Config.parse!(
        """
        version: 1
        commands:
          setup: [mix deps.get, npm ci]
          fix: [mix format]
          checks: [{name: test, run: mix test}, {name: lint, run: mix credo}]
          acceptance: {run: "npx cucumber --format message:$KOGEN_ACCEPTANCE_REPORT", steps_dir: features/steps/}
        protect: [".credo.exs", "config/**/*.yaml"]
        models:
          build: {model: gpt-6-luna, effort: high}
        """,
        "/project/.kogen/project.yaml"
      )

    assert config.setup == ["mix deps.get", "npm ci"]
    assert config.fix == ["mix format"]
    assert config.checks == [{"test", "mix test"}, {"lint", "mix credo"}]
    assert config.acceptance_run == "npx cucumber --format message:$KOGEN_ACCEPTANCE_REPORT"
    assert config.steps_dir == "features/steps"
    assert config.protect == [".credo.exs", "config/**/*.yaml"]

    assert config.models == %{
             "shape" => %{model: "gpt-6.1-sol", effort: "high"},
             "plan" => %{model: "gpt-6.1-sol", effort: "high"},
             "build" => %{model: "gpt-6-luna", effort: "high"},
             "review" => %{model: "gpt-6.1-sol", effort: "high"}
           }

    assert Config.named_commands(config) == [
             {"setup-1", "mix deps.get"},
             {"setup-2", "npm ci"},
             {"fix-1", "mix format"},
             {"test", "mix test"},
             {"lint", "mix credo"},
             {"acceptance", "npx cucumber --format message:$KOGEN_ACCEPTANCE_REPORT"}
           ]
  end

  test "SET-8: a plain command scalar keeps its comma and shell arguments" do
    config =
      Config.parse!(
        """
        version: 1
        commands:
          checks:
            - name: test
              run: python3 -c "print(1, 2)"
        """,
        "/project/.kogen/project.yaml"
      )

    assert config.checks == [{"test", "python3 -c \"print(1, 2)\""}]
  end

  test "SET-8: acceptance run and steps_dir may remain null until configured" do
    config =
      Config.parse!(
        "version: 1\ncommands:\n  acceptance:\n    run: null\n    steps_dir: null\n",
        "/project/.kogen/project.yaml"
      )

    assert config.acceptance_run == nil
    assert config.steps_dir == nil
    refute {"acceptance", nil} in Config.named_commands(config)
  end

  test "SET-4 / SET-8: invalid configuration errors name the file and each source line" do
    cases = [
      {"root unknown key", "version: 1\nlimits: 3\n", 2, "unknown key limits"},
      {"nested unknown key",
       "version: 1\ncommands:\n  checks:\n    - name: test\n      runn: mix test\n", 5,
       "unknown key runn"},
      {"duplicate key", "version: 1\ncommands:\n  acceptance:\n    run: first\n    run: second\n",
       5, "duplicate key run"},
      {"acceptance run boolean", "version: 1\ncommands:\n  acceptance:\n    run: true\n", 4,
       "commands.acceptance.run must be a string or null"},
      {"check run boolean",
       "version: 1\ncommands:\n  checks:\n    - name: test\n      run: true\n", 4,
       "a check needs a name and a run string"},
      {"checks null", "version: 1\ncommands:\n  checks: null\n", 3,
       "commands.checks must be a list"},
      {"setup null", "version: 1\ncommands:\n  setup: null\n", 3,
       "commands.setup must be a list"},
      {"protect null", "version: 1\nprotect: null\n", 2, "protect must be a list"},
      {"duplicate check name",
       "version: 1\ncommands:\n  checks:\n    - name: test\n      run: one\n    - name: test\n      run: two\n",
       6, "check name test is used twice"},
      {"uppercase check name",
       "version: 1\ncommands:\n  checks:\n    - name: Unit\n      run: mix test\n", 4,
       "check name Unit must be lowercase"},
      {"acceptance reserved name",
       "version: 1\ncommands:\n  checks:\n    - name: acceptance\n      run: mix test\n", 4,
       "check name acceptance is reserved"},
      {"model reserved name",
       "version: 1\ncommands:\n  checks:\n    - name: model\n      run: mix test\n", 4,
       "check name model is reserved"},
      {"steps_dir number", "version: 1\ncommands:\n  acceptance:\n    steps_dir: 3\n", 4,
       "commands.acceptance.steps_dir must be a string or null"}
    ]

    for {label, text, line, message} <- cases do
      error =
        assert_raise Error, fn -> Config.parse!(text, "/tmp/#{label}/.kogen/project.yaml") end

      assert error.class == "environment"
      assert error.reason == "project_config_invalid"
      assert error.detail == "/tmp/#{label}/.kogen/project.yaml"
      assert error.exit == 3
      assert error.lines == ["line #{line}: #{message}"]
    end
  end

  test "SET-4: loading an invalid project file reports its actual path and source line" do
    root = Path.join(System.tmp_dir!(), "kogen-config-#{System.unique_integer([:positive])}")
    path = Path.join(root, Config.path())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "version: 1\ncommands:\n  acceptance:\n    run: true\n")
    on_exit(fn -> File.rm_rf!(root) end)

    error = assert_raise Error, fn -> Config.load!(root) end

    assert error.detail == path
    assert error.lines == ["line 4: commands.acceptance.run must be a string or null"]
  end
end
