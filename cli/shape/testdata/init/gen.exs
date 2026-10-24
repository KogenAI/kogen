# Generates cli/shape/testdata/init/mix-golden.json from the Elixir Kogen (Kogen.Init.validate/2):
#   mise exec -- mix run --no-start cli/shape/testdata/init/gen.exs
# TestInitMixVerificationMatchesElixir compares the Go scanner with these pinned results.
real = File.read!("mix.exs")

sources = [
  real,
  "defmodule App.MixProject do\n  def project, do: [app: :app, deps: deps()]\n  defp deps, do: [{:ecto, \"~> 3.0\"}]\nend\n",
  "def project, do: [aliases: [check: [\"format --check-formatted\", \"test\"]]]\n",
  "def project, do: [aliases: aliases()]\ndefp aliases, do: [check: [\"test\"]]\n",
  "def project, do: [aliases: aliases()]\ndefp aliases() do\n  [check: [\"test\"], lint: &lint/1]\nend\n",
  "def project, do: [aliases: aliases]\ndefp aliases, do: [check: [\"test\"]]\n",
  "def project, do: [elixirc_options: [warnings_as_errors: true]]\n",
  "# aliases: [check: [\"test\"]]\ndef project, do: [deps: []]\n",
  "def project, do: [deps: []]\n# elixirc_options: []\n",
  "def project do\n  [\n    app: :a,\n    # xref: [exclude: []]\n    deps: []\n  ]\nend\n",
  "def project do\n  [\n    app: :a,\n    xref: [exclude: [A]],\n    deps: []\n  ]\nend\n",
  "def project do\n  base = [app: :a]\n  base ++ [dialyzer: [plt_add_apps: [:mix]]]\nend\n",
  "def project do\n  base = [app: :a]\n  [dialyzer: [plt_add_apps: [:mix]]]\nend\n",
  "def project do\n  [app: :a, name: \"aliases: [check: 1]\", deps: []]\nend\n",
  "def project do\n  [app: :a, doc: \"\"\"\n  elixirc_options: x\n  \"\"\", deps: []]\nend\n",
  "def project do\n  [app: :a, doc: ~S(xref: [) , deps: []]\nend\n",
  "def project do\n  [app: :a, rx: ~r/credo: [/, deps: []]\nend\n",
  "def project do\n  [app: :a, s: \"#{inspect(1)} test_paths\", deps: []]\nend\n",
  "def project do\n  [{:app, :a}, {:test_paths, [\"t\"]}]\nend\n",
  "def project do\n  [:app, test_paths: [\"t\"]]\nend\n",
  "def project(), do: [credo: [strict: true]]\n",
  "def project(arg), do: [credo: [strict: true]]\n",
  "defp project, do: [test_coverage: [tool: ExCoveralls]]\n",
  "def project do\n  Keyword.merge([app: :a], test_paths: [\"t\"])\nend\n",
  "def project do\n  ([test_pattern: \"*_x.exs\"])\nend\n",
  "def project do\n  [app: :a, aliases: aliases(), deps: []]\nend\n\ndef aliases do\n  [\n    check: [\n      \"format --check-formatted\",\n      \"test\"\n    ],\n    setup: [\"deps.get\"]\n  ]\nend\n",
  "def project do\n  [app: :a, aliases: [setup: [\"deps.get\"], \"ci.check\": [\"test\"]]]\nend\n",
  "def project do\n  [app: :a, aliases: [\"ci.check\": [\"test\"]]]\nend\n",
  "def project do\n  [app: :a,\n   aliases: foo()]\nend\ndef foo, do: [check: []]\n",
  "def project do\n  [app: :a, aliases: Foo.aliases()]\nend\n",
  "def project do\n  [app: :a, aliases: []]\nend\n",
  "def project do\n  [app: :a, aliases: nil]\nend\n",
  "def project do\n  if Mix.env() == :test do\n    [credo: []]\n  else\n    [deps: []]\n  end\nend\n",
  "def project do\n  [deps: [], test_load_filters: [&String.ends_with?(&1, \"_test.exs\")]]\nend\n",
  "def project do\n  [deps: [], releases: [kogen: [steps: [:assemble]]], test_ignore_filters: [~r/x/]]\nend\n",
  "def project do\n  [deps: [<<1, 2>>, ?a, ?\\n, 0x1F, 1.5e3], test_paths: []]\nend\n",
  "def project do\n  [deps: [fn x ->\n    x\n  end], xref: []]\nend\n",
  "def project do\n  [deps: [], xref: []\nend\n",
  "def project do\n  [deps: [\"unterminated], xref: []]\nend\n",
  "defmodule A do\n  def project do\n    [deps: []]\n  end\n  def project do\n    [dialyzer: []]\n  end\nend\n",
  "defmodule A do\n  def project do\n    [dialyzer: []]\n  end\n  def project do\n    [deps: []]\n  end\nend\n",
  "def project do\n  [deps: []]\nrescue\n  _ -> [dialyzer: []]\nend\n",
  "",
  "not elixir at all {{{",
  "def project, do: [credo: []] |> Keyword.put(:app, :a)\n",
  "def project, do: [app: :a]\n  |> Keyword.put(:credo, [])\n",
  "def project, do: [credo: []] ++\n  [app: :a]\n"
]

check_sets = [
  [],
  [%{"name" => "check", "run" => "mix check"}],
  [%{"name" => "lint", "run" => "mix ci.check"}],
  [%{"name" => "setup", "run" => "mix setup && mix test"}],
  [%{"name" => "test", "run" => "mix test"}, %{"name" => "check", "run" => "mix check"}],
  [%{"name" => "compile", "run" => "mix compile"}]
]

cases =
  for text <- sources, checks <- check_sets do
    args = %{"setup" => [], "fix" => [], "checks" => checks, "protect" => ["mix.exs"]}
    ctx = %{tracked_paths: ["mix.exs"], contents: %{"mix.exs" => text}}

    eligible =
      case Kogen.Init.validate(args, ctx) do
        {:ok, _} -> true
        {:invalid, [problem]} -> not String.starts_with?(problem, "protect path mix.exs is not eligible:") and raise("unexpected #{problem}")
      end

    %{"text" => text, "checks" => checks, "eligible" => eligible}
  end

File.write!("cli/shape/testdata/init/mix-golden.json", JSON.encode!(cases))
IO.puts("#{length(cases)} cases, #{Enum.count(cases, & &1["eligible"])} eligible")
