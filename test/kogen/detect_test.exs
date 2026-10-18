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
