defmodule Kogen.ShapingAuditAuditorPureTest do
  use ExUnit.Case, async: true

  alias Kogen.ShapingAudit.Auditor

  defp isolated_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-auditor-test-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    dir
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

  # -- pre-I/O state gating -----------------------------------------------
  test "skipped while the session is asking" do
    # State gating happens before anything is read from disk, so a fully
    # synthetic ctx (never touched) is enough here.
    ctx = %{state: :asking}
    result = Auditor.run(ctx, [], launch?: true)

    assert result["status"] == "skipped"
    assert result["findings"] == []
  end
end
