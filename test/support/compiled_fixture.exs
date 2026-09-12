defmodule Kogen.CompiledFixture do
  @moduledoc false

  @fixture_files [
    ".gitignore",
    "mix.exs",
    ".kogen/config.yaml",
    ".codex/hooks.json",
    ".codex/hooks/check.sh",
    ".codex/hooks/verification_policy.py",
    "priv/kogen/prompts/execution-policy.md",
    "priv/kogen/prompts/developer.md",
    "priv/kogen/prompts/reviewer.md",
    "priv/kogen/prompts/shaping.md",
    "priv/kogen/prompts/shaping-fresh.md",
    "priv/kogen/prompts/shaping-continuation.md",
    "test/support/codex",
    "test/support/fake_codex",
    "test/support/scenario_response.py",
    "test/support/fake_codex_shaper"
  ]

  @doc "Creates a private lifecycle fixture that loads this test build's BEAM files."
  def create!(source, label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-#{label}-#{:os.getpid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "lib"))

    Enum.each(@fixture_files, fn relative ->
      destination = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(source, relative), destination)
    end)

    File.chmod!(Path.join(root, ".codex/hooks/check.sh"), 0o755)
    File.chmod!(Path.join(root, "test/support/fake_codex"), 0o755)
    File.chmod!(Path.join(root, "test/support/fake_codex_shaper"), 0o755)

    File.write!(
      Path.join(root, "Makefile"),
      ".PHONY: check\n\ncheck:\n\t@test ! -f lib/kogen_fake_break.ex || { echo 'bounded fixture check: lib/kogen_fake_break.ex remains' >&2; exit 1; }\n"
    )

    root
  end

  @doc "Runs a public Mix task in the fixture without compiling into a shared cache."
  def mix_task!(fixture, task, env \\ [])

  def mix_task!(fixture, task, env) when is_binary(task),
    do: mix_task!(fixture, [task], env)

  def mix_task!(fixture, task, env) when is_list(task) do
    {output, exit_code} =
      System.cmd(
        "elixir",
        ["--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++
          Enum.flat_map(compiled_ebins(), &["-pa", &1]) ++ ["-S", "mix"] ++ task,
        cd: fixture,
        env: [{"MIX_BUILD_PATH", Path.join(fixture, "_build")} | env],
        stderr_to_stdout: true
      )

    {output, exit_code}
  end

  defp compiled_ebins do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(
      &(Path.type(&1) == :absolute and Path.basename(&1) == "ebin" and File.dir?(&1))
    )
    |> Enum.sort()
  end
end
