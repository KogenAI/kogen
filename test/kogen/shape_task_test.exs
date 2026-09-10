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

  @draft """
  id: 01960000-0000-7000-8000-000000000abc
  slug: unfinished
  shaped_against:
    branch: old-main
    head: old-head
  shaping:
    harness: codex
    model: old-model
    effort: low
    started: '2026-01-01T00:00:00Z'
  """

  test "continuation uses current profiles and role without mutating unfinished draft" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    File.write!(Path.join(draft, "intent.yaml"), @draft)

    File.write!(
      Path.join(draft, "questions.md"),
      "Parked until process reassessment. Historical yes."
    )

    prompt_path = Path.join(fixture, "priv/kogen/prompts/shaping.md")
    File.write!(prompt_path, File.read!(prompt_path) <> "\nCURRENT_SHARED_ROLE_MARKER\n")
    config_path = Path.join(fixture, ".kogen/config.yaml")

    config =
      File.read!(config_path)
      |> String.replace("gpt-6-astra", "current-root")
      |> String.replace("gpt-5.6-luna", "current-scout")
      |> String.replace("low", "medium")

    File.write!(config_path, config)
    before = snapshot(draft)

    {output, 0} = capture(fixture, ["unfinished"])
    assert output =~ "01960000-0000-7000-8000-000000000abc"
    assert snapshot(draft) == before
    refute File.exists?(Path.join(fixture, ".kogen/intents/approved/unfinished"))
    prompt = File.read!(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
    args = File.read!(Path.join(fixture, ".kogen/runtime/shaping-args"))
    assert args =~ "--model\ncurrent-root\n"
    assert args =~ ~s(model_reasoning_effort="medium")
    refute args =~ "\nresume\n"

    for text <- [
          "CURRENT_SHARED_ROLE_MARKER",
          "current-scout",
          "old-main",
          "old-head",
          "Current checkout branch: `main`",
          "shaping_continuations",
          "append exactly one",
          "Keep original `shaping` metadata unchanged",
          "Parked work",
          "conflicts",
          "relevant linked evidence",
          "ask where",
          "Historical approval",
          "Missing or incomplete"
        ] do
      assert prompt =~ text
    end

    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: fixture)
    assert prompt =~ String.trim(head)
    refute prompt =~ "already minted"
    refute prompt =~ "{{"
  end

  test "invalid selections fail before harness launch" do
    fixture = shape_fixture()
    dir = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(dir)

    missing_fields =
      for key <- ["id", "slug", "shaped_against", "shaping"],
          do:
            {Regex.replace(Regex.compile!("(?m)^#{key}:[^\\n]*\\n(?:  [^\\n]*\\n)*"), @draft, ""),
             key}

    nested_fields =
      for {key, value} <- [
            {"branch", "old-main"},
            {"head", "old-head"},
            {"harness", "codex"},
            {"model", "old-model"},
            {"effort", "low"},
            {"started", "'2026-01-01T00:00:00Z'"}
          ],
          do: {String.replace(@draft, "  #{key}: #{value}\n", ""), key}

    for {yaml, diagnostic} <-
          [
            {"[broken", "YAML"},
            {String.replace(@draft, "slug: unfinished", "slug: other"), "slug"}
          ] ++ missing_fields ++ nested_fields do
      File.write!(Path.join(dir, "intent.yaml"), yaml)
      {output, status} = capture(fixture, ["unfinished"])
      assert status != 0
      assert output =~ diagnostic
      assert File.read!(Path.join(dir, "intent.yaml")) == yaml
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
    end

    for args <- [
          ["../unfinished"],
          ["/tmp/unfinished"],
          ["Bad_slug"],
          ["missing"],
          ["one", "two"]
        ] do
      {_, status} = capture(fixture, args)
      assert status != 0
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
    end

    File.rm!(Path.join(dir, "intent.yaml"))

    for state <- ["approved", "complete"] do
      destination = Path.join(fixture, ".kogen/intents/#{state}/unfinished")
      File.mkdir_p!(destination)
      File.write!(Path.join(destination, "intent.yaml"), @draft)
      {output, status} = capture(fixture, ["unfinished"])
      assert status != 0
      assert output =~ "missing or unreadable"
    end

    File.ln_s!(
      Path.join(fixture, ".kogen/intents/approved/unfinished/intent.yaml"),
      Path.join(dir, "intent.yaml")
    )

    {output, status} = capture(fixture, ["unfinished"])
    assert status != 0
    assert output =~ "symbolic links"
    refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
  end

  defp shape_fixture do
    fixture = Kogen.CompiledFixture.create!(File.cwd!(), "continue-shape")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_fixture_git!(fixture)
    fixture
  end

  defp capture(fixture, args) do
    Kogen.CompiledFixture.mix_task!(fixture, ["kogen.shape" | args], [
      {"KOGEN_HARNESS", Path.join(fixture, "test/support/fake_codex_shaper")},
      {"KOGEN_SHAPE_CAPTURE_ONLY", "1"}
    ])
  end

  defp snapshot(dir) do
    Map.new(Path.wildcard(Path.join(dir, "**/*")), &{&1, File.read!(&1)})
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
