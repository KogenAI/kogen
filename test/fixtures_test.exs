defmodule Kogen.FixturesTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Proc

  @project_root Path.expand("..", __DIR__)
  @fixture_root Path.expand("../fixtures/hello_app", __DIR__)
  @reference_root Path.expand("../fixtures/hello_app_reference", __DIR__)
  @project_script """
  root = hd(System.argv())
  source = File.read!(Path.join([root, "demo/intents/status-json.md"]))

  with {:ok, project} <- Kogen.Project.load(root),
       {:ok, intent} <- Kogen.Intent.parse_binary(source, "status-json/intent.md"),
       [] <- Kogen.Intent.lint(intent),
       true <- project.name == "kogen" and intent.slug == "status-json" do
    IO.write("valid")
  else
    result ->
      IO.inspect(result, label: "Kogen demo validation failed")
      System.halt(1)
  end
  """
  @fixture_script """
  root = hd(System.argv())
  path = Path.join([root, ".kogen/intents/greet/intent.md"])

  with {:ok, project} <- Kogen.Project.load(root),
       {:ok, intent} <- Kogen.Intent.parse(path),
       [] <- Kogen.Intent.lint(intent),
       true <- project.name == "hello-app" and intent.slug == "greet" do
    IO.write("valid")
  else
    result ->
      IO.inspect(result, label: "hello_app validation failed")
      System.halt(1)
  end
  """

  @tag :fixture
  test "validates demo inputs and proves the greet Intent red then green", %{tmp_dir: tmp_dir} do
    validate_artifacts(@project_root, @project_script)
    project_root = Kogen.Testkit.Git.create!(tmp_dir)
    copy_tree!(@fixture_root, project_root)
    validate_artifacts(project_root, @fixture_script)
    assert_fixture_check(project_root)
    assert_acceptance_red(project_root)
    copy_tree!(@reference_root, project_root)
    assert_acceptance_green(project_root)
  end

  defp validate_artifacts(project_root, script) do
    output =
      Proc.cmd!(
        "elixir",
        child_args() ++ ["-e", script, "--", project_root],
        cd: project_root
      )

    assert output == "valid"
  end

  defp assert_fixture_check(project_root) do
    started = System.monotonic_time(:millisecond)
    output = Proc.cmd!("make", ["check"], cd: project_root)
    elapsed = System.monotonic_time(:millisecond) - started

    assert output =~ "check"
    assert elapsed < 10_000, "hello_app make check took #{elapsed} ms"
  end

  defp assert_acceptance_red(project_root) do
    failure =
      assert_raise RuntimeError, fn ->
        Proc.cmd!(
          "mise",
          ["exec", "--", "mix", "test", "--force", ".kogen/acceptance/greet_test.exs"],
          cd: project_root
        )
      end

    assert failure.message =~ "Failed: 3 tests"
  end

  defp assert_acceptance_green(project_root) do
    output =
      Proc.cmd!(
        "mise",
        ["exec", "--", "mix", "test", "--force", ".kogen/acceptance/greet_test.exs"],
        cd: project_root
      )

    assert output =~ "3 passed"
  end

  defp copy_tree!(source_root, target_root) do
    for source <- Path.wildcard(Path.join(source_root, "**/*"), match_dot: true) do
      relative = Path.relative_to(source, source_root)

      if !Enum.any?(Path.split(relative), &(&1 in ["_build", "deps"])) do
        target = Path.join(target_root, relative)

        if File.dir?(source) do
          File.mkdir_p!(target)
        else
          File.mkdir_p!(Path.dirname(target))
          File.cp!(source, target)
        end
      end
    end
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
