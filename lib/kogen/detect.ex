defmodule Kogen.Detect do
  @moduledoc "Deterministic detection of a project's commands from its committed root files (SET-10)."

  @npm_ci "npm ci --no-audit --no-fund"
  @npm_placeholder ~s(echo "Error: no test specified" && exit 1)
  @npm_scripts ~w(test lint typecheck check)

  @doc """
  `files` maps root file names to their committed text (nil when absent); `tracked` lists every
  tracked path. Returns `%{setup, fix, checks, protect, runner}`, where `runner` is the steps
  folder of an existing Cucumber runner, or nil.
  """
  def detect(files, tracked) do
    %{setup: [], fix: [], checks: [], protect: [], runner: nil}
    |> mix(files["mix.exs"], &(&1 in tracked))
    |> npm(json(files["package.json"]), tracked)
  end

  @doc """
  The acceptance command (SET-10, SET-13): the project's own Cucumber when it has one, else the
  one Kogen ships, whose `node_modules` also resolves the step files' `require('@cucumber/cucumber')`;
  both on Kogen's own Node.
  """
  def acceptance_command(steps_dir, :project),
    do: ~s("$KOGEN_NODE" node_modules/@cucumber/cucumber/bin/cucumber.js ) <> args(steps_dir)

  def acceptance_command(steps_dir, :kogen),
    do:
      ~s(NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" ) <>
        args(steps_dir)

  defp args(steps_dir),
    do:
      ~s(--strict --require '#{steps_dir}/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES")

  defp mix(d, nil, _), do: d

  defp mix(d, mix_exs, exists?) do
    formatter = exists?.(".formatter.exs")
    credo = String.contains?(mix_exs, ":credo")

    %{
      d
      | setup: d.setup ++ ["mix deps.get"],
        fix: d.fix ++ if(formatter, do: ["mix format"], else: []),
        checks:
          d.checks ++
            if(formatter, do: [check("format", "mix format --check-formatted")], else: []) ++
            [check("compile", "mix compile --warnings-as-errors"), check("test", "mix test")] ++
            if(credo, do: [check("credo", "mix credo --strict")], else: []),
        protect:
          d.protect ++
            if(formatter, do: [".formatter.exs"], else: []) ++
            if(credo and exists?.(".credo.exs"), do: [".credo.exs"], else: [])
    }
  end

  defp npm(d, nil, _), do: d

  defp npm(d, pkg, tracked) do
    scripts = if is_map(pkg["scripts"]), do: pkg["scripts"], else: %{}

    checks =
      Enum.reduce(@npm_scripts, d.checks, fn script, checks ->
        body = scripts[script]

        if is_binary(body) and String.trim(body) != @npm_placeholder do
          taken = Enum.any?(checks, &(&1.name == script))
          name = if taken, do: "npm-#{script}", else: script
          checks ++ [check(name, "npm run #{script}")]
        else
          checks
        end
      end)

    deps = Map.merge(map(pkg["dependencies"]), map(pkg["devDependencies"]))

    runner =
      if Map.has_key?(deps, "@cucumber/cucumber"),
        do:
          Enum.find(~w(features/steps features/step_definitions), "features/steps", fn dir ->
            Enum.any?(tracked, &String.starts_with?(&1, dir <> "/"))
          end)

    %{
      d
      | setup: d.setup ++ if("package-lock.json" in tracked, do: [@npm_ci], else: []),
        checks: checks,
        runner: runner
    }
  end

  defp check(name, run), do: %{name: name, run: run}
  defp map(m) when is_map(m), do: m
  defp map(_), do: %{}

  defp json(nil), do: nil

  defp json(text) do
    case JSON.decode(text) do
      {:ok, m} when is_map(m) -> m
      _ -> nil
    end
  end
end
