Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.ShapeTaskTest do
  use ExUnit.Case, async: true

  @moduletag :lifecycle

  test "public Shape mints an identity and persists a Draft for explicit fixture approval" do
    source = File.cwd!()
    fixture = Kogen.CompiledFixture.create!(source, "shape")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_fixture_git!(fixture)
    bulk_sentinel = "SHAPING_FILE_BODY_SENTINEL"
    File.write!(Path.join(fixture, "README.md"), String.duplicate(bulk_sentinel, 50_000))
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
    assert shaped["shaping"]["route"] == config.route
    assert shaped["shaping"]["harness"] == "codex"
    assert shaped["shaping"]["model"] == config.shaping.model
    assert shaped["shaping"]["effort"] == config.shaping.effort
    args = File.read!(Path.join(fixture, ".kogen/runtime/shaping-args"))
    prompt = File.read!(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
    refute prompt =~ bulk_sentinel
    assert args =~ "--model\n#{config.shaping.model}\n"
    assert args =~ ~s(model_reasoning_effort="#{config.shaping.effort}")
    assert_shared_execution_policy!(prompt, :shaping, config)
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
      "Parked until process reassessment. Historical yes.\n" <>
        String.duplicate("CONTINUED_SHAPING_BODY_SENTINEL", 40_000)
    )

    prompt_path = Path.join(fixture, "priv/kogen/prompts/shaping.md")
    File.write!(prompt_path, File.read!(prompt_path) <> "\nCURRENT_SHARED_ROLE_MARKER\n")
    config_path = Path.join(fixture, ".kogen/config.yaml")

    File.write!(config_path, distinct_config())
    before = snapshot(draft)

    {output, 0} = capture(fixture, ["unfinished"])
    assert output =~ "01960000-0000-7000-8000-000000000abc"
    assert snapshot(draft) == before
    refute File.exists?(Path.join(fixture, ".kogen/intents/approved/unfinished"))
    prompt = File.read!(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
    refute prompt =~ "CONTINUED_SHAPING_BODY_SENTINEL"
    args = File.read!(Path.join(fixture, ".kogen/runtime/shaping-args"))
    assert args =~ "--model\ncurrent-shaper\n"
    assert args =~ ~s(model_reasoning_effort="shaping-effort")
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
          "Missing or incomplete",
          "Follow direction already supplied",
          "partial answer"
        ] do
      assert prompt =~ text
    end

    assert prompt =~
             "route: current\nharness: codex\nmodel: current-shaper\neffort: shaping-effort\n"

    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: fixture)
    assert prompt =~ String.trim(head)
    refute prompt =~ "already minted"
    refute prompt =~ "{{"
    {:ok, config} = Kogen.Intent.read_config(config_path)
    assert_shared_execution_policy!(prompt, :shaping, config)
  end

  test "fresh shaping guidance requires autonomous outcome-focused investigation" do
    prompt = File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/shaping.md"))
    compact = Regex.replace(~r/\s+/, prompt, " ")

    for text <- [
          "Trace the proposed feature from its realistic starting state",
          "source-linked probe",
          "A plan to probe is not execution",
          "write only inside the active",
          "does not authorize editing `README.md`",
          "A different passing mock cannot repair missing credentials",
          "Partial answers settle only explicitly selected",
          "Distinguish supplied public behavior",
          "material public choice is absent",
          "end the turn without asking for approval",
          "request for package review is not approval",
          "Select targets by affected existing workflows",
          "outer driver alone observes an ephemeral interaction",
          "zero questions is not itself a quality target"
        ] do
      assert compact =~ text
    end

    refute compact =~ "JSON pairs or tab-separated lines"
    refute compact =~ "LF for a newly normalized CSV output"
  end

  test "rendered shaping roles keep approval explicit and bookkeeping narrow" do
    fresh = File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/shaping.md"))
    continued = File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/shaping-continuation.md"))
    reviewer = File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/reviewer.md"))

    for prompt <- [fresh, continued] do
      compact = Regex.replace(~r/\s+/, prompt, " ")
      assert compact =~ "explicit"
      assert compact =~ "current-conversation"
      assert compact =~ "current approval statement"
      assert compact =~ "current approval metadata"
      assert compact =~ "current-tense"
      assert compact =~ "agreed requirements"
      assert compact =~ "original provenance"
      assert compact =~ "historical evidence"
      assert compact =~ "partial answer"
      assert compact =~ "review request"
      assert compact =~ "no source, test"
    end

    assert reviewer =~ "selected `approved/` directory is the lifecycle state owner"
    assert reviewer =~ "legacy `status: draft`"
    assert reviewer =~ "genuine current contradictions"
    assert reviewer =~ "current claim that approval is still pending"
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

  test "fresh and continued Shape reject invalid required profiles before harness dispatch" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    File.write!(Path.join(draft, "intent.yaml"), @draft)
    config_path = Path.join(fixture, ".kogen/config.yaml")

    invalid_configs = [
      {"missing helper",
       String.replace(
         distinct_config(),
         "      expert: {model: current-expert, effort: expert-effort}\n",
         ""
       ), "routes.current.helpers.expert"},
      {"blank root model",
       String.replace(distinct_config(), "model: current-developer", "model: \"\""),
       "routes.current.developer.model"},
      {"wrong-typed helper effort",
       String.replace(distinct_config(), "effort: scout-effort", "effort: 42"),
       "routes.current.helpers.scout.effort"}
    ]

    for {args, route} <- [{[], "fresh"}, {["unfinished"], "continuation"}],
        {_case, config, diagnostic} <- invalid_configs do
      File.write!(config_path, config)
      File.rm_rf!(Path.join(fixture, ".kogen/runtime"))

      {output, status} = capture(fixture, args)

      assert status != 0, "#{route} Shape launched with invalid #{diagnostic}"
      assert output =~ "config.yaml missing required key: #{diagnostic}"
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-args"))
    end
  end

  @claude_config """
  default_route: claude
  routes:
    claude:
      harness: claude
      shaping:   {model: claude-opus-5-5, effort: medium}
      developer: {model: claude-opus-5-5, effort: medium}
      reviewer:  {model: claude-opus-5-5, effort: medium}
      helpers:
        scout:  {model: claude-sonnet-5, effort: low}
        worker: {model: claude-sonnet-5, effort: medium}
        expert: {model: claude-opus-5-5, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  test "Claude Code Shape launches the interactive managed claude with the prompt as first message" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    File.write!(Path.join(draft, "intent.yaml"), @draft)
    File.write!(Path.join(fixture, ".kogen/config.yaml"), @claude_config)
    claude_root = Path.join(fixture <> "-claude-root", "claude")
    File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)

    for {args, mode} <- [{[], "fresh"}, {["unfinished"], "continuation"}] do
      File.rm_rf!(Path.join(fixture, ".kogen/runtime"))

      {output, 0} =
        Kogen.CompiledFixture.mix_task!(fixture, ["kogen.shape" | args], [
          {"KOGEN_HARNESS", Path.join(fixture, "test/support/fake_claude_shaper")},
          {"KOGEN_CLAUDE_ROOT", claude_root},
          {"ANTHROPIC_API_KEY", "INHERITED-API-KEY"},
          {"CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT", "0"}
        ])

      argv =
        fixture |> Path.join(".kogen/runtime/shaping-args") |> File.read!() |> String.split("\n")

      prompt = File.read!(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
      env = File.read!(Path.join(fixture, ".kogen/runtime/shaping-env"))

      assert output =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}/
      refute "-p" in argv

      args_bytes = File.read!(Path.join(fixture, ".kogen/runtime/shaping-args"))
      assert prompt != ""

      assert String.ends_with?(args_bytes, "\n--\n" <> prompt <> "\n"),
             "the rendered prompt must be the first message after --"

      assert prompt =~ if(mode == "fresh", do: "Fresh", else: "continuation")
      assert_flag!(argv, "--model", "claude-opus-5-5")
      assert_flag!(argv, "--effort", "medium")
      assert_flag!(argv, "--setting-sources", "project")
      assert "--dangerously-skip-permissions" in argv
      assert "--strict-mcp-config" in argv
      assert "Agent(general-purpose)" in argv
      refute Enum.any?(argv, &String.contains?(&1, "model_reasoning_effort"))
      refute "--enable" in argv

      agents = argv |> flag("--agents") |> Jason.decode!()

      for {_name, agent} <- agents,
          do: assert(Enum.all?(agent["tools"], &(&1 not in ~w(Edit Write NotebookEdit))))

      assert env =~ "KOGEN_ROLE=shaper"
      assert env =~ "CLAUDE_CONFIG_DIR=#{Path.join(claude_root, "accounts/shared")}"
      assert env =~ "DISABLE_AUTOUPDATER=1"
      assert env =~ "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1\n"
      assert env =~ "ANTHROPIC_API_KEY=unset"

      assert prompt =~ "harness `claude`" or prompt =~ "harness: claude"
      assert prompt =~ "route `claude`" or prompt =~ "route: claude"
      assert prompt =~ "Claude Code agent `kogen-scout`"
      refute prompt =~ "native kind `explorer`"
      refute prompt =~ "{{"
    end
  end

  test "Claude Code Shape stops before launch when the runtime, login or model is not ready" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    File.write!(Path.join(draft, "intent.yaml"), @draft)
    config_path = Path.join(fixture, ".kogen/config.yaml")
    claude_root = Path.join(fixture <> "-claude-root", "claude")
    trace = Path.join(Path.dirname(claude_root), "trace.jsonl")
    File.mkdir_p!(claude_root)
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)
    env = [{"KOGEN_CLAUDE_ROOT", claude_root}, {"KOGEN_TEST_NATIVE_TRACE", trace}]

    route = fn args ->
      File.rm_rf!(Path.join(fixture, ".kogen/runtime"))
      {output, status} = Kogen.CompiledFixture.mix_task!(fixture, ["kogen.shape" | args], env)
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
      {output, status}
    end

    File.write!(config_path, @claude_config)

    for args <- [[], ["unfinished"]] do
      {output, status} = route.(args)
      assert status != 0
      assert output =~ "Kogen Claude Code 2.1.281 is not installed. Run mix kogen.claude.install"
    end

    source = File.cwd!()

    {_out, 0} =
      System.cmd("python3", [
        Path.join(source, "test/support/managed_claude_fixture.py"),
        claude_root,
        Path.join(source, "priv/kogen/claude_code/install.py")
      ])

    for args <- [[], ["unfinished"]] do
      {output, status} = route.(args)
      assert status != 0

      assert output =~
               "Selected shared Kogen Claude Code login is not configured. Run mix kogen.claude.login"
    end

    File.write!(
      config_path,
      String.replace(
        @claude_config,
        "shaping:   {model: claude-opus-5-5",
        "shaping:   {model: gpt-5.6-sol"
      )
    )

    for args <- [[], ["unfinished"]] do
      {output, status} = route.(args)
      assert status != 0
      assert output =~ "unsupported Claude Code model for shaping: gpt-5.6-sol"
    end

    refute File.exists?(trace) and File.read!(trace) =~ ~s("-p")
    refute File.exists?(trace) and File.read!(trace) =~ ~s("--dangerously-skip-permissions")
  end

  test "Shape runs on the default route or the --route route in every argument position" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    File.write!(Path.join(draft, "intent.yaml"), @draft)
    config_path = Path.join(fixture, ".kogen/config.yaml")
    File.write!(config_path, two_route_config())
    before = snapshot(draft)

    for {args, route, mode} <- [
          {[], "current", :fresh},
          {["--route", "other"], "other", :fresh},
          {["--route=other"], "other", :fresh},
          {["unfinished"], "current", :continuation},
          {["--route", "other", "unfinished"], "other", :continuation},
          {["unfinished", "--route", "other"], "other", :continuation}
        ] do
      File.rm_rf!(Path.join(fixture, ".kogen/runtime"))
      {_output, 0} = capture(fixture, args)

      {:ok, config} = Kogen.Intent.read_config(config_path, route)
      args_text = File.read!(Path.join(fixture, ".kogen/runtime/shaping-args"))
      prompt = File.read!(Path.join(fixture, ".kogen/runtime/shaping-prompt"))

      assert args_text =~ "--model\n#{route}-shaper\n", inspect(args)
      assert args_text =~ ~s(model_reasoning_effort="#{config.shaping.effort}")
      assert_shared_execution_policy!(prompt, :shaping, config)

      case mode do
        :fresh ->
          assert prompt =~ "route `#{route}`, harness `codex`, model `#{route}-shaper`"

        :continuation ->
          assert prompt =~
                   "route: #{route}\nharness: codex\nmodel: #{route}-shaper\neffort: #{config.shaping.effort}\n"
      end

      other = if route == "current", do: "other", else: "current"
      refute prompt =~ "#{other}-shaper"
      refute prompt =~ "#{other}-scout"
    end

    assert snapshot(draft) == before
  end

  test "continuing a Draft first shaped on another route records this session's route only" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    routed = String.replace(@draft, "  harness: codex\n", "  route: other\n  harness: codex\n")
    File.write!(Path.join(draft, "intent.yaml"), routed)
    File.write!(Path.join(fixture, ".kogen/config.yaml"), two_route_config())
    before = snapshot(draft)

    {_output, 0} = capture(fixture, ["unfinished"])

    prompt = File.read!(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
    assert prompt =~ "route: current\nharness: codex\nmodel: current-shaper\n"
    refute prompt =~ "route: other"
    assert prompt =~ "Keep original `shaping` metadata unchanged"
    assert Regex.replace(~r/\s+/, prompt, " ") =~ "including its `route` or its absence"
    assert snapshot(draft) == before
  end

  test "unknown routes, missing route values and unknown options fail before harness launch" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    File.write!(Path.join(draft, "intent.yaml"), @draft)
    File.write!(Path.join(fixture, ".kogen/config.yaml"), two_route_config())
    before = snapshot(Path.join(fixture, ".kogen/intents"))
    usage = "usage: mix kogen.shape [--route <name>] [draft-slug]"

    for {args, expected} <- [
          {["--route", "missing"], "unknown route: missing; available routes: current, other"},
          {["--route", "missing", "unfinished"],
           "unknown route: missing; available routes: current, other"},
          {["--route"], usage},
          {["unfinished", "--route"], usage},
          {["--route="], usage},
          {["--bogus"], usage},
          {["--route", "other", "one", "two"], usage}
        ] do
      File.rm_rf!(Path.join(fixture, ".kogen/runtime"))
      {output, status} = capture(fixture, args)

      assert status != 0, inspect(args)
      assert output =~ expected, inspect(args)
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-args"))
      assert snapshot(Path.join(fixture, ".kogen/intents")) == before
    end
  end

  test "the flat configuration shape is refused before harness launch" do
    fixture = shape_fixture()
    draft = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(draft)
    File.write!(Path.join(draft, "intent.yaml"), @draft)

    File.write!(Path.join(fixture, ".kogen/config.yaml"), """
    harness: codex
    shaping: {model: current-shaper, effort: shaping-effort}
    developer: {model: current-developer, effort: developer-effort}
    reviewer: {model: current-reviewer, effort: reviewer-effort}
    helpers:
      scout: {model: current-scout, effort: scout-effort}
      worker: {model: current-worker, effort: worker-effort}
      expert: {model: current-expert, effort: expert-effort}
    outer_resumptions: 2
    verification_retries: 2
    """)

    before = snapshot(Path.join(fixture, ".kogen/intents"))

    for args <- [[], ["unfinished"], ["--route", "current"]] do
      {output, status} = capture(fixture, args)
      assert status != 0
      assert output =~ "flat configuration shape"
      assert output =~ "define default_route and routes"
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
      assert snapshot(Path.join(fixture, ".kogen/intents")) == before
    end
  end

  test "only the selected route is checked for harness support, proven models and readiness" do
    fixture = shape_fixture()
    config_path = Path.join(fixture, ".kogen/config.yaml")
    claude_root = Path.join(fixture <> "-claude-root", "claude")
    File.mkdir_p!(claude_root)
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)

    File.write!(
      config_path,
      distinct_config("""
        pi:
          harness: pi-chatgpt
          shaping: {model: pi-model, effort: low}
          developer: {model: pi-model, effort: low}
          reviewer: {model: pi-model, effort: low}
          helpers:
            scout: {model: pi-model, effort: low}
            worker: {model: pi-model, effort: low}
            expert: {model: pi-model, effort: low}
        unproven:
          harness: claude
          shaping: {model: claude-unproven-9, effort: medium}
          developer: {model: claude-opus-5-5, effort: medium}
          reviewer: {model: claude-opus-5-5, effort: medium}
          helpers:
            scout: {model: claude-sonnet-5, effort: low}
            worker: {model: claude-sonnet-5, effort: medium}
            expert: {model: claude-opus-5-5, effort: high}
        claude:
          harness: claude
          shaping: {model: claude-opus-5-5, effort: medium}
          developer: {model: claude-opus-5-5, effort: medium}
          reviewer: {model: claude-opus-5-5, effort: medium}
          helpers:
            scout: {model: claude-sonnet-5, effort: low}
            worker: {model: claude-sonnet-5, effort: medium}
            expert: {model: claude-opus-5-5, effort: high}
      """)
    )

    # The selected Codex route proceeds although the other routes name an
    # unsupported harness, an unproven model and an uninstalled Claude Code.
    {_output, 0} =
      Kogen.CompiledFixture.mix_task!(fixture, ["kogen.shape"], [
        {"KOGEN_HARNESS", Path.join(fixture, "test/support/fake_codex_shaper")},
        {"KOGEN_SHAPE_CAPTURE_ONLY", "1"},
        {"KOGEN_CLAUDE_ROOT", claude_root}
      ])

    assert File.read!(Path.join(fixture, ".kogen/runtime/shaping-args")) =~ "current-shaper"

    for {route, expected} <- [
          {"pi", "unsupported harness: pi-chatgpt; expected codex or claude"},
          {"unproven", "unsupported Claude Code model for shaping: claude-unproven-9"},
          {"claude", "Kogen Claude Code 2.1.281 is not installed. Run mix kogen.claude.install"}
        ] do
      File.rm_rf!(Path.join(fixture, ".kogen/runtime"))

      {output, status} =
        Kogen.CompiledFixture.mix_task!(fixture, ["kogen.shape", "--route", route], [
          {"KOGEN_CLAUDE_ROOT", claude_root}
        ])

      assert status != 0
      assert output =~ expected
      refute File.exists?(Path.join(fixture, ".kogen/runtime/shaping-prompt"))
    end
  end

  defp flag(argv, name), do: argv |> Enum.drop_while(&(&1 != name)) |> Enum.at(1)
  defp assert_flag!(argv, name, value), do: assert(flag(argv, name) == value)

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
    for path <- Path.wildcard(Path.join(dir, "**/*")),
        File.regular?(path),
        into: %{},
        do: {path, File.read!(path)}
  end

  defp distinct_config(extra_routes \\ "") do
    """
    default_route: current
    routes:
      current:
        harness: codex
        shaping: {model: current-shaper, effort: shaping-effort}
        developer: {model: current-developer, effort: developer-effort}
        reviewer: {model: current-reviewer, effort: reviewer-effort}
        helpers:
          scout: {model: current-scout, effort: scout-effort}
          worker: {model: current-worker, effort: worker-effort}
          expert: {model: current-expert, effort: expert-effort}
    #{extra_routes}outer_resumptions: 2
    verification_retries: 2
    """
  end

  # A second Codex route with distinguishable profiles.
  defp two_route_config(extra_routes \\ "") do
    distinct_config("""
      other:
        harness: codex
        shaping: {model: other-shaper, effort: other-shaping-effort}
        developer: {model: other-developer, effort: other-developer-effort}
        reviewer: {model: other-reviewer, effort: other-reviewer-effort}
        helpers:
          scout: {model: other-scout, effort: other-scout-effort}
          worker: {model: other-worker, effort: other-worker-effort}
          expert: {model: other-expert, effort: other-expert-effort}
    #{extra_routes}
    """)
  end

  defp assert_shared_execution_policy!(prompt, role, config) do
    assert length(String.split(prompt, "## Shared execution and delegation policy")) == 2

    root = Map.fetch!(config, role)

    assert prompt =~ "Configured root (#{role}): `#{root.model}` at `#{root.effort}`."

    assert prompt =~
             "- **scout:** `#{config.helpers.scout.model}` at `#{config.helpers.scout.effort}`; native kind `explorer`."

    assert prompt =~
             "- **worker:** `#{config.helpers.worker.model}` at `#{config.helpers.worker.effort}`; native kind `worker`."

    assert prompt =~
             "- **expert:** `#{config.helpers.expert.model}` at `#{config.helpers.expert.effort}`; native kind `default`."

    refute prompt =~ "{{execution_policy}}"
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
