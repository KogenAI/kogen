Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.ShapeTaskTest do
  use ExUnit.Case, async: true

  @moduletag :lifecycle

  test "public Shape mints an identity and persists a Draft for explicit fixture approval" do
    source = File.cwd!()
    fixture = Kogen.CompiledFixture.create!(source, "shape")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_fixture_git!(fixture)
    env = [{"KOGEN_HARNESS", Path.join(fixture, "test/support/fake_codex_shaper")}]

    {output, 0} = Kogen.CompiledFixture.mix_task!(fixture, "kogen.shape", env)

    draft = Path.join(fixture, ".kogen/intents/drafts/fake-shaped-intent")
    assert File.dir?(draft)

    [id] =
      Regex.run(~r/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/, output)

    draft_text = File.read!(Path.join(draft, "intent.yaml"))
    assert draft_text =~ id
    shaped = YamlElixir.read_from_string!(draft_text)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: fixture)
    assert shaped["shaped_against"] == %{"branch" => "main", "head" => String.trim(head)}
    {:ok, config} = Kogen.Intent.read_config(Path.join(fixture, ".kogen/config.yaml"))
    assert shaped["shaping"]["harness"] == "codex"
    assert shaped["shaping"]["model"] == config.shaping.model
    assert shaped["shaping"]["effort"] == config.shaping.effort
    approved = Path.join(fixture, ".kogen/intents/approved/fake-shaped-intent")
    File.mkdir_p!(Path.dirname(approved))
    File.rename!(draft, approved)
    refute File.dir?(draft)
    assert File.exists?(Path.join(approved, "scenarios.yaml"))
  end

  defp init_fixture_git!(fixture) do
    env = [
      {"GIT_AUTHOR_NAME", "Kogen Shape Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-shape-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Shape Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-shape-fixture@example.invalid"}
    ]

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_, 0} =
      System.cmd("git", ["commit", "-q", "-m", "shape fixture baseline"], cd: fixture, env: env)
  end
end
