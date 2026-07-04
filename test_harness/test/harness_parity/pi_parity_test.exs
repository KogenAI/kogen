defmodule CodegenTestHarness.HarnessParity.PhoenixMinimalTest do
  @moduledoc """
  Asserts the phoenix-minimal build produces the same observable contract under
  both the claude and pi harnesses (exit 0, key file present, >= 1 commit beyond
  the scaffold's initial commit). A Pi-only launcher/dispatch break reds here
  instead of shipping. Legitimate per-harness divergence is suppressed only via
  a `known_divergent.exs` tuple with a written reason.
  """
  use ExUnit.Case, async: false

  alias CodegenTestHarness.Fixtures

  @moduletag :harness_parity
  @moduletag timeout: 3_900_000

  @scenario "phoenix-minimal"
  @harnesses ["claude", "pi"]
  @key_file "mix.exs"

  @allowlist Code.eval_file(Path.join(__DIR__, "known_divergent.exs")) |> elem(0)

  setup do
    {:ok, cwd_for: fn -> Fixtures.isolated_tmp_dir(stack: :phoenix) end}
  end

  test "phoenix-minimal builds equivalently on claude and pi", %{cwd_for: cwd_for} do
    results =
      Map.new(@harnesses, fn harness ->
        cwd = cwd_for.()
        commits_before = Fixtures.count_commits!(cwd)

        {exit_code, output} =
          Fixtures.run_codegen_build_parity(
            cwd,
            harness,
            "Add a single Phoenix context module `Catalog` with a `list_items/0` " <>
              "that returns []. No migration, no LiveView. Keep it minimal.",
            stack: "phoenix"
          )

        key_present? = File.exists?(Path.join(cwd, @key_file))
        commits_after = Fixtures.count_commits!(cwd)

        {harness,
         %{
           exit: exit_code,
           key: key_present?,
           new_commits: commits_after - commits_before,
           output: output
         }}
      end)

    allowed = Enum.map(@allowlist, fn {s, h, _} -> {s, h} end)

    for {harness, r} <- results do
      if {@scenario, harness} in allowed do
        {_, _, reason} =
          Enum.find(@allowlist, fn {s, h, _} -> {s, h} == {@scenario, harness} end)

        IO.puts(:stderr, "[harness-parity] allowed divergence #{@scenario}/#{harness}: #{reason}")
        assert r.exit == 0, "#{@scenario}/#{harness} exit #{r.exit}\n#{r.output}"
      else
        assert r.exit == 0, "#{@scenario}/#{harness} exit #{r.exit} (expected 0)\n#{r.output}"
        assert r.key, "#{@scenario}/#{harness} missing #{@key_file}"

        assert r.new_commits >= 1,
               "#{@scenario}/#{harness} produced no commit beyond scaffold init"
      end
    end
  end
end

defmodule CodegenTestHarness.HarnessParity.StaticMinimalTest do
  @moduledoc """
  Asserts the static-minimal build produces the same observable contract under
  both the claude and pi harnesses (exit 0, key file present, >= 1 commit beyond
  the scaffold's initial commit). A Pi-only launcher/dispatch break reds here
  instead of shipping. Legitimate per-harness divergence is suppressed only via
  a `known_divergent.exs` tuple with a written reason.
  """
  use ExUnit.Case, async: false

  alias CodegenTestHarness.Fixtures

  @moduletag :harness_parity
  @moduletag timeout: 3_900_000

  @scenario "static-minimal"
  @harnesses ["claude", "pi"]
  @key_file "index.html"

  @allowlist Code.eval_file(Path.join(__DIR__, "known_divergent.exs")) |> elem(0)

  setup do
    {:ok, cwd_for: fn -> Fixtures.isolated_tmp_dir() end}
  end

  test "static-minimal builds equivalently on claude and pi", %{cwd_for: cwd_for} do
    results =
      Map.new(@harnesses, fn harness ->
        cwd = cwd_for.()
        commits_before = Fixtures.count_commits!(cwd)

        {exit_code, output} =
          Fixtures.run_codegen_build_parity(
            cwd,
            harness,
            "Create a single static `index.html` with an `<h1>Hello</h1>`. No build tooling.",
            stack: "static"
          )

        key_present? = File.exists?(Path.join(cwd, @key_file))
        commits_after = Fixtures.count_commits!(cwd)

        {harness,
         %{
           exit: exit_code,
           key: key_present?,
           new_commits: commits_after - commits_before,
           output: output
         }}
      end)

    allowed = Enum.map(@allowlist, fn {s, h, _} -> {s, h} end)

    for {harness, r} <- results do
      if {@scenario, harness} in allowed do
        {_, _, reason} =
          Enum.find(@allowlist, fn {s, h, _} -> {s, h} == {@scenario, harness} end)

        IO.puts(:stderr, "[harness-parity] allowed divergence #{@scenario}/#{harness}: #{reason}")
        assert r.exit == 0, "#{@scenario}/#{harness} exit #{r.exit}\n#{r.output}"
      else
        assert r.exit == 0, "#{@scenario}/#{harness} exit #{r.exit} (expected 0)\n#{r.output}"
        assert r.key, "#{@scenario}/#{harness} missing #{@key_file}"

        assert r.new_commits >= 1,
               "#{@scenario}/#{harness} produced no commit beyond scaffold init"
      end
    end
  end
end
