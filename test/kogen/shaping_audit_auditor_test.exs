Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)

defmodule Kogen.ShapingAuditAuditorTest do
  @moduledoc """
  `Kogen.ShapingAudit.Auditor` (`auditor-setting`, `blind-auditor-layer`).
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingAudit.{Auditor, Finding, Fixture, Materialization, Package, Questions}

  @root Path.expand("../..", __DIR__)
  @fake_auditor Path.join(@root, "test/support/shaping_audit/fake_auditor")

  @config_with_auditor """
  default_route: codex
  routes:
    codex:
      harness: codex
      shaping:   {model: expert-model, effort: low}
      developer: {model: expert-model, effort: low}
      reviewer:  {model: expert-model, effort: low}
      auditor:   {model: audit-model, effort: high}
      helpers:
        scout:  {model: expert-model, effort: low}
        worker: {model: expert-model, effort: low}
        expert: {model: expert-model, effort: low}
  outer_resumptions: 1
  verification_retries: 1
  offline_retries: 4
  """

  @config_without_auditor """
  default_route: codex
  routes:
    codex:
      harness: codex
      shaping:   {model: expert-model, effort: low}
      developer: {model: expert-model, effort: low}
      reviewer:  {model: expert-model, effort: low}
      helpers:
        scout:  {model: expert-model, effort: low}
        worker: {model: expert-model, effort: low}
        expert: {model: expert-model, effort: low}
  outer_resumptions: 1
  verification_retries: 1
  offline_retries: 4
  """

  # -- helpers ---------------------------------------------------------------

  defp isolated_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-auditor-test-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp write_config(root, text, route \\ "codex") do
    path = Path.join(root, "auditor-config.yaml")
    File.write!(path, text)
    {:ok, config} = Kogen.Intent.read_config(path, route)
    config
  end

  defp parse_scenarios(nil), do: nil

  defp parse_scenarios(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, list} -> list
      _ -> nil
    end
  end

  # Builds a fresh audit ctx (a fresh materialization, as the real
  # orchestrator does per `mix kogen.audit` run) and runs the auditor layer.
  # Removes the materialization afterwards, mirroring the orchestrator's own
  # `after` clause.
  defp run_audit(root, package_rel, config, deterministic_findings, run_opts) do
    {:ok, %{files: files, revision: revision}} = Package.load(root, package_rel)
    {:ok, intent} = YamlElixir.read_from_string(files["intent.yaml"])
    questions = Questions.parse(files["questions.md"])
    {:ok, %{dir: materialization, base: base}} = Materialization.create(root, package_rel, files)

    ctx = %{
      root: root,
      slug: intent["slug"],
      package_rel: package_rel,
      materialization: materialization,
      files: files,
      intent: intent,
      scenarios: parse_scenarios(files["scenarios.yaml"]),
      questions: questions,
      state: Questions.state(questions),
      head: Fixture.head(root),
      revision: revision,
      route: config.route,
      config: config,
      env: %{},
      opts: []
    }

    result = Auditor.run(ctx, deterministic_findings, run_opts)
    Materialization.remove(base)
    {result, ctx}
  end

  defp fake_env(log_dir, overrides \\ []) do
    [
      {"KOGEN_HARNESS", @fake_auditor},
      {"FAKE_AUDITOR_LOG_DIR", log_dir}
    ] ++ overrides
  end

  defp put_env(pairs) do
    Enum.each(pairs, fn {key, value} ->
      if is_nil(value), do: System.delete_env(key), else: System.put_env(key, value)
    end)
  end

  defp clear_env(pairs) do
    Enum.each(pairs, fn {key, _value} -> System.delete_env(key) end)
  end

  # The materialization is removed after the run, so resolve its nearest
  # existing ancestor and rejoin the rest.
  defp physical_path(path) do
    path = Path.expand(path)

    if File.dir?(path) do
      {physical, 0} = System.cmd("pwd", ["-P"], cd: path)
      String.trim(physical)
    else
      Path.join(physical_path(Path.dirname(path)), Path.basename(path))
    end
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp record_files(root, slug) do
    dir = Path.join([root, ".kogen/runtime/shaping-audits", slug, "auditor"])

    case File.ls(dir) do
      {:ok, names} -> Enum.filter(names, &String.ends_with?(&1, ".json"))
      {:error, _} -> []
    end
  end

  # -- prompt rendering, parsing, ids, bounds (pure) --------------------------

  test "parse_message reads the last fenced JSON object" do
    message = """
    thinking...

    ```json
    {"findings": []}
    ```

    Actually, one more thought, then the real answer:

    ```json
    {"findings": [{"label": "l", "summary": "s", "detail": "d", "paths": []}]}
    ```
    """

    assert {:ok, [%{"label" => "l"}]} = Auditor.parse_message(message)
  end

  test "parse_message accepts a bare JSON final message" do
    assert {:ok, []} = Auditor.parse_message(~s({"findings": []}))
  end

  test "parse_message fails on prose with no JSON" do
    assert :error = Auditor.parse_message("I could not finish in time.")
  end

  test "build_findings bounds fields, paths and the finding count, and stores dropped counts" do
    findings_60 =
      for i <- 1..60, do: %{"label" => "l#{i}", "summary" => "s", "detail" => "d", "paths" => []}

    {findings, dropped} = Auditor.build_findings(findings_60, "message-60")

    assert dropped == %{"findings" => 10, "fields" => 0, "paths" => 0}
    # 50 real findings plus the synthetic "findings dropped" finding.
    assert length(findings) == 51
    assert Enum.any?(findings, &(&1["rule"] == "auditor-findings-dropped"))

    assert Enum.any?(
             findings,
             &(&1["disputable"] == false and &1["rule"] == "auditor-findings-dropped")
           )

    oversized = [
      %{
        "label" => "l",
        "summary" => String.duplicate("s", 500),
        "detail" => String.duplicate("d", 2000),
        "paths" => Enum.map(1..20, &"p#{&1}")
      }
    ]

    {[finding], dropped2} = Auditor.build_findings(oversized, "message-oversized")
    assert dropped2 == %{"findings" => 0, "fields" => 2, "paths" => 1}
    assert String.length(finding["message"]) <= 200 + 3 + 1000
    assert length(finding["paths"]) == 10

    assert finding["id"] ==
             "aud-" <>
               String.slice(
                 Base.encode16(:crypto.hash(:sha256, "message-oversized"), case: :lower),
                 0,
                 6
               ) <> "-1"
  end

  test "render_prompt inlines the bounded package, strips revisions/baseline_history/shaping_continuations/*approval* keys from intent.yaml, and trims questions.md after ## Dispositions" do
    intent_yaml = """
    id: 1
    slug: demo
    title: Demo
    revisions:
      - note: history, never inlined
    baseline_history:
      - note: also history
    shaping_continuations:
      - note: also history
    approval:
      approved_by: Someone
    revision_12_approval:
      note: historical
    may_change_guarded_paths: []
    """

    questions_md = """
    ## Settled

    kept-before-dispositions

    ## Dispositions

    kept-in-dispositions

    ## History

    dropped-after-dispositions
    """

    ctx = %{
      package_rel: ".kogen/intents/drafts/demo",
      revision: "revabc",
      head: "headsha",
      materialization: isolated_dir("prompt-materialization"),
      files: %{
        "intent.yaml" => intent_yaml,
        "scenarios.yaml" => "- id: x\n",
        "risks.yaml" => "risks: []\n",
        "INTENT.md" => "# Demo\n",
        "questions.md" => questions_md
      },
      intent: %{"may_change_guarded_paths" => []},
      scenarios: []
    }

    on_exit(fn -> File.rm_rf(ctx.materialization) end)

    {prompt, not_audited} = Auditor.render_prompt(ctx, [])

    assert not_audited == []
    refute prompt =~ "history, never inlined"
    refute prompt =~ "also history"
    refute prompt =~ "approved_by"
    refute prompt =~ "historical"
    assert prompt =~ "may_change_guarded_paths"
    assert prompt =~ "kept-before-dispositions"
    assert prompt =~ "kept-in-dispositions"
    refute prompt =~ "dropped-after-dispositions"
    assert prompt =~ "revabc"
    assert prompt =~ "headsha"
    assert prompt =~ ".kogen/intents/drafts/demo"
  end

  test "render_prompt cuts at the byte budget and lists every file left out as not_audited" do
    big = String.duplicate("x", 200_000)

    ctx = %{
      package_rel: ".kogen/intents/drafts/demo",
      revision: "revabc",
      head: "headsha",
      materialization: isolated_dir("prompt-cut-materialization"),
      files: %{
        "intent.yaml" => "id: 1\nslug: demo\n",
        "scenarios.yaml" => big,
        "risks.yaml" => "risks: []\n",
        "INTENT.md" => "# Demo\n",
        "questions.md" => "## Settled\nnone\n"
      },
      intent: %{"may_change_guarded_paths" => []},
      scenarios: []
    }

    on_exit(fn -> File.rm_rf(ctx.materialization) end)

    {prompt, not_audited} = Auditor.render_prompt(ctx, [])

    assert not_audited != []
    assert Enum.any?(not_audited, &(&1 =~ "risks.yaml"))
    assert prompt =~ "Not audited by the auditor"
    assert byte_size(prompt) < 165_000
  end

  # -- run rule, ids, dispositions --------------------------------------------

  describe "run/3 gating" do
    test "skipped while the session is asking" do
      # State gating happens before anything is read from disk, so a fully
      # synthetic ctx (never touched) is enough here.
      ctx = %{state: :asking}
      result = Auditor.run(ctx, [], launch?: true)

      assert result["status"] == "skipped"
      assert result["findings"] == []
    end

    test "skipped while an open blocking deterministic finding exists; Jev never gates it" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      blocking = Finding.new("package-invalid", nil, %{"message" => "broken"})
      {result, _ctx} = run_audit(root, package_rel, config, [blocking], launch?: true)

      assert result["status"] == "skipped"
    end

    test "a missing auditor setting gives unavailable naming the route and launches nothing" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_without_auditor)

      log_dir = isolated_dir("missing-setting-log")
      put_env(fake_env(log_dir))
      on_exit(fn -> clear_env(fake_env(log_dir)) end)

      {result, _ctx} = run_audit(root, package_rel, config, [], launch?: true)

      assert result["status"] == "unavailable"
      assert result["reason"] =~ "codex"
      assert result["reason"] =~ "no auditor setting"
      refute File.exists?(Path.join(log_dir, "argv"))
    end
  end

  describe "run/3 launching" do
    test "launches through the route's auditor setting, in the materialization, with the auditor.md prompt only" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("launch-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "three-findings"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {result, ctx} = run_audit(root, package_rel, config, [], launch?: true, prior_failures: [])

      assert result["status"] == "ok"
      assert length(result["findings"]) == 3
      assert Enum.all?(result["findings"], &String.starts_with?(&1["id"], "aud-"))
      assert Enum.all?(result["findings"], &(&1["severity"] == "blocking"))
      assert Enum.all?(result["findings"], &(&1["layer"] == "auditor"))
      assert Enum.all?(result["findings"], &Map.has_key?(&1, "auditor_label"))

      pwd = read_lines(Path.join(log_dir, "pwd")) |> List.first()
      # The fake logs `pwd -P`; /var is a symlink to /private/var on macOS.
      assert Path.expand(pwd) == physical_path(ctx.materialization)

      env_lines = read_lines(Path.join(log_dir, "env"))
      assert Enum.any?(env_lines, &(&1 == "KOGEN_ROLE=auditor"))
      assert Enum.any?(env_lines, &(&1 == "GIT_OPTIONAL_LOCKS=0"))

      stdin = File.read!(Path.join(log_dir, "stdin"))
      assert stdin =~ "read-only"
      assert stdin =~ "infeasible or contradictory scenarios"
      refute stdin =~ "You are the Expert in Kogen"

      argv = read_lines(Path.join(log_dir, "argv"))
      assert Enum.any?(argv, &(&1 == "audit-model"))
      refute Enum.any?(argv, &(&1 == "expert-model"))

      [record_file] = record_files(root, "complete")

      record =
        Path.join([root, ".kogen/runtime/shaping-audits/complete/auditor", record_file])
        |> File.read!()
        |> Jason.decode!()

      assert record["phase"] == "reserved"
      assert record["status"] == "unavailable"
      [completed] = Auditor.load_records(ctx)
      assert completed["attempt_id"] == record["attempt_id"]
      assert completed["phase"] == "completed"
      record = completed

      assert record["harness"] == "codex"
      assert record["model"] == "audit-model"
      assert record["effort"] == "high"
      assert record["route"] == "codex"
      assert record["head"] == ctx.head
      assert record["revision"] == ctx.revision
      assert is_binary(record["prompt_sha256"])
      assert record["counted"] == true
    end

    test "the prompt carries no finding of the other layers and no checkout path" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("no-other-findings-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "empty"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {_result, ctx} = run_audit(root, package_rel, config, [], launch?: true)

      stdin = File.read!(Path.join(log_dir, "stdin"))
      refute stdin =~ ctx.root
      refute stdin =~ "stale-anchor"
      refute stdin =~ "recommendation-without-evidence"
    end

    test "runs date-first and one-reply instructions, and its checklist items appear whitespace-normalised" do
      prompt_template = File.read!(Path.join(@root, "priv/kogen/prompts/auditor.md"))

      checklist_items = [
        "infeasible or contradictory scenarios",
        "a plausible wrong implementation that passes the proofs",
        "unguarded paths and existing tests that will break",
        "missing or blind selectors",
        "wrong citations",
        "every consumer of each new or changed persisted artifact, including copies in live fixtures",
        "files the running controller reads",
        "overlap with other packages and landed commits",
        "any Build input that is not on main (a branch, stash, scratchpad or prototype diff)",
        "the prior failures of this Intent",
        "each addition with its caller in this Intent",
        "requested scope deferred",
        "anything relabelling a timeout or failure as provider or environment",
        "a mock instead of the real consumer",
        "a weakened validator"
      ]

      normalized = prompt_template |> String.replace(~r/\s+/, " ")

      assert normalized =~ "Run `date` first"
      assert normalized =~ "answer within about 4 minutes"
      assert normalized =~ "ONE reply"
      assert normalized =~ "without running any other command"

      for item <- checklist_items do
        assert normalized =~ String.replace(item, ~r/\s+/, " "),
               "expected the auditor prompt to contain: #{item}"
      end
    end

    test "the findings format example parses with the production parser" do
      prompt_template = File.read!(Path.join(@root, "priv/kogen/prompts/auditor.md"))
      [_, example] = Regex.run(~r/```json\n(.*?)```/s, prompt_template)
      assert {:ok, _findings} = Auditor.parse_message("```json\n" <> example <> "```")
    end
  end

  describe "run/3 the run rule and time budget" do
    test "a prior result on another HEAD or route is diagnostic only and does not spend that binding's budget" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("binding-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "three-findings"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {first, first_ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert first["status"] == "ok"

      File.write!(Path.join(root, "lib/b.ex"), "defmodule B do\n  def value, do: 2\nend\n")
      {_, 0} = System.cmd("git", ["add", "lib/b.ex"], cd: root)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "move HEAD"], cd: root)

      {new_head, head_ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert new_head["status"] == "ok"
      assert new_head["budget_state"]["normal_count"] == 1
      assert new_head["audited_binding"]["head"] == head_ctx.head
      assert head_ctx.head != first_ctx.head
      assert new_head["previous_audit"]["head"] == first_ctx.head
      assert length(new_head["previous_audit"]["findings"]) == 3

      alternate_config_text =
        @config_with_auditor
        |> String.replace("default_route: codex", "default_route: alternate")
        |> String.replace("codex:", "alternate:")

      alternate_config = write_config(root, alternate_config_text, "alternate")
      {new_route, route_ctx} = run_audit(root, package_rel, alternate_config, [], launch?: true)
      assert new_route["status"] == "ok"
      assert new_route["budget_state"]["normal_count"] == 1
      assert new_route["audited_binding"]["route"] == "alternate"
      assert route_ctx.route == "alternate"
      assert new_route["previous_audit"]["route"] == "codex"
      assert length(record_files(root, "complete")) == 3
    end

    test "a first run with findings, one confirming run, then a third --auditor on the same HEAD launches nothing" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("bound-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "three-findings"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {first, first_ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert first["status"] == "ok"
      assert length(first["findings"]) == 3
      refute first["bound_reached"]

      # Same HEAD, same revision: reused, no relaunch.
      File.rm_rf!(log_dir)
      File.mkdir_p!(log_dir)
      {same, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert same["status"] == "ok"
      refute File.exists?(Path.join(log_dir, "argv"))

      # Edit the Draft at the same HEAD: a confirming run is due.
      File.write!(Path.join([root, package_rel, "risks.yaml"]), "risks: []\n")

      {confirming, confirming_ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert confirming["status"] == "ok"
      assert confirming["bound_reached"]
      assert File.exists?(Path.join(log_dir, "argv"))

      assert confirming["audited_binding"] == %{
               "revision" => confirming_ctx.revision,
               "config_fingerprint" => Kogen.Intent.config_fingerprint(config),
               "head" => confirming_ctx.head,
               "route" => confirming_ctx.route
             }

      assert confirming["previous_audit"]["revision"] == first_ctx.revision
      assert length(confirming["previous_audit"]["findings"]) == 3

      # A third --auditor request on the same HEAD launches nothing further.
      File.rm_rf!(log_dir)
      File.mkdir_p!(log_dir)
      {third, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert third["bound_reached"]
      refute File.exists?(Path.join(log_dir, "argv"))

      File.write!(Path.join([root, package_rel, "risks.yaml"]), "risks: [changed again]\n")
      {changed, changed_ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert changed["status"] == "missing-confirmation"
      assert changed["findings"] == []

      assert changed["requested_binding"] == %{
               "revision" => changed_ctx.revision,
               "config_fingerprint" => Kogen.Intent.config_fingerprint(config),
               "head" => changed_ctx.head,
               "route" => changed_ctx.route
             }

      assert changed["previous_audit"]["revision"] == confirming_ctx.revision
      assert length(changed["previous_audit"]["findings"]) == 3
      assert changed["budget_state"]["normal_count"] == 2
      assert changed["budget_state"]["confirmation_grant"] == "available"
      refute File.exists?(Path.join(log_dir, "argv"))
    end

    test "a clean first run gets a fresh second run on a changed revision and cannot confirm a third" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("no-findings-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "empty"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {first, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert first["status"] == "ok"
      assert first["findings"] == []

      File.rm_rf!(log_dir)
      File.mkdir_p!(log_dir)
      {same, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert same["status"] == "ok"
      assert same["reused"] == true
      refute File.exists?(Path.join(log_dir, "argv"))

      File.write!(Path.join([root, package_rel, "risks.yaml"]), "risks: []\n")
      File.rm_rf!(log_dir)
      File.mkdir_p!(log_dir)

      {second, second_ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert second["status"] == "ok"
      assert second["reused"] == false
      assert second["launched"] == true
      assert second["audited_binding"]["revision"] == second_ctx.revision
      assert second["budget_state"]["normal_count"] == 2
      assert File.exists?(Path.join(log_dir, "argv"))

      File.write!(Path.join([root, package_rel, "risks.yaml"]), "risks: [changed again]\n")
      File.rm_rf!(log_dir)
      File.mkdir_p!(log_dir)
      {third, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert third["status"] == "missing-confirmation"
      assert third["previous_audit"]["revision"] == second_ctx.revision
      refute File.exists?(Path.join(log_dir, "argv"))
    end

    test "an unparseable first run closes the normal budget for changed revisions" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("no-json-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "no-json"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {first, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert first["status"] == "unavailable"

      File.write!(Path.join([root, package_rel, "risks.yaml"]), "risks: []\n")
      File.rm_rf!(log_dir)
      File.mkdir_p!(log_dir)

      {second, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert second["status"] == "missing-confirmation"
      assert second["bound_reached"] == true
      assert second["previous_audit"]["status"] == "unavailable"
      assert second["budget_state"]["normal_count"] == 1
      refute File.exists?(Path.join(log_dir, "argv"))
    end

    test "a launch failure consumes allowance and an exact retry never dispatches again" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      System.put_env(
        "KOGEN_HARNESS",
        Path.join(@root, "test/support/shaping_audit/does-not-exist")
      )

      on_exit(fn -> System.delete_env("KOGEN_HARNESS") end)

      {failure, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert failure["status"] == "unavailable"

      log_dir = isolated_dir("after-failure-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "three-findings"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {counted, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert counted["status"] == "unavailable"
      assert counted["bound_reached"]
      assert counted["reused"]
      assert counted["budget_state"]["normal_count"] == 1
      refute File.exists?(Path.join(log_dir, "argv"))

      {confirmed, _} = run_audit(root, package_rel, config, [], launch?: true, confirm?: true)
      assert confirmed["status"] == "ok"
      assert confirmed["budget_state"]["confirmation_grant"] == "used"
      assert File.exists?(Path.join(log_dir, "argv"))
    end

    test "an unused confirmation precedes exact failed normal reuse, and failed confirmation only replays" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)
      log_dir = isolated_dir("failed-confirmation-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "no-json"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)
      {failed_normal, ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert failed_normal["status"] == "unavailable"
      assert failed_normal["budget_state"]["normal_count"] == 1
      {failed_grant, _} = run_audit(root, package_rel, config, [], launch?: true, confirm?: true)
      assert failed_grant["status"] == "unavailable"
      assert failed_grant["attempt_id"] != failed_normal["attempt_id"]
      assert failed_grant["budget_state"]["normal_count"] == 1
      assert failed_grant["budget_state"]["confirmation_grant"] == "used"
      assert length(Auditor.load_records(ctx)) == 2
      File.rm_rf!(log_dir)
      System.put_env("FAKE_AUDITOR_MESSAGE", "empty")
      {replayed, _} = run_audit(root, package_rel, config, [], launch?: true, confirm?: true)
      assert replayed["status"] == "unavailable"
      assert replayed["reused"]
      assert replayed["attempt_id"] == failed_grant["attempt_id"]
      refute File.exists?(Path.join(log_dir, "argv"))
    end

    test "completion refuses a collision and never overwrites the existing attempt evidence" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)
      ledger = Path.join(root, ".kogen/runtime/shaping-audits/complete/auditor")
      wrapper = Path.join(root, "collision-auditor")

      File.write!(wrapper, """
      #!/usr/bin/env python3
      import glob, os, sys
      reservation = glob.glob(#{inspect(ledger)} + "/*.json")[0]
      with open(reservation + ".completion", "x") as f:
          f.write("existing evidence must survive")
      os.execv(#{inspect(@fake_auditor)}, [#{inspect(@fake_auditor)}] + sys.argv[1:])
      """)

      File.chmod!(wrapper, 0o755)
      log_dir = isolated_dir("completion-collision")
      env = fake_env(log_dir, [{"KOGEN_HARNESS", wrapper}, {"FAKE_AUDITOR_MESSAGE", "empty"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)
      {result, _ctx} = run_audit(root, package_rel, config, [], launch?: true)
      assert result["status"] == "unavailable"
      assert result["reason"] =~ "exclusively persist"
      [reservation] = Path.wildcard(Path.join(ledger, "*.json"))
      assert File.read!(reservation <> ".completion") == "existing evidence must survive"
      record = File.read!(reservation) |> Jason.decode!()
      assert record["phase"] == "reserved"
      assert record["counted"]
      assert record["status"] == "unavailable"
      File.rm_rf!(log_dir)
      {retry, _} = run_audit(root, package_rel, config, [], launch?: true, confirm?: true)
      assert retry["reason"] =~ "ledger integrity"
      refute File.exists?(Path.join(log_dir, "argv"))
      assert File.read!(reservation <> ".completion") == "existing evidence must survive"
    end

    test "opts[:launch?] false reuses existing records only and launches nothing" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("no-launch-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "three-findings"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {no_launch, _} = run_audit(root, package_rel, config, [], launch?: false)
      assert no_launch["status"] == "not-run"
      refute File.exists?(Path.join(log_dir, "argv"))

      {launched, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert launched["status"] == "ok"

      File.rm_rf!(log_dir)
      File.mkdir_p!(log_dir)
      {reused, _} = run_audit(root, package_rel, config, [], launch?: false)
      assert reused["status"] == "ok"
      refute File.exists?(Path.join(log_dir, "argv"))
    end

    test "nothing kills a slow auditor; the layer waits and parses its answer" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("slow-log")

      env =
        fake_env(log_dir, [
          {"FAKE_AUDITOR_MESSAGE", "three-findings"},
          {"FAKE_AUDITOR_SLEEP_SECONDS", "5"}
        ])

      put_env(env)
      on_exit(fn -> clear_env(env) end)

      started = System.monotonic_time(:millisecond)
      {result, _} = run_audit(root, package_rel, config, [], launch?: true)
      elapsed = System.monotonic_time(:millisecond) - started

      assert result["status"] == "ok"
      assert elapsed >= 4900
      assert result["elapsed_ms"] >= 4900
    end
  end

  describe "run/3 dispositions and findings-dropped bound" do
    test "a listed finding with no disposition stays blocking; a still_open fix stays blocking" do
      finding =
        Finding.new("auditor-finding", "1", %{"layer" => "auditor", "severity" => "blocking"})

      assert Finding.open_blocking?(finding)

      dispositioned =
        finding
        |> Map.put("disposition", %{"kind" => "fixed", "text" => "patched"})
        |> Map.put("still_open", true)

      assert Finding.open_blocking?(dispositioned)
    end

    test "a run that drops findings over the bound raises blocking auditor-findings-dropped, cleared by a later clean run" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("sixty-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "sixty-findings"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {result, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert Enum.any?(result["findings"], &(&1["rule"] == "auditor-findings-dropped"))
    end
  end

  describe "run/3 write detection" do
    setup do
      root = Fixture.repo!()
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root, package_rel: package_rel, config: config}
    end

    test "a write inside .git/ (a ref) rejects the layer, naming the path", %{
      root: root,
      package_rel: package_rel,
      config: config
    } do
      log_dir = isolated_dir("write-git-ref-log")

      env =
        fake_env(log_dir, [
          {"FAKE_AUDITOR_MESSAGE", "three-findings"},
          {"FAKE_AUDITOR_WRITE", "git-ref"}
        ])

      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {result, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert result["status"] == "rejected"
      assert result["findings"] == []
    end

    test "a write to .git/index rejects the layer", %{
      root: root,
      package_rel: package_rel,
      config: config
    } do
      log_dir = isolated_dir("write-git-index-log")

      env =
        fake_env(log_dir, [
          {"FAKE_AUDITOR_MESSAGE", "three-findings"},
          {"FAKE_AUDITOR_WRITE", "git-index"}
        ])

      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {result, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert result["status"] == "rejected"
    end

    test "a write inside the checkout rejects the layer", %{
      root: root,
      package_rel: package_rel,
      config: config
    } do
      log_dir = isolated_dir("write-checkout-log")

      env =
        fake_env(log_dir, [
          {"FAKE_AUDITOR_MESSAGE", "three-findings"},
          {"FAKE_AUDITOR_WRITE", "checkout"},
          {"FAKE_AUDITOR_CHECKOUT", root}
        ])

      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {result, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert result["status"] == "rejected"
    end

    test "a write inside the report directory rejects the layer", %{
      root: root,
      package_rel: package_rel,
      config: config
    } do
      log_dir = isolated_dir("write-report-log")
      report_dir = Path.join([root, ".kogen/runtime/shaping-audits/complete"])
      File.mkdir_p!(report_dir)

      env =
        fake_env(log_dir, [
          {"FAKE_AUDITOR_MESSAGE", "three-findings"},
          {"FAKE_AUDITOR_WRITE", "report-dir"},
          {"FAKE_AUDITOR_REPORT_DIR", report_dir}
        ])

      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {result, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert result["status"] == "rejected"
    end

    test "a write outside every watched location does not reject the layer", %{
      root: root,
      package_rel: package_rel,
      config: config
    } do
      log_dir = isolated_dir("write-own-dir-log")
      own_dir = isolated_dir("own-dir-scratch")

      env =
        fake_env(log_dir, [
          {"FAKE_AUDITOR_MESSAGE", "three-findings"},
          {"FAKE_AUDITOR_WRITE", "own-dir"},
          {"FAKE_AUDITOR_OWN_DIR", own_dir}
        ])

      put_env(env)
      on_exit(fn -> clear_env(env) end)

      {result, _} = run_audit(root, package_rel, config, [], launch?: true)
      assert result["status"] == "ok"
      assert File.exists?(Path.join(own_dir, "fake-auditor-scripted-write"))
    end
  end

  describe "run/3 alongside Jev" do
    test "with Jev returning HTTP 500 and a clean deterministic layer, exactly one auditor launch happens" do
      root = Fixture.repo!()
      on_exit(fn -> File.rm_rf(root) end)
      package_rel = Fixture.add_draft!(root, "complete")
      config = write_config(root, @config_with_auditor)

      log_dir = isolated_dir("with-jev-log")
      env = fake_env(log_dir, [{"FAKE_AUDITOR_MESSAGE", "three-findings"}])
      put_env(env)
      on_exit(fn -> clear_env(env) end)

      # This test calls the auditor layer directly, as the packet allows: the
      # orchestrator calls Deterministic -> Auditor -> Jev in order, and Jev's
      # own HTTP 500 (`jev-unavailable`, scope environment) never gates the
      # auditor layer, which has already run by the time Jev is asked.
      {result, _ctx} = run_audit(root, package_rel, config, [], launch?: true)

      assert result["status"] == "ok"
      assert length(record_files(root, "complete")) == 1

      argv_calls =
        log_dir
        |> Path.join("argv")
        |> File.exists?()

      assert argv_calls
    end
  end

  test "main/2 removes every auditor materialization outcome" do
    own_prefix = "kogen-audit-#{:erlang.phash2(self())}-"

    own_tmp_entries = fn ->
      Path.wildcard(Path.join(System.tmp_dir!(), "kogen-audit-*"))
      |> Enum.filter(&(Path.basename(&1) |> String.starts_with?(own_prefix)))
    end

    outcomes = [
      [],
      [{"FAKE_AUDITOR_MESSAGE", "no-json"}],
      [
        {"FAKE_AUDITOR_MESSAGE", "empty"},
        {"FAKE_AUDITOR_WRITE", "checkout"}
      ],
      [{"KOGEN_HARNESS", Path.join(System.tmp_dir!(), "missing-auditor-executable")}]
    ]

    for overrides <- outcomes do
      root = Fixture.repo!(second_commit: false, working_tree: false, prior_failures: false)
      Fixture.add_draft!(root, "complete")
      on_exit(fn -> File.rm_rf!(root) end)

      env = Fixture.audit_env!(root)
      env_pairs = [{"FAKE_AUDITOR_CHECKOUT", root} | overrides]
      put_env(env_pairs)
      on_exit(fn -> clear_env(env_pairs) end)
      before = own_tmp_entries.()

      assert Kogen.ShapingAudit.main(["--auditor", "complete"], root: root, env: env) in [0, 1]
      assert own_tmp_entries.() == before
    end
  end

  describe "the setup guard" do
    test "KOGEN_ROLE=auditor refuses mix kogen.codex management commands" do
      System.put_env("KOGEN_ROLE", "auditor")
      on_exit(fn -> System.delete_env("KOGEN_ROLE") end)

      assert_raise RuntimeError, ~r/managed roles cannot run setup/, fn ->
        Kogen.Codex.management_allowed!("install")
      end
    end

    test "KOGEN_ROLE=auditor refuses mix kogen.claude management commands" do
      System.put_env("KOGEN_ROLE", "auditor")
      on_exit(fn -> System.delete_env("KOGEN_ROLE") end)

      assert_raise RuntimeError, ~r/managed roles cannot run setup/, fn ->
        Kogen.ClaudeCode.management_allowed!("install")
      end
    end
  end

  describe "source scan" do
    test "no file under lib/kogen/shaping_audit starts a harness executable itself" do
      offenders =
        Path.wildcard(Path.join(@root, "lib/kogen/shaping_audit/**/*.ex"))
        |> Enum.filter(fn path ->
          text = File.read!(path)

          (text =~ ~r/System\.cmd\(\s*"(codex|claude)"/ or
             text =~ ~r/Port\.open\(.*(codex|claude)/) and
            not (path =~ "materialization.ex")
        end)

      assert offenders == [],
             "these files under lib/kogen/shaping_audit appear to launch a harness executable directly: #{inspect(offenders)}"
    end
  end
end
