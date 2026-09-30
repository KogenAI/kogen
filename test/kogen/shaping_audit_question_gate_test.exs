Code.require_file("../support/shaping_audit/fake_jev_audit.ex", __DIR__)

defmodule Kogen.ShapingAuditQuestionGateTest do
  @moduledoc """
  The `question-gate` scenario: the shipped question-gate-v1 table against
  its evidence, every routing branch (cite / controller / Shaper) at and
  just below each threshold, the related-topic citation control, the
  `settled.json` ids against their stated sources, the request state in the
  fake log, and that a Shaper-routed auditor finding in the autonomous
  state becomes an assumption, never a question.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingAudit.FakeJevAudit
  alias Kogen.ShapingAudit.JevLayer
  alias Kogen.ShapingAudit.Questions

  @drafts Path.expand("../support/shaping_audit/packages", __DIR__)

  describe "the shipped question-gate-v1 table" do
    test "equals evidence/jev-routing-calibration/question-gate-v1.question.json byte for byte" do
      shipped =
        File.read!(
          Path.join(
            System.fetch_env!("KOGEN_TEST_ROOT"),
            "priv/kogen/shaping_audit/question-gate-v1.json"
          )
        )

      evidence =
        File.read!(
          Path.join(
            System.fetch_env!("KOGEN_TEST_ROOT"),
            "test/support/shaping_audit/calibration/question-gate-v1.question.json"
          )
        )

      assert shipped == evidence
    end

    test "pins the product_ux rule text naming \"splitting or deferring any requested scope\"" do
      gate = JevLayer.gate_table()
      rules = gate["questions"]["gate"]["instructions"]["rules"]
      assert Enum.any?(rules, &String.contains?(&1, "splitting or deferring any requested scope"))
    end

    test "priv/kogen/shaping_audit/ ships no finding-routing file" do
      listing =
        System.fetch_env!("KOGEN_TEST_ROOT")
        |> Path.join("priv/kogen/shaping_audit")
        |> File.ls!()

      refute Enum.any?(listing, &String.contains?(&1, "finding-routing"))
    end
  end

  describe "settled.json" do
    test "ids match their stated DIRECTION/Shaping sources" do
      settled =
        File.read!(
          Path.join(System.fetch_env!("KOGEN_TEST_ROOT"), "priv/kogen/shaping_audit/settled.json")
        )
        |> Jason.decode!()

      ids = Enum.map(settled["entries"], & &1["id"])

      assert "dir-1.13" in ids
      assert "dir-1.17" in ids
      assert "shp-auditor-profile" in ids
      refute "shp-one-build" in ids
      assert "shp-wait-only-product" in ids

      for entry <- settled["entries"] do
        assert is_binary(entry["source"]) and entry["source"] != ""
        assert is_binary(entry["text"]) and entry["text"] != ""

        if String.starts_with?(entry["id"], "dir-") do
          assert entry["source"] =~ "DIRECTION.md"
        end
      end
    end

    test "includes DIRECTION 1.13 (Plain Kogen always requires explicit human approval)" do
      settled =
        File.read!(
          Path.join(System.fetch_env!("KOGEN_TEST_ROOT"), "priv/kogen/shaping_audit/settled.json")
        )
        |> Jason.decode!()

      entry = Enum.find(settled["entries"], &(&1["id"] == "dir-1.13"))
      assert entry
      assert entry["text"] =~ "explicit human approval"
    end
  end

  describe "the question gate, one Ask the Shaper entry per case" do
    test "cite at the threshold: already_settled 0.80, settled_by 0.80, confirm 0.60" do
      ctx = build_ctx("Does plain Kogen always require explicit human approval of each Intent?")

      transport =
        FakeJevAudit.answering(%{
          "gate" => {"already_settled", 0.80},
          "settled_by" => {"dir-1.13", 0.80},
          "confirm" => 0.60
        })

      result = JevLayer.run(with_transport(ctx, transport), [])
      assert result["status"] == "ok"
      assert Enum.any?(result["findings"], &(&1["rule"] == "question-already-settled"))
      refute Enum.any?(result["findings"], &(&1["rule"] == "technical-question-to-shaper"))

      [route] = result["routes"]
      assert route["item"] == "question 1"
      assert route["route"] == "cite"
      assert is_map(route["distributions"])
      assert route["model"] == "jev-1.13.0"
      assert route["wording_version"] == "question-gate-v1"
    end

    test "just below the confirm threshold falls back to controller or Shaper, never cite" do
      ctx = build_ctx("Does plain Kogen always require explicit human approval of each Intent?")

      transport =
        FakeJevAudit.answering(%{
          "gate" => {"already_settled", 0.80},
          "settled_by" => {"dir-1.13", 0.80},
          "confirm" => 0.59
        })

      result = JevLayer.run(with_transport(ctx, transport), [])
      refute Enum.any?(result["findings"], &(&1["rule"] == "question-already-settled"))
    end

    test "controller at the 0.50 technical threshold" do
      ctx = build_ctx("Should hook-state.json count blocks per session id or per process?")

      transport =
        FakeJevAudit.answering(%{
          "gate" =>
            {"technical", 0.50,
             %{"technical" => 0.50, "product_ux" => 0.30, "already_settled" => 0.20}},
          "settled_by" => {"none", 0.9}
        })

      result = JevLayer.run(with_transport(ctx, transport), [])
      assert Enum.any?(result["findings"], &(&1["rule"] == "technical-question-to-shaper"))
    end

    test "just below 0.50 technical routes to the Shaper (no finding)" do
      ctx = build_ctx("Should hook-state.json count blocks per session id or per process?")

      transport =
        FakeJevAudit.answering(%{
          "gate" =>
            {"technical", 0.49,
             %{"technical" => 0.49, "product_ux" => 0.31, "already_settled" => 0.20}},
          "settled_by" => {"none", 0.9}
        })

      result = JevLayer.run(with_transport(ctx, transport), [])
      assert result["findings"] == []
    end

    test "the related-topic control (already_settled 0.85, confirm 0.45) routes to the Shaper" do
      ctx =
        build_ctx(
          "Should the auditor also run when the Shaper uses the Codex route directly without mix kogen.shape?"
        )

      transport =
        FakeJevAudit.answering(%{
          "gate" =>
            {"already_settled", 0.85,
             %{"already_settled" => 0.85, "technical" => 0.10, "product_ux" => 0.05}},
          "settled_by" => {"shp-auditor-profile", 0.85},
          "confirm" => 0.45
        })

      result = JevLayer.run(with_transport(ctx, transport), [])
      refute Enum.any?(result["findings"], &(&1["rule"] == "question-already-settled"))
      refute Enum.any?(result["findings"], &(&1["rule"] == "technical-question-to-shaper"))
    end

    test "splitting or deferring requested scope is never cited or handed to the controller" do
      ctx = build_ctx("Should the default-route flip move to a follow-up Intent to save time?")

      transport =
        FakeJevAudit.answering(%{
          "gate" =>
            {"product_ux", 0.9,
             %{"product_ux" => 0.9, "technical" => 0.05, "already_settled" => 0.05}},
          "settled_by" => {"none", 0.9}
        })

      result = JevLayer.run(with_transport(ctx, transport), [])
      assert result["findings"] == []
    end

    test "the request state carries the item and the settled list, from the fake log" do
      log =
        Path.join(System.tmp_dir!(), "kogen-fake-jev-audit-#{System.unique_integer([:positive])}")

      File.mkdir_p!(log)
      System.put_env("FAKE_JEV_LOG_DIR", log)
      on_exit(fn -> File.rm_rf!(log) end)

      questions_md = """
      ## Ask the Shaper

      1. Does plain Kogen always require explicit human approval of each Intent? Recommendation: undecided. Evidence: unproven — asking the Shaper.

      ## Settled

      1. Package decision. Evidence: package evidence.
      """

      ctx =
        build_ctx("Does plain Kogen always require explicit human approval of each Intent?")
        |> Map.put(:questions, Questions.parse(questions_md))
        |> Map.update!(:files, &Map.put(&1, "questions.md", questions_md))
        |> Map.put(:env, %{
          "KOGEN_JEV_TRANSPORT" => FakeJevAudit.transport_path(),
          "KOGEN_JEV_SECURITY" => FakeJevAudit.security_path()
        })

      JevLayer.run(ctx, [])

      logged =
        log
        |> Path.join("request-1.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("body")
        |> Jason.decode!()

      assert logged["state"]["item"] =~ "explicit human approval"
      assert is_list(logged["state"]["settled"])
      assert Enum.any?(logged["state"]["settled"], &(&1["id"] == "dir-1.13"))
      assert Enum.any?(logged["state"]["settled"], &(&1["id"] == "package-1"))
      refute logged["body"] |> to_string() =~ "diff --git"
    end

    test "gate and confirmation requests contain only their calibrated question shapes" do
      ctx = build_ctx("Does plain Kogen always require explicit human approval of each Intent?")

      transport =
        FakeJevAudit.answering(
          %{
            "gate" => {"already_settled", 0.9},
            "settled_by" => {"dir-1.13", 0.9},
            "confirm" => 0.9
          },
          self()
        )

      result = JevLayer.run(with_transport(ctx, transport), [])
      assert result["status"] == "ok"

      bodies =
        drain_requests()
        |> Enum.map(&Jason.decode!(&1.body))
        |> Enum.map(&(Map.keys(&1["questions"]) |> Enum.sort()))

      assert [["gate", "settled_by"], ["confirm"]] = bodies
    end

    test "one invalid gate answer is retried once, then makes Jev unavailable" do
      invalid =
        Jason.encode!(%{
          "model" => "jev-1.13.0",
          "answers" => %{
            "gate" => %{
              "type" => "choice",
              "choice" => "no_objection",
              "confidence" => 0.9,
              "probabilities" => %{"no_objection" => 0.9}
            },
            "settled_by" => %{
              "type" => "choice",
              "choice" => "none",
              "confidence" => 0.9,
              "probabilities" => %{"none" => 0.9}
            }
          }
        })

      result =
        JevLayer.run(
          with_transport(
            build_ctx("Should hook-state.json count blocks per session id or per process?"),
            FakeJevAudit.replay([{200, invalid}, {200, invalid}], self())
          ),
          []
        )

      assert result["status"] == "unavailable"
      assert result["reason"] =~ "was not sent"
      assert length(drain_requests()) == 2
    end
  end

  describe "gate routing of auditor findings in the autonomous state" do
    setup do
      root = Path.join(@drafts, "jev-clauses")

      ctx = %{
        root: root,
        slug: "jev-clauses",
        package_rel: ".x",
        materialization: Path.join(root, "head"),
        files: %{},
        intent: nil,
        scenarios: [],
        questions: Questions.parse(""),
        state: :autonomous,
        head: "h",
        revision: "r",
        route: "claude",
        config: nil,
        env: %{},
        opts: []
      }

      auditor_finding = %{
        "id" => "aud-1",
        "rule" => "scope-drift",
        "layer" => "auditor",
        "scope" => "draft",
        "severity" => "blocking",
        "disputable" => true,
        "scenario" => nil,
        "paths" => [],
        "message" => "Should hook-state.json count blocks per session or process?",
        "route" => nil,
        "disposition" => nil
      }

      {:ok, ctx: ctx, finding: auditor_finding}
    end

    test "a Shaper-routed finding becomes an assumption, never a question", %{
      ctx: ctx,
      finding: finding
    } do
      transport =
        FakeJevAudit.answering(%{
          "gate" =>
            {"product_ux", 0.9,
             %{"product_ux" => 0.9, "technical" => 0.05, "already_settled" => 0.05}},
          "settled_by" => {"none", 0.9}
        })

      result = JevLayer.run(with_transport(ctx, transport), [finding])
      [routed] = result["routed_findings"]
      assert routed["route"] == "shaper"
      assert routed["message"] =~ "assumption"
      assert routed["message"] =~ "never a question"
    end

    test "a technical finding is routed to the controller, never the Shaper", %{
      ctx: ctx,
      finding: finding
    } do
      transport =
        FakeJevAudit.answering(%{
          "gate" =>
            {"technical", 0.9,
             %{"technical" => 0.9, "product_ux" => 0.05, "already_settled" => 0.05}},
          "settled_by" => {"none", 0.9}
        })

      result = JevLayer.run(with_transport(ctx, transport), [finding])
      [routed] = result["routed_findings"]
      assert routed["route"] == "controller"
      refute routed["message"] =~ "assumption"
    end
  end

  # --------------------------------------------------------------- helpers

  defp build_ctx(ask_entry_text) do
    root = Path.join(@drafts, "questions")
    scenarios = YamlElixir.read_from_file!(Path.join(root, "scenarios.yaml"))

    questions_md = """
    ## Ask the Shaper

    1. #{ask_entry_text} Recommendation: undecided. Evidence: unproven — asking the Shaper.
    """

    questions = Questions.parse(questions_md)

    %{
      root: root,
      slug: "questions",
      package_rel: ".kogen/intents/drafts/questions",
      materialization: Path.join(root, "head"),
      files: %{"questions.md" => questions_md},
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
