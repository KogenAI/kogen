defmodule Kogen.DetectTest do
  use ExUnit.Case, async: true

  alias Kogen.{Detect, Init}

  test "SET-10: a Mix project with a formatter and credo gets setup, fixer, checks and protect" do
    mix = ~s(defp deps, do: [{:credo, "~> 1.7", only: :test}])
    d = Detect.detect(%{"mix.exs" => mix}, ~w(mix.exs .formatter.exs .credo.exs lib/a.ex))

    assert d.setup == ["mix deps.get"]
    assert d.fix == ["mix format"]
    assert Enum.map(d.checks, & &1.name) == ~w(format compile test credo)
    assert d.protect == ~w(.formatter.exs .credo.exs)
    assert d.runner == nil
  end

  test "SET-10: a Mix project without .formatter.exs or credo gets compile and test only" do
    d = Detect.detect(%{"mix.exs" => "defmodule A.MixProject do end"}, ~w(mix.exs))

    assert d.fix == []

    assert d.checks == [
             %{name: "compile", run: "mix compile --warnings-as-errors"},
             %{name: "test", run: "mix test"}
           ]

    assert d.protect == []
  end

  test "SET-10: npm scripts become checks, npm's placeholder test does not, a taken name is prefixed" do
    pkg =
      JSON.encode!(%{
        "scripts" => %{
          "test" => ~s(echo "Error: no test specified" && exit 1),
          "lint" => "eslint .",
          "build" => "vite build"
        }
      })

    d = Detect.detect(%{"package.json" => pkg}, ~w(package.json package-lock.json))
    assert d.setup == ["npm ci --no-audit --no-fund"]
    assert d.checks == [%{name: "lint", run: "npm run lint"}]

    both =
      Detect.detect(
        %{"mix.exs" => "", "package.json" => JSON.encode!(%{"scripts" => %{"test" => "jest"}})},
        ~w(mix.exs package.json)
      )

    assert Enum.map(both.checks, & &1.name) == ~w(compile test npm-test)
    assert both.setup == ["mix deps.get"]
  end

  test "SET-10: an existing Cucumber runner and its steps folder are found" do
    pkg = JSON.encode!(%{"devDependencies" => %{"@cucumber/cucumber" => "13.3.0"}})

    assert Detect.detect(
             %{"package.json" => pkg},
             ~w(package.json features/step_definitions/a.js)
           ).runner ==
             "features/step_definitions"

    assert Detect.detect(%{"package.json" => pkg}, ~w(package.json)).runner == "features/steps"
  end

  test "SET-11: a proposed check replaces the detected one of the same name, others are added after" do
    detected = %{
      setup: ["mix deps.get"],
      fix: [],
      checks: [%{name: "test", run: "mix test"}, %{name: "compile", run: "mix compile"}],
      protect: [".formatter.exs"]
    }

    proposed = %{
      setup: ["mix deps.get", "mix ecto.create"],
      fix: ["mix format"],
      checks: [
        %{name: "sobelow", run: "mix sobelow"},
        %{name: "test", run: "mix test --warnings-as-errors"}
      ],
      protect: [".credo.exs", ".formatter.exs"]
    }

    assert Init.merge(detected, proposed) == %{
             setup: ["mix deps.get", "mix ecto.create"],
             fix: ["mix format"],
             checks: [
               %{name: "test", run: "mix test --warnings-as-errors"},
               %{name: "compile", run: "mix compile"},
               %{name: "sobelow", run: "mix sobelow"}
             ],
             protect: [".formatter.exs", ".credo.exs"]
           }
  end

  test "SET-11: dependency-only manifests and lockfiles cannot be protected, but check definitions and settings can" do
    cases = [
      {"mix.exs",
       "defmodule App.MixProject do\n  def project, do: [app: :app, deps: deps()]\n  defp deps, do: [{:ecto, \"~> 3.0\"}]\nend\n",
       [], false},
      {"cli/go.mod",
       "module example.invalid/cli\n\ngo 1.27\n\nrequire example.invalid/lib v1.0.0\n", [],
       false},
      {"cli/go.sum", "example.invalid/lib v1.0.0 h1:abc\n", [], false},
      {"mix.lock", "%{\"ecto\" => {:hex, :ecto, \"3.0\", \"checksum\"}}\n", [], false},
      {"package-lock.json", "{\"lockfileVersion\": 3, \"packages\": {}}\n", [], false},
      {"package.json", JSON.encode!(%{"scripts" => %{"lint" => "eslint ."}}),
       [%{"name" => "lint", "run" => "npm run lint"}], true},
      {"package.json", JSON.encode!(%{"eslintConfig" => %{"rules" => %{"eqeqeq" => "error"}}}),
       [%{"name" => "lint", "run" => "npx eslint ."}], true},
      {"mix.exs",
       "def project, do: [aliases: [check: [\"format --check-formatted\", \"test\"]]]\n",
       [%{"name" => "check", "run" => "mix check"}], true},
      {"mix.exs",
       "def project, do: [aliases: aliases()]\ndefp aliases, do: [check: [\"test\"]]\n",
       [%{"name" => "check", "run" => "mix check"}], true},
      {"mix.exs", "def project, do: [elixirc_options: [warnings_as_errors: true]]\n",
       [%{"name" => "compile", "run" => "mix compile"}], true},
      {"mix.exs", "# aliases: [check: [\"test\"]]\ndef project, do: [deps: []]\n",
       [%{"name" => "check", "run" => "mix check"}], false},
      {".formatter.exs", "[inputs: [\"{lib,test}/**/*.{ex,exs}\"]]\n", [], true}
    ]

    for {path, content, checks, eligible} <- cases do
      args = %{"setup" => [], "fix" => [], "checks" => checks, "protect" => [path]}
      tracked = %{tracked_paths: [path], contents: %{path => content}}

      case {eligible, Init.validate(args, tracked)} do
        {true, {:ok, %{protect: [^path]}}} ->
          :ok

        {false, {:invalid, problems}} ->
          assert Enum.any?(
                   problems,
                   &String.starts_with?(&1, "protect path #{path} is not eligible:")
                 )

        result ->
          flunk("unexpected validation for #{path}: #{inspect(result)}")
      end
    end
  end

  test "SET-11: protection validation includes detected checks when the proposal adds none" do
    args = %{"checks" => [], "protect" => ["package.json"]}

    context = %{
      tracked_paths: ["package.json"],
      contents: %{"package.json" => JSON.encode!(%{"scripts" => %{"test" => "node --test"}})},
      detected_checks: [%{name: "test", run: "npm run test"}]
    }

    assert {:ok, %{protect: ["package.json"]}} = Init.validate(args, context)
  end

  test "SET-11: Mix test discovery and coverage settings are verification configuration" do
    for key <- ~w(test_paths test_pattern test_load_filters test_ignore_filters test_coverage) do
      assert {:ok, %{protect: ["mix.exs"]}} =
               Init.validate(%{"protect" => ["mix.exs"]}, %{
                 "mix.exs" => "def project, do: [#{key}: []]"
               })
    end
  end

  test "SET-11: the committed Mix test-selection settings are protected verification configuration" do
    {manifest, 0} = System.cmd("git", ["show", "HEAD:mix.exs"])
    assert manifest =~ "test_load_filters:"
    assert manifest =~ "test_ignore_filters:"

    context = %{
      tracked_paths: ["mix.exs"],
      contents: %{"mix.exs" => manifest},
      detected_checks: [%{name: "test", run: "mix test"}]
    }

    assert {:ok, %{protect: ["mix.exs"]}} =
             Init.validate(%{"checks" => [], "protect" => ["mix.exs"]}, context)
  end

  test "SET-11: invalid names, duplicates, reserved names and untracked protect paths are problems" do
    args = %{
      "setup" => [""],
      "checks" => [
        %{"name" => "Docs Check", "run" => "x"},
        %{"name" => "acceptance", "run" => "x"},
        %{"name" => "a", "run" => "x"},
        %{"name" => "a", "run" => "y"}
      ],
      "protect" => ["missing.cfg"]
    }

    assert {:invalid, problems} = Init.validate(args, ~w(README.md))

    assert problems == [
             "setup must be a list of non-empty commands",
             "protect path missing.cfg is not a tracked file",
             "check name Docs Check must be lowercase letters, digits and dashes",
             "check name acceptance is reserved",
             "check name a is used twice"
           ]

    assert {:ok, %{checks: [%{name: "docs", run: "node docs-check.js"}]}} =
             Init.validate(
               %{"checks" => [%{"name" => "docs", "run" => "node docs-check.js"}]},
               []
             )
  end
end
