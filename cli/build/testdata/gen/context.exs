# Reference for the builder's opening message: runs lib/kogen/build.ex's private context/1
# (made public in a renamed copy) on fixed inputs and writes the contract blocks as JSON.
#
#   mise exec -- mix run --no-start cli/build/testdata/gen/context.exs   (in the repository root)
root_dir = File.cwd!()
:persistent_term.put(:kogen_caller, %{env: %{}, cwd: root_dir, install_root: root_dir})

src =
  File.read!("lib/kogen/build.ex")
  |> String.replace("defmodule Kogen.Build do", "defmodule Kogen.BuildGolden do")
  |> String.replace("defp context(b)", "def context(b)")

Code.compile_string(src)

intent_md = """
# Add a "greeting" #{1 + 1} \\ é
Slug: fixture
Model: %MODEL%

Acceptance:
- .kogen/intents/fixture/acceptance.feature
- features/steps/s.js

## Tests
- one: unit
"""

feature = "Feature: F\n  Scenario: S\n    Given a thing\n"

cases = [
  %{
    name: "no model",
    model_line: "not applicable — nothing",
    model_qnt: nil,
    readme: "# Project\n\nText.\n",
    setup: [],
    fix: [],
    checks: [],
    acceptance_run: nil,
    baseline: [".kogen/intents/fixture/intent.md", ".kogen/project.yaml"]
  },
  %{
    name: "model and commands",
    model_line: "model.qnt invariants=inv seed=1 samples=2 steps=3",
    model_qnt: "module m { val x = 1 }\n",
    readme: nil,
    setup: ["npm ci", "echo \"q\" 'r' \#{x} \\ é\n"],
    fix: ["mix format"],
    checks: [{"test", "mix test"}, {"lint", "mix credo --strict"}],
    acceptance_run: "node run.js \"$X\"",
    baseline: [".kogen/intents/fixture/intent.md", "features/steps/s.js", ".kogen/project.yaml"]
  }
]

out =
  for c <- cases do
    dir = Path.join(System.tmp_dir!(), "ctx-gen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".kogen/intents/fixture"))
    File.write!(Path.join(dir, ".kogen/intents/fixture/intent.md"), String.replace(intent_md, "%MODEL%", c.model_line))
    File.write!(Path.join(dir, ".kogen/intents/fixture/acceptance.feature"), feature)
    if c.model_qnt, do: File.write!(Path.join(dir, ".kogen/intents/fixture/model.qnt"), c.model_qnt)
    if c.readme, do: File.write!(Path.join(dir, "README.md"), c.readme)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    File.write!(Path.join(dir, "a.txt"), "a\n")

    config = %Kogen.Config{
      setup: c.setup,
      fix: c.fix,
      checks: c.checks,
      acceptance_run: c.acceptance_run,
      steps_dir: "features/steps"
    }

    b = %{
      root: dir,
      slug: "fixture",
      intent: Kogen.Intent.read(dir, "fixture"),
      config: config,
      baseline: c.baseline
    }

    [stable, dynamic] = Kogen.BuildGolden.context(b)

    File.rm_rf!(dir)

    %{
      "name" => c.name,
      "model_line" => c.model_line,
      "model_qnt" => c.model_qnt,
      "readme" => c.readme,
      "setup" => c.setup,
      "fix" => c.fix,
      "checks" => Enum.map(c.checks, fn {n, r} -> [n, r] end),
      "acceptance_run" => c.acceptance_run,
      "baseline" => c.baseline,
      "files" => "a.txt\n.kogen/intents/fixture/acceptance.feature\n.kogen/intents/fixture/intent.md\nREADME.md\n",
      "stable" => stable["text"],
      "dynamic" => dynamic["text"]
    }
  end

File.write!("cli/build/testdata/context-golden.json", JSON.encode!(out))
IO.puts("wrote #{length(out)} cases")
