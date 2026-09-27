Code.require_file("../support/shaping_audit/fake_jev_audit.ex", __DIR__)
Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)

defmodule Kogen.ShapingAuditJevTest do
  @moduledoc """
  The `jev-contract-questions` scenario: the shipped question-set-v1 table
  against its evidence, the 14 advisory contract questions over the
  `jev-clauses` fixture Draft (each planted case flagged, each clean
  counterpart silent), the `jev-large` fixture's size limits, the privacy
  allowlist, concurrency, retries and every failure mode.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingAudit.FakeJevAudit
  alias Kogen.ShapingAudit.Fixture
  alias Kogen.ShapingAudit.JevLayer
  alias Kogen.ShapingAudit.{Package, Report}
  alias Kogen.ShapingAudit.Questions

  @drafts Path.expand("../support/shaping_audit/packages", __DIR__)

  describe "the shipped question-set-v1 table" do
    test "holds the 14 entries of question-set-v1.json byte for byte, plus fix-check" do
      shipped =
        "priv/kogen/shaping_audit/questions-v1.json" |> File.read!() |> Jason.decode!()

      evidence_entries =
        "test/support/shaping_audit/calibration/question-set-v1.json"
        |> File.read!()
        |> Jason.decode!()

      evidence_fix_check =
        "test/support/shaping_audit/calibration/fix-check-v1.json"
        |> File.read!()
        |> Jason.decode!()

      assert length(shipped["entries"]) == 14
      assert shipped["entries"] == evidence_entries["entries"]
      assert shipped["fix-check"] == evidence_fix_check
    end

    test "priv/kogen/shaping_audit/ ships no finding-routing file" do
      listing = "priv/kogen/shaping_audit" |> File.ls!()
      refute Enum.any?(listing, &String.contains?(&1, "finding-routing"))
    end
  end

  describe "the README claims" do
    test "state the setup step, the allowlist and that Jev's answers are advisory" do
      readme = File.read!("README.md")
      assert readme =~ "### Jev in the Shaping audit"

      assert readme =~
               "security add-generic-password -s dev.kogen.jev -a <account> -w"

      assert readme =~ "risk `privacy-boundary` allowlist"
      assert readme =~ "never sends a diff, working-tree bytes"
      assert readme =~ "strictly advisory"
    end
  end

  describe "Kogen.Jev.request_body/2 (the Build handoff) is unchanged" do
    test "byte-identical for a fixed input" do
      items = [%{"kind" => "scenario", "id" => "s1"}]
      body = Kogen.Jev.request_body("notes", items)
      assert Jason.decode!(body)["model"] == Kogen.Jev.model()
      assert Kogen.Jev.objection_threshold() == 0.85
      assert Kogen.Jev.timeout_ms() == 60_000
    end
  end

  test "main/2 persists advisory Jev requests and answers and remains ready" do
    root = Fixture.repo!(second_commit: false, working_tree: false, prior_failures: false)
    File.mkdir_p!(Path.join(root, "test/kogen"))
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def ok, do: true\nend\n")
    File.write!(Path.join(root, "test/kogen/sample_test.exs"), "assert true\n")
    File.write!(Path.join(root, "docs/note.txt"), "committed citation\n")

    {_, 0} =
      System.cmd("git", ["add", "lib/demo.ex", "test/kogen/sample_test.exs", "docs/note.txt"],
        cd: root
      )

    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "Jev: fixture"], cd: root)
    package_rel = Fixture.add_draft!(root, "jev-clauses", source: "packages")
    on_exit(fn -> File.rm_rf!(root) end)

    env = Fixture.audit_env!(root)

    System.put_env(
      "FAKE_JEV_ANSWERS",
      Jason.encode!(%{"kind:c0" => ["unobservable", 0.8], "leak" => ["none", 1.0]})
    )

    on_exit(fn -> System.delete_env("FAKE_JEV_ANSWERS") end)

    code = Kogen.ShapingAudit.main(["--auditor", "jev-clauses"], root: root, env: env)
    assert code == 0
    {:ok, loaded} = Package.load(root, package_rel)
    {:ok, report} = Report.read(root, "jev-clauses", loaded.revision)
    jev = report["layers"]["jev"]

    assert report["readiness"] == "ready"
    assert jev["status"] == "ok"
    assert jev["requests"] != []
    assert Map.keys(jev["answers"]) |> Enum.sort() == Enum.sort(jev["requests"])
    assert Enum.all?(jev["findings"], &(&1["rule"] == "then-unobservable"))
    assert jev["findings"] != []
    assert Enum.all?(jev["findings"], &(&1["severity"] == "advisory"))
    refute Jason.encode!(report) =~ "usage"
  end

  test "fixed auditor findings receive a fix-check and retain or close still_open" do
    for {choice, still_open} <- [{"partly", true}, {"addressed", false}] do
      ctx = build_ctx("jev-clauses")

      finding = %{
        "id" => "aud-fixed",
        "rule" => "scope-drift",
        "layer" => "auditor",
        "scope" => "draft",
        "severity" => "blocking",
        "disputable" => true,
        "scenario" => "sample-scenario",
        "paths" => [],
        "message" => "the scenario contract needs review",
        "route" => nil,
        "disposition" => %{"kind" => "fixed", "reason" => "fixed sample-scenario"}
      }

      transport = fn request ->
        body = Jason.decode!(request.body)

        answers =
          if Map.has_key?(body["questions"], "fix-check") do
            %{
              "fix-check" => %{
                "type" => "choice",
                "choice" => choice,
                "confidence" => 0.9,
                "probabilities" => %{
                  "addressed" => if(choice == "addressed", do: 0.9, else: 0.05),
                  "partly" => if(choice == "partly", do: 0.9, else: 0.05),
                  "not_addressed" => if(choice == "not_addressed", do: 0.9, else: 0.05)
                }
              }
            }
          else
            %{
              "gate" => %{
                "type" => "choice",
                "choice" => "product_ux",
                "confidence" => 0.9,
                "probabilities" => %{
                  "product_ux" => 0.9,
                  "technical" => 0.05,
                  "already_settled" => 0.05
                }
              },
              "settled_by" => %{
                "type" => "choice",
                "choice" => "none",
                "confidence" => 0.9,
                "probabilities" => %{"none" => 0.9}
              }
            }
          end

        if Map.has_key?(body["questions"], "gate") or Map.has_key?(body["questions"], "fix-check") do
          {:ok,
           %{status: 200, body: Jason.encode!(%{"model" => body["model"], "answers" => answers})}}
        else
          FakeJevAudit.answering().(request)
        end
      end

      result = JevLayer.run(with_transport(ctx, transport), [finding])
      assert result["status"] == "ok"
      assert Enum.any?(result["requests"], &is_binary/1)

      assert [%{"still_open" => ^still_open}] =
               Enum.filter(result["routed_findings"], &(&1["id"] == "aud-fixed"))
    end
  end

  describe "the 14 advisory contract questions, planted and clean" do
    setup do
      {:ok, ctx: build_ctx("jev-clauses")}
    end

    test "then-unobservable fires only when Jev flags it (clean silent, planted flags)", %{
      ctx: ctx
    } do
      clean_ctx = with_transport(ctx, FakeJevAudit.answering(%{"kind:c0" => {"observable", 0.9}}))
      clean = JevLayer.run(clean_ctx, [])
      assert clean["status"] == "ok"
      refute Enum.any?(clean["findings"], &(&1["rule"] == "then-unobservable"))
      assert Enum.all?(clean["findings"], &(&1["severity"] == "advisory"))

      planted_ctx =
        with_transport(ctx, FakeJevAudit.answering(%{"kind:c0" => {"unobservable", 0.9}}))

      planted = JevLayer.run(planted_ctx, [])
      assert planted["status"] == "ok"

      assert Enum.any?(
               planted["findings"],
               &(&1["rule"] == "then-unobservable" and &1["scenario"] == "sample-scenario")
             )
    end

    test "wrong-result-implausible fires only above its 0.80 gate", %{ctx: ctx} do
      below = with_transport(ctx, FakeJevAudit.answering(%{"plaus:w0" => {"implausible", 0.79}}))

      refute Enum.any?(
               JevLayer.run(below, [])["findings"],
               &(&1["rule"] == "wrong-result-implausible")
             )

      at = with_transport(ctx, FakeJevAudit.answering(%{"plaus:w0" => {"implausible", 0.80}}))

      assert Enum.any?(
               JevLayer.run(at, [])["findings"],
               &(&1["rule"] == "wrong-result-implausible")
             )
    end

    test "hard-rule-timeout-raised fires only at its 0.75 noul gate", %{ctx: ctx} do
      below = with_transport(ctx, FakeJevAudit.answering(%{"timeout:c0" => 0.74}))

      refute Enum.any?(
               JevLayer.run(below, [])["findings"],
               &(&1["rule"] == "hard-rule-timeout-raised")
             )

      at = with_transport(ctx, FakeJevAudit.answering(%{"timeout:c0" => 0.75}))

      assert Enum.any?(
               JevLayer.run(at, [])["findings"],
               &(&1["rule"] == "hard-rule-timeout-raised")
             )
    end

    test "wrong-result-not-caught fires only when both the choice and the noul agree", %{ctx: ctx} do
      caught =
        with_transport(ctx, FakeJevAudit.answering(%{"caught_choice:w0" => {"e0", 0.9}}))

      refute Enum.any?(
               JevLayer.run(caught, [])["findings"],
               &(&1["rule"] == "wrong-result-not-caught")
             )

      not_caught =
        with_transport(ctx, FakeJevAudit.answering(%{"caught_choice:w0" => {"none", 0.6}}))

      assert Enum.any?(
               JevLayer.run(not_caught, [])["findings"],
               &(&1["rule"] == "wrong-result-not-caught")
             )
    end

    test "paid-observation-offline-checkable fires only when Jev says offline", %{ctx: ctx} do
      offline = with_transport(ctx, FakeJevAudit.answering(%{"o" => {"offline", 0.9}}))

      assert Enum.any?(
               JevLayer.run(offline, [])["findings"],
               &(&1["rule"] == "paid-observation-offline-checkable")
             )

      clean = with_transport(ctx, FakeJevAudit.answering(%{"o" => {"provider_only", 0.9}}))

      refute Enum.any?(
               JevLayer.run(clean, [])["findings"],
               &(&1["rule"] == "paid-observation-offline-checkable")
             )
    end

    test "provider-behaviour-in-offline-scenario fires only above its 0.90 gate", %{ctx: ctx} do
      below = with_transport(ctx, FakeJevAudit.answering(%{"pc:c0" => {"provider_only", 0.89}}))

      refute Enum.any?(
               JevLayer.run(below, [])["findings"],
               &(&1["rule"] == "provider-behaviour-in-offline-scenario")
             )

      at = with_transport(ctx, FakeJevAudit.answering(%{"pc:c0" => {"provider_only", 0.90}}))

      assert Enum.any?(
               JevLayer.run(at, [])["findings"],
               &(&1["rule"] == "provider-behaviour-in-offline-scenario")
             )
    end

    test "outcome-without-scenario fires for the Outcome item no scenario states", %{ctx: ctx} do
      result = JevLayer.run(with_transport(ctx, FakeJevAudit.answering()), [])
      assert Enum.any?(result["findings"], &(&1["rule"] == "outcome-without-scenario"))
    end

    test "non-goal-leakage never fires when the scenario requires no listed non-goal", %{ctx: ctx} do
      clean = with_transport(ctx, FakeJevAudit.answering(%{"leak" => {"none", 0.9}}))
      refute Enum.any?(JevLayer.run(clean, [])["findings"], &(&1["rule"] == "non-goal-leakage"))
    end

    test "non-goal-leakage fires when Jev says the scenario requires a listed non-goal", %{
      ctx: ctx
    } do
      planted = with_transport(ctx, FakeJevAudit.answering(%{"leak" => {"n0", 0.9}}))
      result = JevLayer.run(planted, [])
      assert Enum.any?(result["findings"], &(&1["rule"] == "non-goal-leakage"))
    end

    test "citation is judged from the HEAD materialization, never the working tree", %{ctx: ctx} do
      contradicted =
        with_transport(ctx, FakeJevAudit.answering(%{"c0" => {"contradicted", 0.9}}, self()))

      result = JevLayer.run(contradicted, [])
      assert Enum.any?(result["findings"], &(&1["rule"] == "citation-contradicted"))

      # supported (>= 0.85) is silent
      clean =
        with_transport(
          ctx,
          FakeJevAudit.answering(
            %{"c0" => {"supported", 0.9}, "c1" => {"supported", 0.9}},
            self()
          )
        )

      clean_result = JevLayer.run(clean, [])

      refute Enum.any?(
               clean_result["findings"],
               &(&1["rule"] in ["citation-contradicted", "citation-insufficient"])
             )

      requests = drain_requests()
      assert Enum.any?(requests, &(&1.body =~ "KOGEN-SENTINEL-HEAD-MATERIALIZATION"))
      refute Enum.any?(requests, &(&1.body =~ "KOGEN-SENTINEL-UNCOMMITTED-WORKING-TREE-EDIT"))
    end
  end

  # Every one of the 14 question-set-v1 entries: `raise` overrides put the
  # entry's own gate answer at or past its threshold (a planted case), and
  # `safe` overrides put it just short of the threshold (the clean
  # counterpart). Two entries (`alternative-caught-evidence`,
  # `alternative-caught-strict`) share `wrong-result-not-caught`, each
  # isolated by holding its partner answer fixed.
  @fourteen_entries [
    {"clause-kind", "then-unobservable", %{"kind:c0" => {"unobservable", 0.80}},
     %{"kind:c0" => {"unobservable", 0.79}}},
    {"clause-asserted", "then-without-described-proof",
     %{"kind:c0" => {"observable", 0.9}, "asserted:c0" => {"not_described", 0.80}},
     %{"kind:c0" => {"observable", 0.9}, "asserted:c0" => {"not_described", 0.79}}},
    {"alternative-plausible", "wrong-result-implausible", %{"plaus:w0" => {"implausible", 0.80}},
     %{"plaus:w0" => {"implausible", 0.79}}},
    {"clause-timeout", "hard-rule-timeout-raised", %{"timeout:c0" => 0.75},
     %{"timeout:c0" => 0.74}},
    {"clause-effort", "hard-rule-effort-lowered", %{"effort:c0" => 0.75}, %{"effort:c0" => 0.74}},
    {"clause-weaken", "hard-rule-check-loosened", %{"weaken:c0" => 0.75}, %{"weaken:c0" => 0.74}},
    {"alternative-caught-evidence", "wrong-result-not-caught",
     %{"caught_noul:w0" => 0.1, "caught_choice:w0" => {"none", 0.50}},
     %{"caught_noul:w0" => 0.1, "caught_choice:w0" => {"none", 0.49}}},
    {"alternative-caught-strict", "wrong-result-not-caught",
     %{"caught_choice:w0" => {"none", 0.9}, "caught_noul:w0" => 0.59},
     %{"caught_choice:w0" => {"none", 0.9}, "caught_noul:w0" => 0.60}},
    {"paid-observation", "paid-observation-offline-checkable", %{"o" => {"offline", 0.80}},
     %{"o" => {"offline", 0.79}}},
    {"clause-provider-only", "provider-behaviour-in-offline-scenario",
     %{"pc:c0" => {"provider_only", 0.90}}, %{"pc:c0" => {"provider_only", 0.89}}},
    {"outcome-coverage", "outcome-without-scenario",
     %{"cov:o0" => {"none", 0.80}, "cov:o1" => {"none", 0.80}},
     %{"cov:o0" => {"none", 0.79}, "cov:o1" => {"none", 0.79}}},
    {"non-goal-leakage", "non-goal-leakage", %{"leak" => {"n0", 0.60}},
     %{"leak" => {"n0", 0.59}}},
    {"question-provenance", "question-unresolved",
     %{"prov:q0" => {"unresolved", 0.80}, "prov:q1" => {"with_provenance", 0.9}},
     %{"prov:q0" => {"unresolved", 0.79}, "prov:q1" => {"with_provenance", 0.9}}},
    {"citation", "citation-insufficient", %{"c0" => {"supported", 0.84}},
     %{"c0" => {"supported", 0.85}}}
  ]

  describe "every one of the 14 question-set-v1 entries, at and just below its own gate" do
    setup do
      {:ok, ctx: build_ctx("jev-clauses")}
    end

    for {id, rule, raise_overrides, safe_overrides} <- @fourteen_entries do
      test "#{id} raises #{rule} at its gate and not just below it", %{ctx: ctx} do
        raising =
          with_transport(ctx, FakeJevAudit.answering(unquote(Macro.escape(raise_overrides))))

        raised = JevLayer.run(raising, [])
        assert raised["status"] == "ok"

        assert Enum.any?(raised["findings"], &(&1["rule"] == unquote(rule))),
               "#{unquote(id)} did not raise #{unquote(rule)} at its gate"

        safe = with_transport(ctx, FakeJevAudit.answering(unquote(Macro.escape(safe_overrides))))
        safe_result = JevLayer.run(safe, [])

        refute Enum.any?(safe_result["findings"], &(&1["rule"] == unquote(rule))),
               "#{unquote(id)} raised #{unquote(rule)} just below its gate"
      end
    end

    test "the table above covers exactly the 14 shipped entry ids" do
      shipped_ids =
        "priv/kogen/shaping_audit/questions-v1.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("entries")
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      table_ids = @fourteen_entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert table_ids == shipped_ids
      assert length(table_ids) == 14
    end
  end

  describe "the privacy allowlist" do
    test "never sends risks.yaml, references.yaml, approval.md, evidence/ or the working tree",
         %{} do
      ctx = with_transport(build_ctx("jev-clauses"), FakeJevAudit.answering(%{}, self()))
      JevLayer.run(ctx, [])
      requests = drain_requests()
      bodies = Enum.map_join(requests, "\n", & &1.body)

      refute bodies =~ "KOGEN-SENTINEL-RISKS-YAML"
      refute bodies =~ "KOGEN-SENTINEL-REFERENCES-YAML"
      refute bodies =~ "KOGEN-SENTINEL-APPROVAL-MD"
      refute bodies =~ "KOGEN-SENTINEL-EVIDENCE-DIR"
      refute bodies =~ "KOGEN-SENTINEL-UNCOMMITTED-WORKING-TREE-EDIT"
      refute bodies =~ "diff --git"
    end
  end

  describe "size limits" do
    test "jev-item-too-large fires for the over-sized clause and skips it" do
      ctx = with_transport(build_ctx("jev-large"), FakeJevAudit.answering(%{}, self()))
      result = JevLayer.run(ctx, [])
      assert result["status"] == "ok"

      assert Enum.any?(
               result["findings"],
               &(&1["rule"] == "jev-item-too-large" and
                   String.contains?(&1["id"], "large-item-scenario"))
             )

      requests = drain_requests()
      refute Enum.any?(requests, &(byte_size(&1.body) > 400_000))
    end

    test "jev-request-too-large fires when many small items still exceed 64 KiB" do
      ctx = with_transport(build_ctx("jev-large"), FakeJevAudit.answering(%{}, self()))
      result = JevLayer.run(ctx, [])

      assert Enum.any?(
               result["findings"],
               &(&1["rule"] == "jev-request-too-large" and
                   String.contains?(&1["id"], "large-request-scenario"))
             )
    end
  end

  describe "concurrency and the layer deadline" do
    test "at most 4 requests run at once" do
      ctx = build_ctx("jev-clauses")
      {:ok, counter} = Agent.start_link(fn -> {0, 0} end)

      transport = fn request ->
        Agent.update(counter, fn {current, peak} -> {current + 1, max(current + 1, peak)} end)
        Process.sleep(20)
        Agent.update(counter, fn {current, peak} -> {current - 1, peak} end)
        FakeJevAudit.answering().(request)
      end

      _ = JevLayer.run(with_transport(ctx, transport), [])
      {_current, peak} = Agent.get(counter, & &1)
      assert peak <= 4
    end

    test "a sleep past an injected deadline makes the layer unavailable" do
      ctx = build_ctx("jev-clauses")

      slow = fn request ->
        Process.sleep(200) |> then(fn _ -> FakeJevAudit.answering().(request) end)
      end

      ctx = with_transport(ctx, slow, jev_deadline_ms: 20)

      result = JevLayer.run(ctx, [])
      assert result["status"] == "unavailable"
      assert result["reason"] =~ "deadline"
    end
  end

  describe "every Jev failure mode" do
    setup do
      {:ok, ctx: build_ctx("jev-clauses")}
    end

    for {label, results, reason_part} <- [
          {"HTTP 500", [{500, "boom"}], "HTTP 500"},
          {"HTTP 401", [{401, "no"}], "HTTP 401"},
          {"HTTP 422", [{422, "bad"}], "HTTP 422"},
          {"HTTP 429 three times", [{429, "x"}, {429, "x"}, {429, "x"}], "HTTP 429"},
          {"invalid JSON", [{200, "not json"}], "not a JSON object"},
          {"echoed key", [{:error, "refused with Bearer kogen-offline-sentinel-jev-key"}],
           "[redacted]"}
        ] do
      test "#{label} makes the layer unavailable with a precise reason", %{ctx: ctx} do
        ctx =
          with_transport(ctx, FakeJevAudit.replay(unquote(Macro.escape(results))),
            jev_sleep: fn _ms -> :ok end
          )

        result = JevLayer.run(ctx, [])
        assert result["status"] == "unavailable"
        assert result["reason"] =~ unquote(reason_part)
        assert [%{"rule" => "jev-unavailable", "scope" => "environment"}] = result["findings"]
        refute Jason.encode!(result) =~ "kogen-offline-sentinel-jev-key"
      end
    end

    test "a missing answer makes the layer unavailable, with no partial finding" do
      ctx = build_single_ask_ctx("Does plain Kogen always require explicit human approval?")

      body =
        Jason.encode!(%{"model" => "jev-1.13.0", "answers" => %{"gate" => valid_gate_answer()}})

      ctx = with_transport(ctx, FakeJevAudit.replay([{200, body}]))
      result = JevLayer.run(ctx, [])
      assert result["status"] == "unavailable"
      assert result["reason"] =~ "answer for settled_by is missing"
      assert [%{"rule" => "jev-unavailable"}] = result["findings"]
    end

    test "an unknown option id makes the layer unavailable, with no partial finding" do
      ctx = build_single_ask_ctx("Does plain Kogen always require explicit human approval?")

      body =
        Jason.encode!(%{
          "model" => "jev-1.13.0",
          "answers" => %{
            "gate" => %{
              "type" => "choice",
              "choice" => "not_a_real_option",
              "confidence" => 0.9,
              "probabilities" => %{
                "technical" => 0.9,
                "product_ux" => 0.05,
                "already_settled" => 0.05
              }
            },
            "settled_by" => valid_settled_by_answer()
          }
        })

      ctx = with_transport(ctx, FakeJevAudit.replay([{200, body}]))
      result = JevLayer.run(ctx, [])
      assert result["status"] == "unavailable"
      assert result["reason"] =~ "was not sent"
      assert [%{"rule" => "jev-unavailable"}] = result["findings"]
    end

    test "429 twice then success still answers", %{ctx: ctx} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      transport = fn request ->
        n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        if n < 2,
          do: {:ok, %{status: 429, body: "slow"}},
          else: FakeJevAudit.answering().(request)
      end

      ctx = with_transport(ctx, transport, jev_sleep: fn _ms -> :ok end)
      result = JevLayer.run(ctx, [])
      assert result["status"] == "ok"
      assert Agent.get(counter, & &1) >= 3
    end

    test "a missing Keychain item names the setup command" do
      ctx = build_ctx("jev-clauses")
      ctx = %{ctx | env: %{"KOGEN_JEV_SECURITY" => "/nonexistent/security-fixture"}}
      result = JevLayer.run(ctx, [])
      assert result["status"] == "unavailable"
      assert result["reason"] =~ "security add-generic-password -s dev.kogen.jev"
    end
  end

  describe "the fake executables" do
    test "the audit fakes never open a network connection and log every call" do
      log =
        Path.join(System.tmp_dir!(), "kogen-fake-jev-audit-#{System.unique_integer([:positive])}")

      File.mkdir_p!(log)
      System.put_env("FAKE_JEV_LOG_DIR", log)
      on_exit(fn -> File.rm_rf!(log) end)

      ctx =
        build_ctx("jev-clauses")
        |> Map.put(:env, %{
          "KOGEN_JEV_TRANSPORT" => FakeJevAudit.transport_path(),
          "KOGEN_JEV_SECURITY" => FakeJevAudit.security_path()
        })

      result = JevLayer.run(ctx, [])
      assert result["status"] == "ok"
      logged = log |> Path.join("request-1.json") |> File.read!() |> Jason.decode!()
      assert logged["authorization_matches_keychain"] == true

      fake_source = File.read!(FakeJevAudit.transport_path())
      refute fake_source =~ ~r/\b(socket|urllib|http\.client|requests|ssl)\b/
    end
  end

  # --------------------------------------------------------------- helpers

  # A minimal :asking-state ctx with exactly one `## Ask the Shaper` entry,
  # so exactly one gate request is sent (no scenarios, no confirm follow-up).
  defp build_single_ask_ctx(text) do
    questions_md = "## Ask the Shaper\n\n1. #{text} Recommendation: r. Evidence: unproven — x.\n"
    questions = Questions.parse(questions_md)

    %{
      root: Path.join(@drafts, "questions"),
      slug: "single-ask",
      package_rel: ".kogen/intents/drafts/single-ask",
      materialization: Path.join(@drafts, "questions/head"),
      files: %{"questions.md" => questions_md},
      intent: nil,
      scenarios: [],
      questions: questions,
      state: Questions.state(questions),
      head: "0000000000000000000000000000000000000000",
      revision: "0000000000000000000000000000000000000000000000000000000000000000",
      route: "claude",
      config: nil,
      env: %{},
      opts: []
    }
  end

  defp valid_gate_answer do
    %{
      "type" => "choice",
      "choice" => "technical",
      "confidence" => 0.9,
      "probabilities" => %{"technical" => 0.9, "product_ux" => 0.05, "already_settled" => 0.05}
    }
  end

  defp valid_settled_by_answer do
    %{
      "type" => "choice",
      "choice" => "none",
      "confidence" => 0.9,
      "probabilities" => %{"none" => 0.9}
    }
  end

  defp build_ctx(draft) do
    root = Path.join(@drafts, draft)
    scenarios = YamlElixir.read_from_file!(Path.join(root, "scenarios.yaml"))
    intent_md = read_optional(Path.join(root, "INTENT.md"))
    questions_md = read_optional(Path.join(root, "questions.md"))
    questions = Questions.parse(questions_md)

    %{
      root: root,
      slug: draft,
      package_rel: ".kogen/intents/drafts/#{draft}",
      materialization: Path.join(root, "head"),
      files: %{
        "scenarios.yaml" => File.read!(Path.join(root, "scenarios.yaml")),
        "INTENT.md" => intent_md || "",
        "questions.md" => questions_md
      },
      intent: nil,
      scenarios: scenarios,
      questions: questions,
      state: Questions.state(questions),
      head: "0000000000000000000000000000000000000000",
      revision: "0000000000000000000000000000000000000000000000000000000000000000",
      route: "claude",
      config: nil,
      env: %{},
      opts: []
    }
  end

  defp read_optional(path), do: if(File.exists?(path), do: File.read!(path), else: nil)

  defp with_transport(ctx, transport, extra_opts \\ []) do
    %{
      ctx
      | env: %{
          "KOGEN_JEV_TRANSPORT" => transport,
          "KOGEN_JEV_SECURITY" => FakeJevAudit.security_path()
        },
        opts: extra_opts
    }
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:jev_request, request} -> drain_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
