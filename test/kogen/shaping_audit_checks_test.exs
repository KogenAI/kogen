Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)
Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.ShapingAuditChecksTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.VerificationPlan

  alias Kogen.ShapingAudit.{
    Deterministic,
    Finding,
    Fixture,
    HeadlessInput,
    Materialization,
    Package,
    Questions,
    Report
  }

  alias Kogen.VerificationPolicy

  @root Path.expand("../..", __DIR__)

  defp repo!(opts \\ []) do
    root = Fixture.repo!(opts)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp add!(root, slug, opts \\ []) do
    rel = Fixture.add_draft!(root, slug, opts)
    on_exit(fn -> File.rm_rf!(Path.join(root, rel)) end)
    rel
  end

  defp report!(root, slug, opts \\ []) do
    add!(root, slug)

    assert Kogen.ShapingAudit.main(
             ["--auditor", slug],
             [root: root, env: Fixture.audit_env!(root)] ++ opts
           ) in [
             0,
             1
           ]

    {:ok, rel} = Package.locate(root, slug)
    {:ok, loaded} = Package.load(root, rel)
    {:ok, report} = Report.read(root, slug, loaded.revision)
    report
  end

  defp ids(report), do: report["findings"] |> Enum.map(& &1["id"]) |> Enum.sort()

  defp ctx!(root, slug, opts \\ []) do
    rel = add!(root, slug, opts)
    {:ok, %{files: files}} = Package.load(root, rel)
    {:ok, mat} = Materialization.create(root, rel, files)
    on_exit(fn -> Materialization.remove(mat) end)

    parse = fn key ->
      case YamlElixir.read_from_string(files[key]) do
        {:ok, value} -> value
        _ -> nil
      end
    end

    %{
      root: root,
      slug: slug,
      package_rel: rel,
      files: files,
      materialization: mat.dir,
      intent: parse.("intent.yaml"),
      scenarios: parse.("scenarios.yaml"),
      questions: Questions.parse(files["questions.md"]),
      opts: []
    }
  end

  test "proof-defects: every proof predicate fails, never only the first" do
    root = repo!()
    ctx = ctx!(root, "proof-defects")
    result = Deterministic.run(ctx)

    findings = result["findings"]

    assert Enum.sort(Enum.map(findings, & &1["id"])) == [
             "paid-reason-malformed not a valid reason",
             "proof-selector-missing test/gone_test.exs",
             "proof-selector-missing test/stray_test.exs",
             "unguarded-affected-path lib/unguarded.ex",
             "unknown-target live-extra",
             "unsupported-selector ../x_test.exs",
             "unsupported-selector /abs/x_test.exs",
             "unsupported-selector test/**",
             "unsupported-selector test/a_test.exs:3"
           ]

    assert Enum.all?(findings, &(&1["severity"] == "blocking" and &1["disputable"] == false))

    assert Enum.find(findings, &(&1["id"] == "unguarded-affected-path lib/unguarded.ex"))["paths"] ==
             [
               "lib/unguarded.ex"
             ]

    {:ok, catalog} = VerificationPlan.load(ctx.materialization)

    assert {:error, _} =
             VerificationPlan.build(
               ctx.scenarios,
               ctx.intent["may_change_guarded_paths"],
               catalog,
               ctx.materialization
             )
  end

  test "complete: no finding, readiness ready, and build/4 accepts the same HEAD and package" do
    root = repo!()
    add!(root, "complete")
    report = report!(root, "complete")
    assert report["findings"] == []
    assert report["readiness"] == "ready"
    assert report["layers"]["deterministic"]["status"] == "ok"

    {:ok, rel} = Package.locate(root, "complete")
    {:ok, loaded} = Package.load(root, rel)
    {:ok, materialization} = Materialization.create(root, rel, loaded.files)

    on_exit(fn -> Materialization.remove(materialization) end)
    {:ok, catalog} = VerificationPlan.load(materialization.dir)
    {:ok, scenarios} = YamlElixir.read_from_string(loaded.files["scenarios.yaml"])
    {:ok, intent} = YamlElixir.read_from_string(loaded.files["intent.yaml"])

    assert {:ok, _} =
             VerificationPlan.build(
               scenarios,
               intent["may_change_guarded_paths"],
               catalog,
               materialization.dir
             )
  end

  test "proof findings are empty exactly when build/4 accepts, on every fixture Draft" do
    root = repo!()

    names =
      Path.wildcard(Path.join(@root, "test/support/shaping_audit/drafts/*"))
      |> Enum.map(&Path.basename/1)
      |> Enum.reject(&(&1 in ["invalid", "non-regular"]))

    assert Enum.sort(names) ==
             Path.wildcard(Path.join(@root, "test/support/shaping_audit/drafts/*"))
             |> Enum.map(&Path.basename/1)
             |> Enum.reject(&(&1 in ["invalid", "non-regular"]))
             |> Enum.sort()

    for name <- names do
      ctx = ctx!(root, name)
      {:ok, catalog} = VerificationPlan.load(ctx.materialization)

      errors =
        VerificationPlan.proof_errors(
          ctx.scenarios,
          ctx.intent["may_change_guarded_paths"],
          catalog,
          ctx.materialization,
          added: List.wrap(get_in(ctx.intent, ["catalog_changes", "add"]))
        )

      added = List.wrap(get_in(ctx.intent, ["catalog_changes", "add"]))

      build_result =
        VerificationPlan.build(
          ctx.scenarios,
          ctx.intent["may_change_guarded_paths"],
          catalog,
          ctx.materialization,
          added: added
        )

      assert errors == [] == match?({:ok, _}, build_result), "#{name}: proof parity mismatch"
    end

    malformed_root = repo!()
    malformed = ctx!(malformed_root, "complete")
    scenario = hd(malformed.scenarios)

    malformed_proof =
      Map.merge(scenario["proof"], %{"offline" => [], "affected_paths" => [], "base" => "other"})

    malformed_scenario = Map.put(scenario, "proof", malformed_proof)
    {:ok, malformed_catalog} = VerificationPlan.load(malformed.materialization)

    malformed_errors =
      VerificationPlan.proof_errors(
        [malformed_scenario],
        malformed.intent["may_change_guarded_paths"],
        malformed_catalog,
        malformed.materialization
      )

    assert {"verified-by-invalid", _} =
             Enum.find(malformed_errors, &(&1 |> elem(0) == "verified-by-invalid"))

    assert {:error, _} =
             VerificationPlan.build(
               [malformed_scenario],
               malformed.intent["may_change_guarded_paths"],
               malformed_catalog,
               malformed.materialization
             )
  end

  test "controller-read: the Codex policy script is flagged; the catalog and the bootstrap scripts are not" do
    root = repo!()
    add!(root, "controller-read")

    assert ids(report!(root, "controller-read")) == [
             "controller-read-path .codex/hooks/verification_policy.py"
           ]

    assert hd(report!(root, "controller-read")["findings"])["disputable"] == false

    add!(root, "catalog-added")
    assert ids(report!(root, "catalog-added")) == []

    assert VerificationPolicy.controller_paths() == [
             ".codex/hooks.json",
             ".codex/hooks/verification_policy.py"
           ]

    policy_root =
      Path.join(System.tmp_dir!(), "kogen-policy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(policy_root, ".codex/hooks"))
    File.cp!(Path.join(root, ".codex/hooks.json"), Path.join(policy_root, ".codex/hooks.json"))

    File.cp!(
      Path.join(root, ".codex/hooks/verification_policy.py"),
      Path.join(policy_root, ".codex/hooks/verification_policy.py")
    )

    on_exit(fn -> File.rm_rf!(policy_root) end)
    assert :ok = VerificationPolicy.preflight(["check"], policy_root)
    File.rm!(Path.join(policy_root, ".codex/hooks.json"))
    assert {:error, _} = VerificationPolicy.preflight(["check"], policy_root)
    File.cp!(Path.join(root, ".codex/hooks.json"), Path.join(policy_root, ".codex/hooks.json"))
    File.rm!(Path.join(policy_root, ".codex/hooks/verification_policy.py"))
    assert {:error, _} = VerificationPolicy.preflight(["check"], policy_root)
  end

  test "no controller path is a string literal under lib/kogen/shaping_audit" do
    source =
      Path.wildcard(Path.join(@root, "lib/kogen/shaping_audit/**/*.ex"))
      |> Enum.map_join("\n", &File.read!/1)

    refute source =~ ".codex/hooks.json"
    refute source =~ "verification_policy.py"
    refute source =~ "claude_code/settings.json"
  end

  test "a committed catalog that does not match the committed Makefile gives repository-invalid" do
    root = repo!(catalog_mismatch: true)
    add!(root, "complete")
    report = report!(root, "complete")
    assert ids(report) == ["repository-invalid"]
    finding = hd(report["findings"])
    assert finding["scope"] == "environment"
    assert finding["disputable"] == false
    assert finding["paths"] == []
    {:ok, rel} = Package.locate(root, "complete")
    {:ok, loaded} = Package.load(root, rel)
    {:ok, materialization} = Materialization.create(root, rel, loaded.files)
    on_exit(fn -> Materialization.remove(materialization) end)
    assert {:error, reason} = VerificationPlan.load(materialization.dir)
    assert finding["message"] == reason

    assert report["readiness"] == "not_ready" and
             report["layers"]["deterministic"]["status"] == "unavailable"
  end

  test "the working tree's stray test and uncommitted target never reach any rule" do
    root = repo!()
    ctx = ctx!(root, "proof-defects")
    refute File.exists?(Path.join(ctx.materialization, "test/stray_test.exs"))
    refute File.read!(Path.join(ctx.materialization, "Makefile")) =~ "live-extra"

    assert "proof-selector-missing test/stray_test.exs" in ids(%{
             "findings" => Deterministic.run(ctx)["findings"]
           })

    assert "unknown-target live-extra" in ids(%{"findings" => Deterministic.run(ctx)["findings"]})
  end

  test "ledger-flawed: a catalogued test file with the ledger unguarded is only an advisory ledger-closure" do
    report = report!(repo!(), "ledger-flawed")
    assert ids(report) == ["ledger-closure"]
    finding = hd(report["findings"])
    assert finding["severity"] == "advisory"
    refute Finding.open_blocking?(finding)
    assert finding["disputable"] == false
    assert finding["paths"] == ["test/a_test.exs", "priv/kogen/test-reliability.yaml"]
    assert finding["message"] =~ "guarding"
    assert finding["message"] =~ "harmless"
  end

  test "ledger-unstated: a deleted catalogued test with the remediation file unguarded is only advisory" do
    report = report!(repo!(), "ledger-unstated")
    assert ids(report) == ["ledger-row-update-unstated"]
    assert hd(report["findings"])["severity"] == "advisory"
    refute Finding.open_blocking?(hd(report["findings"]))
    assert hd(report["findings"])["paths"] == ["priv/kogen/test-reliability-remediation.yaml"]
    refute hd(report["findings"])["message"] =~ ~r/refresh|\.py/
  end

  test "ledger findings never block the audit" do
    root = repo!()
    add!(root, "ledger-flawed")

    assert Kogen.ShapingAudit.main(["--auditor", "ledger-flawed"],
             root: root,
             env: Fixture.audit_env!(root)
           ) == 0
  end

  test "ledger-rename, ledger-both and ledger-body get no ledger finding" do
    for slug <- ["ledger-rename", "ledger-both", "ledger-body"] do
      report = report!(repo!(), slug)
      refute Enum.any?(report["findings"], &String.starts_with?(&1["id"], "ledger-"))
    end

    root = repo!()
    add!(root, "ledger-unstated")
    scenario = Path.join(root, ".kogen/intents/drafts/ledger-unstated/scenarios.yaml")

    File.write!(
      scenario,
      String.replace(File.read!(scenario), "Delete the catalogued test", "Keep the address of")
    )

    assert Kogen.ShapingAudit.main(["--auditor", "ledger-unstated"],
             root: root,
             env: Fixture.audit_env!(root)
           ) ==
             0

    {:ok, rel} = Package.locate(root, "ledger-unstated")
    {:ok, loaded} = Package.load(root, rel)
    {:ok, revised} = Report.read(root, "ledger-unstated", loaded.revision)
    refute Enum.any?(revised["findings"], &String.starts_with?(&1["id"], "ledger-"))
  end

  test "live-owner: an edited, unselected live owner blocks with edited-live-owner-unselected" do
    report = report!(repo!(), "live-owner")
    assert ids(report) == ["edited-live-owner-unselected live-x"]
    assert hd(report["findings"])["disputable"] == false
    assert hd(report["findings"])["paths"] == ["test/live_x_test.exs"]
  end

  test "paid-path-unproven: the owner and prepare branches block; a probe or proving-run record naming the target proves it" do
    assert ids(report!(repo!(), "paid-unproven")) == ["paid-path-unproven live-x"]
    assert ids(report!(repo!(), "paid-proven")) == []
    root = repo!()
    add!(root, "paid-unproven")

    log =
      Path.join(root, ".kogen/intents/drafts/paid-unproven/evidence/proving-run-1/logs/run.log")

    File.mkdir_p!(Path.dirname(log))
    File.write!(log, "live-x passed")
    assert ids(report!(root, "paid-unproven")) == []
    File.write!(log, "other target passed")
    assert ids(report!(root, "paid-unproven")) == ["paid-path-unproven live-x"]

    prepare_root = repo!(prepare: true)
    add!(prepare_root, "paid-overbroad")

    probe =
      Path.join(
        prepare_root,
        ".kogen/intents/drafts/paid-overbroad/evidence/probe-live-x/RESULT.md"
      )

    File.rm!(probe)
    scenario = Path.join(prepare_root, ".kogen/intents/drafts/paid-overbroad/scenarios.yaml")

    File.write!(
      scenario,
      String.replace(
        File.read!(scenario),
        "test/support/shaping_audit/fixture.ex",
        "test/support/live_x_driver.py"
      )
    )

    assert Kogen.ShapingAudit.main(["--auditor", "paid-overbroad"],
             root: prepare_root,
             env: Fixture.audit_env!(prepare_root)
           ) == 1

    {:ok, pre_rel} = Package.locate(prepare_root, "paid-overbroad")
    {:ok, pre_loaded} = Package.load(prepare_root, pre_rel)

    {:ok, pre_report} =
      Report.read(prepare_root, "paid-overbroad", pre_loaded.revision)

    assert ids(pre_report) == [
             "paid-path-unproven live-x",
             "paid-target-overbroad paid-overbroad-case"
           ]

    assert Enum.find(pre_report["findings"], &(&1["id"] == "paid-path-unproven live-x"))["paths"] ==
             ["test/support/live_x_driver.py"]

    default_root = repo!()
    add!(default_root, "paid-overbroad")

    default_probe =
      Path.join(
        default_root,
        ".kogen/intents/drafts/paid-overbroad/evidence/probe-live-x/RESULT.md"
      )

    File.rm!(default_probe)

    assert Kogen.ShapingAudit.main(["--auditor", "paid-overbroad"],
             root: default_root,
             env: Fixture.audit_env!(default_root)
           ) == 1

    {:ok, default_rel} = Package.locate(default_root, "paid-overbroad")
    {:ok, default_loaded} = Package.load(default_root, default_rel)
    {:ok, default_report} = Report.read(default_root, "paid-overbroad", default_loaded.revision)
    assert ids(default_report) == ["paid-target-overbroad paid-overbroad-case"]
  end

  test "paid-overbroad is flagged; paid-provider-only and paid-shared are not" do
    assert ids(report!(repo!(), "paid-overbroad")) == [
             "paid-target-overbroad paid-overbroad-case"
           ]

    assert hd(report!(repo!(), "paid-overbroad")["findings"])["message"] =~
             "introduce the cheaper check"

    refute hd(report!(repo!(), "paid-overbroad")["findings"])["message"] =~ "ask the Shaper"

    assert ids(report!(repo!(), "paid-provider-only")) == []
    assert ids(report!(repo!(), "paid-shared")) == []
  end

  test "a disposition clears a disputable finding but never a mechanical one" do
    root = repo!()
    add!(root, "paid-overbroad")
    path = Path.join(root, ".kogen/intents/drafts/paid-overbroad/questions.md")

    File.write!(
      path,
      File.read!(path) <>
        "\n## Dispositions\npaid-target-overbroad paid-overbroad-case: not a defect — the full observable is needed\n"
    )

    assert Kogen.ShapingAudit.main(["--auditor", "paid-overbroad"],
             root: root,
             env: Fixture.audit_env!(root)
           ) ==
             0

    {:ok, rel} = Package.locate(root, "paid-overbroad")
    {:ok, loaded} = Package.load(root, rel)
    {:ok, report} = Report.read(root, "paid-overbroad", loaded.revision)
    assert report["readiness"] == "ready"

    assert hd(report["findings"])["disposition"] == %{
             "kind" => "not-a-defect",
             "reason" => "the full observable is needed"
           }

    mechanical_root = repo!()
    add!(mechanical_root, "proof-defects")

    File.write!(
      Path.join(mechanical_root, ".kogen/intents/drafts/proof-defects/questions.md"),
      "## Dispositions\nproof-selector-missing test/stray_test.exs: not a defect — accepted\n"
    )

    assert Kogen.ShapingAudit.main(["--auditor", "proof-defects"],
             root: mechanical_root,
             env: Fixture.audit_env!(mechanical_root)
           ) == 1
  end

  test "stale: a changed line and a gone identifier are stale-anchor; a new identifier is not" do
    report = report!(repo!(), "stale")
    assert ids(report) == ["stale-anchor cited_bytes", "stale-anchor lib/a.ex:3"]
    assert Enum.all?(report["findings"], &(&1["disputable"] == true))
  end

  test "stale-disputed: the disposition clears the stale anchor" do
    report = report!(repo!(), "stale-disputed")
    assert ids(report) == ["stale-anchor cited_bytes"]
    assert report["readiness"] == "ready"

    assert hd(report["findings"])["disposition"] == %{
             "kind" => "not-a-defect",
             "reason" => "the Draft deletes it"
           }
  end

  test "stale-unavailable: a baseline that is not a local commit" do
    report = report!(repo!(), "stale-unavailable")
    assert ids(report) == ["stale-anchor-baseline-unavailable"]
    assert hd(report["findings"])["message"] =~ "shaped_against"
  end

  test "long-title and no-subject: mechanical title and subject rules" do
    long = report!(repo!(), "long-title")
    assert ids(long) == ["commit-subject-format", "title-format"]
    assert Enum.all?(long["findings"], &(&1["disputable"] == false))

    assert Enum.find(long["findings"], &(&1["id"] == "title-format"))["message"] =~
             "more than 50 characters"

    assert Enum.find(long["findings"], &(&1["id"] == "title-format"))["message"] =~
             "trailing period"

    assert Enum.find(long["findings"], &(&1["id"] == "commit-subject-format"))["message"] =~
             "more than 72 characters"

    assert Enum.find(long["findings"], &(&1["id"] == "commit-subject-format"))["message"] =~
             "lowercase"

    none = report!(repo!(), "no-subject")
    assert ids(none) == ["commit-subject-format"]
    assert hd(none["findings"])["message"] =~ "commit_subject is missing"
    root = repo!()
    add!(root, "complete")
    intent_path = Path.join(root, ".kogen/intents/drafts/complete/intent.yaml")
    text = File.read!(intent_path)

    File.write!(
      intent_path,
      String.replace(
        text,
        "commit_subject: Add a fixture feature",
        "commit_subject: |-\n  Add a fixture feature\n  With a second line"
      )
    )

    assert Kogen.ShapingAudit.main(["--auditor", "complete"],
             root: root,
             env: Fixture.audit_env!(root)
           ) == 1

    {:ok, rel} = Package.locate(root, "complete")
    {:ok, loaded} = Package.load(root, rel)
    {:ok, multiline} = Report.read(root, "complete", loaded.revision)
    assert ids(multiline) == ["commit-subject-format"]
    assert hd(multiline["findings"])["message"] =~ "more than one line"
    refute Enum.any?(ids(report!(repo!(), "complete")), &(&1 == "title-format"))
  end

  test "history: advisory prior-failures from real-shaped records, bounded" do
    root = repo!(oversized_record: true)
    add!(root, "history")
    reader = Agent.start_link(fn -> [] end) |> elem(1)

    read = fn path ->
      Agent.update(reader, &[path | &1])
      File.read(path)
    end

    assert Kogen.ShapingAudit.main(["--auditor", "history"],
             root: root,
             env: Fixture.audit_env!(root),
             read: read
           ) == 0

    {:ok, rel} = Package.locate(root, "history")
    {:ok, loaded} = Package.load(root, rel)
    {:ok, report} = Report.read(root, "history", loaded.revision)
    read_paths = Agent.get(reader, & &1)

    assert ids(report) == ["prior-failures"]
    assert hd(report["findings"])["severity"] == "advisory"
    assert hd(report["findings"])["message"] =~ "FIXTUREBUILD000000000001"
    assert hd(report["findings"])["message"] =~ "FIXTUREBUILD000000000002"

    assert hd(report["findings"])["message"] =~
             "Candidate changed paths outside Approved guards: lib/b.ex"

    assert report["readiness"] == "ready"
    refute Enum.any?(read_paths, &String.contains?(&1, "FIXTUREBUILD000000000003/record.json"))
  end

  test "invalid: an unparseable scenarios.yaml blocks with package-invalid" do
    root = repo!()
    add!(root, "invalid")

    assert Kogen.ShapingAudit.main(["--auditor", "invalid"],
             root: root,
             env: Fixture.audit_env!(root)
           ) == 1

    {:ok, rel} = Package.locate(root, "invalid")
    {:ok, loaded} = Package.load(root, rel)
    {:ok, report} = Report.read(root, "invalid", loaded.revision)
    assert ids(report) == ["package-invalid"]
    assert hd(report["findings"])["disputable"] == false
    assert report["readiness"] == "not_ready"
  end

  # -- recorded inputs (input-not-recorded, input-recorded-twice) ---------------

  @input_id "in-0002-e4f69869"

  defp with_answer(ctx, answer) do
    text = "## Shaper answers\n\n1. #{answer}\n\n## Settled\n\nNo open questions.\n"
    %{ctx | files: Map.put(ctx.files, "questions.md", text), questions: Questions.parse(text)}
  end

  defp input_ids(slug) do
    root = repo!()
    ctx = ctx!(root, slug)

    ctx =
      if slug == "inputs-recorded" do
        bytes = Map.fetch!(ctx.files, "evidence/inputs/0002.md")
        with_answer(ctx, HeadlessInput.frame(@input_id, bytes))
      else
        ctx
      end

    findings = Deterministic.run(ctx)["findings"]
    {Enum.filter(findings, &String.starts_with?(&1["rule"], "input-")), findings}
  end

  test "the fixture input's id is derived from its exact bytes" do
    bytes =
      File.read!(
        Path.join(
          @root,
          "test/support/shaping_audit/drafts/inputs-recorded/evidence/inputs/0002.md"
        )
      )

    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert "in-0002-" <> String.slice(digest, 0, 8) == @input_id
  end

  test "input-not-recorded passes only with the exact reversible payload under Shaper answers" do
    {[], _findings} = input_ids("inputs-recorded")

    assert {[finding], _findings} = input_ids("inputs-missing")
    assert finding["id"] == "input-not-recorded #{@input_id}"
    assert finding["severity"] == "blocking"
    assert finding["message"] =~ "[input #{@input_id}]"
    assert Finding.open_blocking?(finding)
  end

  test "token-only and paraphrased recording frames produce blocking deterministic findings" do
    root = repo!()
    ctx = ctx!(root, "inputs-recorded")
    bytes = Map.fetch!(ctx.files, "evidence/inputs/0002.md")

    token_only = with_answer(ctx, "[input #{@input_id}] Make the button green.")

    paraphrase =
      with_answer(ctx, HeadlessInput.frame(@input_id, "Choose a similar green shade.\n"))

    for negative <- [token_only, paraphrase] do
      findings = Deterministic.run(negative)["findings"]
      finding = Enum.find(findings, &(&1["id"] == "input-not-recorded #{@input_id}"))
      assert Finding.open_blocking?(finding)
    end

    exact = with_answer(ctx, HeadlessInput.frame(@input_id, bytes))

    refute Enum.any?(
             Deterministic.run(exact)["findings"],
             &String.starts_with?(&1["rule"], "input-")
           )
  end

  test "input-recorded-twice blocks a second entry carrying the same token" do
    {input_findings, _findings} = input_ids("inputs-twice")
    duplicate = Enum.find(input_findings, &(&1["id"] == "input-recorded-twice #{@input_id}"))
    unrecorded = Enum.find(input_findings, &(&1["id"] == "input-not-recorded #{@input_id}"))
    assert Finding.open_blocking?(duplicate)
    assert Finding.open_blocking?(unrecorded)
  end

  test "a token outside Shaper answers does not record an input" do
    root = repo!()
    ctx = ctx!(root, "inputs-recorded")

    questions =
      "## Settled\n\n1. [input #{@input_id}] not an answer\n\n## Shaper answers\n\n1. \"green\"\n"

    ctx = %{
      ctx
      | files: Map.put(ctx.files, "questions.md", questions),
        questions: Questions.parse(questions)
    }

    ids = ctx |> Deterministic.run() |> Map.fetch!("findings") |> Enum.map(& &1["id"])
    assert "input-not-recorded #{@input_id}" in ids
  end

  test "the brief at evidence/brief.md needs no token and packages without inputs are unchanged" do
    assert {[], _findings} = input_ids("inputs-brief-only")
    assert {[], _findings} = input_ids("complete")
  end
end
