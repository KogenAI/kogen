ExUnit.start(autorun: System.get_env("STAGED_OBSERVER_CONTROL") == nil)
Code.require_file(Path.expand("test/support/integration_helpers.ex", File.cwd!()))

defmodule StagedIntentBuildsExercise do
  use ExUnit.Case
  alias Kogen.Integration.{Helpers, FakeProvider}
  alias Kogen.Intent

  defp put(c, p, bytes) do
    p = Path.join(c.repo, p)
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, bytes)
  end

  defp git(c, args) do
    {out, 0} = Helpers.git!(c, args)
    String.trim(out)
  end

  defp script(c, actions), do: FakeProvider.append(c.server, actions)
  defp f(n, a), do: {:function, n, a}
  defp write(s), do: f("write_file", %{"path" => "app.txt", "content" => s <> "\n"})
  defp finish, do: f("finish", %{"summary" => "verify current approved work"})
  defp approve_review, do: f("submit_review", %{"verdict" => "approve", "findings" => []})
  defp requests(c), do: FakeProvider.provider_requests(c.server)
  defp input(r), do: r.json["input"]
  defp read_json(p), do: JSON.decode!(File.read!(p))

  # The factory has already called native init. Bound observation to this Shape
  # invocation, and inspect only its first request, before any candidate echo.
  def shape_requests_since(retained, before), do: Enum.drop(retained, before)
  def shape_guidance([first | _]), do: JSON.encode!(first.json) =~ "## Stages"
  def shape_guidance([]), do: false

  # A custody refusal is not proof that stage lint ran.
  def invalid_plan_refused(status, out) do
    status == 1 and out =~ "intent/lint" and String.downcase(out) =~ "stage" and
      not (out =~ "source_provenance_changed")
  end

  defp trace(c) do
    case File.read(Path.join(c.root, "trace.ndjson")) do
      {:ok, bytes} -> String.split(bytes, "\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  defp custody(c) do
    %{
      head: git(c, ["rev-parse", "HEAD"]),
      index: Base.encode64(File.read!(Path.join(c.repo, ".git/index"))),
      approval: File.read(Intent.approval_path(c.repo, "fixture")),
      app: File.read!(Path.join(c.repo, "app.txt"))
    }
  end

  defp approve(c) do
    {card, status} = Helpers.run_kogen(c, ["intent", "approve", "fixture"])
    assert status == 5, card
    [_, hash] = Regex.run(~r/SHA-256: ([a-f0-9]{64})/, card)
    {out, 0} = Helpers.run_kogen(c, ["intent", "approve", "fixture", hash])
    {card, hash, out}
  end

  @tag timeout: 220_000
  test "record installed native behavior" do
    spec = read_json(System.fetch_env!("STAGED_INPUT"))
    mode = System.fetch_env!("STAGED_MODE")
    suite = Helpers.setup_suite!()

    try do
      c = Helpers.project!(suite, [], staged_intent: false)
      c = %{c | env: Map.put(c.env, "STAGED_TRACE", Path.join(c.root, "trace.ndjson"))}

      try do
        receipt = exercise(c, spec, mode)
        File.write!(System.fetch_env!("STAGED_RECEIPT"), JSON.encode!(receipt))
      after
        Helpers.cleanup_case(c)
      end
    after
      Helpers.cleanup_suite(suite)
    end
  end

  defp exercise(c, spec, mode) do
    # The factory really seeds baseline app.txt, native init and a default approval.
    git(c, ["add", ".kogen/intents/fixture", "features/steps/integration_steps.js"])
    git(c, ["commit", "-qm", "Commit seed fixture"])
    File.rm!(Path.join(c.repo, Intent.intent_md("fixture")))
    File.rm!(Path.join(c.repo, Intent.feature("fixture")))
    File.rmdir!(Path.join(c.repo, Intent.dir("fixture")))
    git(c, ["add", "-u"])
    git(c, ["commit", "-qm", "Remove seed package before native Shape"])
    File.rm!(Intent.approval_path(c.repo, "fixture"))
    config = File.read!(Path.join(c.repo, ".kogen/project.yaml"))

    # Reuse native init's real runner/models, with explicit local fixture commands.
    config = String.replace(config, "setup: []", "setup:\n    - '\"$KOGEN_NODE\" features/steps/gate.cjs setup'")
    config = String.replace(config, "checks: []", "checks:\n    - name: fixture-check\n      run: '\"$KOGEN_NODE\" features/steps/gate.cjs configured'")
    put(c, ".kogen/project.yaml", config)

    put(c, "features/steps/gate.cjs", "const fs=require('node:fs');const k=process.argv[2],s=fs.readFileSync('app.txt','utf8').trim();const ok=k==='stage-one'?s==='phase-one':k==='stage-two'?s==='phase-two':true;fs.appendFileSync(process.env.STAGED_TRACE,JSON.stringify({kind:k,state:s,status:ok?0:1})+'\\n');if(!ok){console.error(k+' failed: '+s);process.exitCode=1;}\n")
    git(c, ["add", ".kogen/project.yaml", "features/steps/gate.cjs"])
    git(c, ["commit", "-qm", "Configure deterministic local gates"])
    plan = spec["plan"]

    md = "# Complete staged fixture\n\nSlug: fixture\nModel: .kogen/intents/fixture/model.qnt invariants=Safe seed=23 samples=10 steps=5\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/stage_fixture.js\n- features/steps/gate.cjs\n\nImplement the complete local rewrite analogue.\n\n## Decisions\n- Keep one whole delivery. (source: request)\n\n## Source comparison\n- addressed: original staged-build request; local analogue only, no Go import.\n\n## Tests\n- whole output: real app file (scenario)\n\n## Feasibility\n- none\n"
    md = md <> if(mode == "single", do: "", else: "\n## Stages\n```json\n" <> JSON.encode!(plan) <> "\n```\n")
    feature = "Feature: Complete local rewrite\n  Scenario: Deliver all work\n    Then the local rewrite is complete\n"
    step = "const {Then}=require('@cucumber/cucumber');const fs=require('node:fs');const assert=require('node:assert/strict');Then('the local rewrite is complete',()=>{const s=fs.readFileSync('app.txt','utf8').trim();fs.appendFileSync(process.env.STAGED_TRACE,JSON.stringify({kind:'acceptance',state:s,status:['final','final-reviewed'].includes(s)?0:1})+'\\n');assert.ok(['final','final-reviewed'].includes(s),'Go migration not implemented: lib remains (local analogue): '+s);});\n"
    model = "module fixture { var n: int action init = n' = 0 action step = n' = n val Safe = n == 0 }\n"

    package = [
      %{"path" => Intent.intent_md("fixture"), "content" => md},
      %{"path" => Intent.feature("fixture"), "content" => feature},
      %{"path" => Intent.model_path("fixture"), "content" => model},
      %{"path" => "features/steps/stage_fixture.js", "content" => step}
    ]

    request_path = Path.join(c.root, "original-request.md")
    File.write!(request_path, spec["request"])
    # Exercise native discovery before submission, then acknowledge identical red.
    discovery = [f("read_file", %{"path" => "app.txt"}), f("read_file", %{"path" => ".kogen/project.yaml"})]
    script(c, discovery ++ List.duplicate(f("submit", %{"files" => package}), 2))
    shape_before = length(requests(c))
    {shape_out, shape_status} = Helpers.run_kogen(c, ["intent", "shape", "fixture", request_path])
    assert shape_status == 0, shape_out <> "\nNative tool feedback: " <> JSON.encode!(FakeProvider.tool_outputs(c.server))
    shape_requests = shape_requests_since(requests(c), shape_before)
    {card, hash, _} = approve(c)
    start = custody(c)
    File.write!(Path.join(c.root, "trace.ndjson"), "")

    common = %{
      shape_ok: shape_status == 0,
      shape_request_exact: Enum.any?(shape_requests, &(FakeProvider.input_text(&1) =~ spec["request"])),
      # Later requests contain our candidate. Only the first can prove native guidance.
      shape_guidance: shape_guidance(shape_requests),
      card_plan: Enum.all?(plan["stages"], &(card =~ &1["title"] and card =~ &1["goal"] and Enum.all?(&1["checks"], fn cmd -> card =~ cmd end)))
    }

    cond do
      String.starts_with?(mode, "invalid:") ->
        bad = case String.replace_prefix(mode, "invalid:", "") do
          "empty" -> %{plan | "stages" => []}
          "duplicate" -> %{plan | "stages" => [hd(plan["stages"]), hd(plan["stages"])]}
          "blank-check" -> put_in(plan, ["stages", Access.at(0), "checks"], [""])
          "version" -> %{plan | "version" => 99}
        end

        # This package is deliberately never shaped or approved: the supported
        # legacy route has no source receipt to invalidate. Do not remove, forge
        # or rebind the real Shape receipt or modify its approved package.
        slug = "invalid-fixture"
        source = Kogen.SourceProvenance.path(c.repo, "fixture")
        legacy_source = Kogen.SourceProvenance.path(c.repo, slug)
        assert File.lstat(Path.join(c.repo, Intent.dir(slug))) == {:error, :enoent}
        assert File.lstat(legacy_source) == {:error, :enoent}
        assert File.lstat(Intent.approval_path(c.repo, slug)) == {:error, :enoent}

        legacy = %{
          Intent.intent_md(slug) => md |> String.replace("Slug: fixture\n", "Slug: #{slug}\n") |> String.replace(".kogen/intents/fixture/", Intent.dir(slug) <> "/") |> String.replace(JSON.encode!(plan), JSON.encode!(bad)),
          Intent.feature(slug) => feature,
          Intent.model_path(slug) => model
        }
        Enum.each(legacy, fn {p, bytes} -> put(c, p, bytes) end)
        watched = Map.keys(legacy) ++ Enum.map(package, & &1["path"]) ++ [Path.relative_to(source, c.repo)]
        snapshot = fn -> Map.new(watched, fn p -> {p, File.read!(Path.join(c.repo, p))} end) end
        before = snapshot.()
        n = length(requests(c))
        {out, status} = Helpers.run_kogen(c, ["intent", "approve", slug])

        Map.merge(common, %{
          invalid_refused: invalid_plan_refused(status, out),
          no_model: length(requests(c)) == n,
          invalid_unchanged: snapshot.() == before and custody(c) == start and File.lstat(legacy_source) == {:error, :enoent},
          no_approval: not File.exists?(Intent.approval_path(c.repo, slug)),
          invalid_output: out,
          invalid_status: status
        })

      mode == "refine" ->
        changed = String.replace(md, "Foundation", "Reconciled foundation")
        path = Path.join(c.root, "correction.md")
        File.write!(path, "Rename the first approved stage to Reconciled foundation; preserve scope and checks.")
        script(c, [f("read_file", %{"path" => Intent.intent_md("fixture")})] ++ List.duplicate(f("submit_refinement", %{"files" => [%{"path" => Intent.intent_md("fixture"), "content" => changed}]}), 2))
        {out, status} = Helpers.run_kogen(c, ["intent", "refine", "fixture", hash, path])
        revoked = not File.exists?(Intent.approval_path(c.repo, "fixture"))
        n = length(requests(c))
        {blocked, bk} = Helpers.run_kogen(c, ["intent", "build", "fixture"])
        {newcard, ck} = Helpers.run_kogen(c, ["intent", "approve", "fixture"])

        Map.merge(common, %{
          refined: status == 0,
          refine_output: out,
          revoked: revoked,
          build_needs_approval: bk != 0 and blocked =~ "not_approved" and length(requests(c)) == n,
          changed_card: ck == 5 and newcard =~ "Reconciled foundation",
          no_commit: git(c, ["rev-parse", "HEAD"]) == start.head
        })

      mode == "single" ->
        script(c, [write("final"), finish(), approve_review()])
        {out, k} = Helpers.run_kogen(c, ["intent", "build", "fixture"])

        Map.merge(common, %{
          landed: k == 0,
          output: out,
          commits: git(c, ["rev-list", "--count", start.head <> "..HEAD"]),
          stage_trace: Enum.filter(trace(c), &String.starts_with?(&1["kind"], "stage-")),
          final_trace: Enum.filter(trace(c), &(&1["kind"] == "acceptance")) |> Enum.map(& &1["state"])
        })

      true -> flow(c, mode, start, common)
    end
  end

  defp flow(c, mode, start, common) do
    private_message = %{"type" => "message", "id" => "stage-builder-private", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "BUILDER_PRIVATE_STAGE_CONVERSATION"}]}
    private_reasoning = %{"type" => "reasoning", "id" => "stage-opaque", "encrypted_content" => "opaque-stage+/==", "summary" => []}
    effect = %{"type" => "function_call", "id" => "stage-effect-item", "call_id" => "stage-effect-call", "name" => "shell", "arguments" => JSON.encode!(%{"command" => "printf 'once\\n' >> .kogen/local/effects"})}

    script(c, [{:items, [private_message, private_reasoning, effect]}, write("broken"), finish(), write("phase-one"), finish(), {:http, 400, %{"error" => %{"message" => "fixture stop", "code" => "invalid_request_error"}}}])
    n = length(requests(c))
    {first, fk} = Helpers.run_kogen(c, ["intent", "build", "fixture"])
    first_requests = Enum.drop(requests(c), n)
    [cp] = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/checkpoint.json"))
    run_dir = Path.dirname(cp)
    result_path = Path.join(run_dir, "result.json")
    old_result = File.read!(result_path)
    stopped = JSON.decode!(old_result)
    stopped_custody = custody(c)
    first_trace = trace(c)
    if mode == "candidate-drift", do: put(c, "app.txt", "operator edit\n")
    if mode == "plan-drift", do: put(c, Intent.intent_md("fixture"), File.read!(Path.join(c.repo, Intent.intent_md("fixture"))) <> "\nSubstantive changed stage contract\n")

    c = if mode == "other-checkout" do
      other = Path.join(c.root, "other-checkout")
      File.cp_r!(c.repo, other)
      %{c | repo: other}
    else
      c
    end

    before_resume = custody(c)
    id = Path.basename(run_dir)
    script(c, [write("phase-two"), finish(), write("final"), finish(), write("review-broken"), approve_review(), write("final-reviewed"), approve_review()])
    n = length(requests(c))
    {last, lk} = Helpers.run_kogen(c, ["intent", "resume", id])
    resumed = Enum.drop(requests(c), n)
    original_log = Path.join(c.repo, ".kogen/local/runs/#{id}/log.jsonl")
    logs = [original_log | Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*/log.jsonl")) -- [original_log]]
    rows = Enum.flat_map(logs, fn p -> String.split(File.read!(p), "\n", trim: true) |> Enum.map(&JSON.decode!/1) end)
    reviews = FakeProvider.review_requests(c.server)

    Map.merge(common, %{
      first_stopped: fk != 0 and stopped_custody.head == start.head,
      stop_index_approval: stopped_custody.index == start.index and stopped_custody.approval == start.approval,
      stage_progress: stopped["stage_progress"],
      stage_trace: Enum.filter(trace(c), &String.starts_with?(&1["kind"], "stage-")),
      no_full_before_stop: not Enum.any?(first_trace, &(&1["kind"] == "acceptance")),
      no_review_before_stop: not Enum.any?(first_requests, &(FakeProvider.input_text(&1) =~ "You review code")),
      resume_exact: resumed != [] and input(hd(resumed)) == input(List.last(first_requests)),
      first_result_unchanged: File.read!(result_path) == old_result,
      effect_once: File.read!(Path.join(c.repo, ".kogen/local/effects")) == "once\n",
      landed: lk == 0,
      commits: git(c, ["rev-list", "--count", start.head <> "..HEAD"]),
      final_trace: Enum.filter(trace(c), &(&1["kind"] == "acceptance")) |> Enum.map(& &1["state"]),
      model_executed: Enum.any?(rows, &(&1["event"] == "command_result" and &1["name"] == "model" and &1["status"] == 0)),
      configured_final: Enum.any?(trace(c), &(&1["kind"] == "configured" and &1["state"] == "final-reviewed" and &1["status"] == 0)),
      reviewer_repair_feedback: Enum.any?(reviews, &(JSON.encode!(&1.json["input"]) =~ "review-broken" and JSON.encode!(&1.json["input"]) =~ "not green")),
      independent: reviews != [] and not (FakeProvider.input_text(hd(reviews)) =~ "BUILDER_PRIVATE_STAGE_CONVERSATION"),
      stage_records: Enum.filter(rows, &(&1["event"] == "stage_pass")) |> Enum.map(&Map.take(&1, ["stage_id", "green"])),
      refused: lk != 0 and Regex.match?(~r/resume_refused|resume_unsupported/, last),
      refusal_unchanged: custody(c) == before_resume,
      no_model: resumed == [],
      first_output: first,
      output: last
    })
  end
end

# Synthetic request-selection and lint-output controls: no installed Build,
# account or inference. Use the same observers as the native exercise, reaching
# the invalid-plan predicate independently of missing stage guidance/progress.
case System.get_env("STAGED_OBSERVER_CONTROL") do
  nil -> :ok
  mode ->
    request = fn text -> %{json: %{"input" => [%{"role" => "developer", "content" => text}]}} end
    init = request.("native init: submit_configuration")
    first = request.("native Shape guidance: ## Stages")
    later = request.("candidate echo: ## Stages")
    selected = StagedIntentBuildsExercise.shape_requests_since([init, first, later], 1)
    true = selected == [first, later]
    true = StagedIntentBuildsExercise.shape_guidance(selected)
    true = StagedIntentBuildsExercise.invalid_plan_refused(1, "intent/lint: stages: expected version 1 and at least two unique stages\n")

    case mode do
      "good" -> IO.puts("shape observer accepted")
      "bad" ->
        for retained <- [
          [first, request.("native Shape without stage guidance"), later],
          [init, request.("native Shape without stage guidance"), later],
          [first]
        ] do
          false = retained |> StagedIntentBuildsExercise.shape_requests_since(1) |> StagedIntentBuildsExercise.shape_guidance()
        end
        for {status, out} <- [
          {1, "candidate/source_provenance_changed: source provenance custody missing, changed or unsafe: stages/fixture/current.json\n"},
          {5, "intent/lint: stages: invalid\n"},
          {0, "intent/lint: stages: invalid\n"},
          {1, "intent/lint: missing Tests section\n"},
          {1, "stage command failed\n"},
          {1, "candidate/source_provenance_changed: intent/lint stages was never reached\n"}
        ] do
          false = StagedIntentBuildsExercise.invalid_plan_refused(status, out)
        end
        IO.puts("shape observer rejected counterexamples")
        System.halt(1)
    end
end
