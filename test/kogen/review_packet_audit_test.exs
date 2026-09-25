Code.require_file("../support/review_packet_audit.ex", __DIR__)

defmodule Kogen.ReviewPacketAuditTest do
  use ExUnit.Case, async: true

  alias Kogen.ReviewPacketAudit

  @build_id "build-1"

  describe "canonical fixture root outside the checkout" do
    test "resolves an already-canonical path idempotently" do
      root = unique_tmp_dir!("plain")
      on_exit(fn -> File.rm_rf!(root) end)
      canonical = ReviewPacketAudit.canonical_path!(root)
      assert Path.type(canonical) == :absolute
      assert ReviewPacketAudit.canonical_path!(canonical) == canonical
    end

    test "resolves a symlinked path to its real, symlink-free target" do
      target = unique_tmp_dir!("target")

      alias_path =
        Path.join(System.tmp_dir!(), "kogen-alias-#{System.unique_integer([:positive])}")

      File.ln_s!(target, alias_path)
      on_exit(fn -> File.rm_rf!(target) end)
      on_exit(fn -> File.rm(alias_path) end)

      resolved = ReviewPacketAudit.canonical_path!(alias_path)
      assert resolved == ReviewPacketAudit.canonical_path!(target)
      refute resolved == alias_path
    end

    test "accepts a canonical tmp path that lies outside the checkout" do
      checkout = unique_tmp_dir!("checkout")
      root = unique_tmp_dir!("outside")
      on_exit(fn -> File.rm_rf!(checkout) end)
      on_exit(fn -> File.rm_rf!(root) end)

      assert ReviewPacketAudit.assert_outside_checkout!(root, checkout) ==
               ReviewPacketAudit.canonical_path!(root)
    end

    test "rejects a fixture root nested inside the checkout" do
      checkout = unique_tmp_dir!("checkout-inside")
      nested = Path.join(checkout, "nested-fixture")
      on_exit(fn -> File.rm_rf!(checkout) end)

      assert_raise ExUnit.AssertionError, ~r/must lie outside the checkout/, fn ->
        ReviewPacketAudit.assert_outside_checkout!(nested, checkout)
      end
    end

    test "rejects the checkout root itself" do
      checkout = unique_tmp_dir!("checkout-self")
      on_exit(fn -> File.rm_rf!(checkout) end)

      assert_raise ExUnit.AssertionError, ~r/must lie outside the checkout/, fn ->
        ReviewPacketAudit.assert_outside_checkout!(checkout, checkout)
      end
    end
  end

  describe "evidence retention survives fixture removal" do
    test "sidecars, packets and the complete package are copied before the source is removed" do
      fixture = unique_tmp_dir!("evidence-fixture")
      log_dir = unique_tmp_dir!("evidence-logs")
      on_exit(fn -> File.rm_rf!(fixture) end)
      on_exit(fn -> File.rm_rf!(log_dir) end)

      tracking = Path.join(fixture, ".kogen/runtime/scenario-tracking/#{@build_id}")
      File.mkdir_p!(Path.join(tracking, "record-versions"))
      File.mkdir_p!(Path.join(tracking, "review-packets"))
      File.write!(Path.join(tracking, "record.json"), "{}")
      File.write!(Path.join(tracking, "record-versions/deadbeef.json"), "{}")
      File.write!(Path.join(tracking, "review-packets/0.json"), "{}")

      complete = Path.join(fixture, ".kogen/intents/complete/probe")
      File.mkdir_p!(complete)
      File.write!(Path.join(complete, "evidence.md"), "evidence\n")

      retained = ReviewPacketAudit.retain_evidence!(fixture, log_dir, "probe")
      assert retained.build_ids == [@build_id]

      File.rm_rf!(fixture)

      assert File.regular?(Path.join(retained.scenario_tracking_dir, "#{@build_id}/record.json"))

      assert File.regular?(
               Path.join(
                 retained.scenario_tracking_dir,
                 "#{@build_id}/record-versions/deadbeef.json"
               )
             )

      assert File.regular?(
               Path.join(retained.scenario_tracking_dir, "#{@build_id}/review-packets/0.json")
             )

      assert File.regular?(Path.join(retained.complete_dir, "evidence.md"))
    end
  end

  describe "packet audit against retained evidence" do
    test "a well-formed retained Build passes the audit" do
      {log_dir, candidate_dir} = passing_fixture!()

      summary =
        ReviewPacketAudit.audit!(log_dir, @build_id, {:dir, candidate_dir})

      assert summary["build_id"] == @build_id
      assert length(summary["packets"]) == 1
      assert length(summary["reviewer_tool_calls"]) == 1
      assert summary["candidate_citation"]["path"] == "dummy.txt"
      assert File.regular?(Path.join(log_dir, "review-packet-audit.json"))
    end

    test "fails when the Reviewer stream only names the packet in prompt text" do
      {log_dir, candidate_dir} = passing_fixture!(tool_call_names_packet?: false)

      assert_raise ExUnit.AssertionError, ~r/no tool call naming/, fn ->
        ReviewPacketAudit.audit!(log_dir, @build_id, {:dir, candidate_dir})
      end
    end

    test "fails on a packet digest mismatch" do
      {log_dir, candidate_dir} = passing_fixture!(digest_mismatch?: true)

      assert_raise ExUnit.AssertionError, ~r/sha256 does not match/, fn ->
        ReviewPacketAudit.audit!(log_dir, @build_id, {:dir, candidate_dir})
      end
    end

    test "fails when the record inlines its own bytes as content_base64" do
      {log_dir, candidate_dir} = passing_fixture!(inline_self_reference?: true)

      assert_raise ExUnit.AssertionError, ~r/must not inline the record's own bytes/, fn ->
        ReviewPacketAudit.audit!(log_dir, @build_id, {:dir, candidate_dir})
      end
    end

    test "fails when the accepting verdict cites no Candidate file" do
      {log_dir, candidate_dir} = passing_fixture!(no_candidate_citation?: true)

      assert_raise ExUnit.AssertionError, ~r/must cite at least one Candidate file/, fn ->
        ReviewPacketAudit.audit!(log_dir, @build_id, {:dir, candidate_dir})
      end
    end
  end

  defp unique_tmp_dir!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-review-packet-audit-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  # Builds a retained-evidence tree (as ReviewPacketAudit.retain_evidence!
  # would have produced) plus a plain "Candidate" directory, standing in for
  # the fixture's git object database once it has been removed.
  defp passing_fixture!(options \\ []) do
    log_dir = unique_tmp_dir!("logs")
    on_exit(fn -> File.rm_rf!(log_dir) end)

    candidate_dir = unique_tmp_dir!("candidate")
    on_exit(fn -> File.rm_rf!(candidate_dir) end)
    File.write!(Path.join(candidate_dir, "dummy.txt"), "reviewer-rework-k4q9z\n")

    tracking = Path.join([log_dir, "scenario-tracking", @build_id])
    File.mkdir_p!(Path.join(tracking, "review-packets"))

    packet_json = %{
      "schema_version" => 1,
      "build_id" => @build_id,
      "attempt_number" => 0,
      "attempt_token" => "attempt-token-1",
      "candidate_id" => "candidate-1",
      "scenario_ids" => ["bounded-review-packet"],
      "risk_ids" => [],
      "handoff" => %{},
      "developer_notes" => %{},
      "receipts" => [],
      "open_findings" => [],
      "superseded_objection" => nil,
      "omitted" => [],
      "record" => %{
        "path" => ".kogen/runtime/scenario-tracking/#{@build_id}/record.json",
        "byte_count" => 2
      }
    }

    canonical_packet_bytes = Jason.encode!(packet_json)
    correct_digest = Base.encode16(:crypto.hash(:sha256, canonical_packet_bytes), case: :lower)

    written_packet_bytes =
      if Keyword.get(options, :digest_mismatch?, false),
        do: Jason.encode!(Map.put(packet_json, "attempt_number", 1)),
        else: canonical_packet_bytes

    packet_path = Path.join(tracking, "review-packets/0.json")
    File.write!(packet_path, written_packet_bytes)

    review_packet_entry = %{
      "path" => ".kogen/runtime/scenario-tracking/#{@build_id}/review-packets/0.json",
      "sha256" => correct_digest,
      "byte_count" => byte_size(canonical_packet_bytes),
      "attempt_token" => "attempt-token-1",
      "candidate_id" => "candidate-1"
    }

    evidence =
      if Keyword.get(options, :no_candidate_citation?, false),
        do: [],
        else: [%{"path" => "dummy.txt", "locator" => "candidate:dummy.txt"}]

    attempt = %{
      "number" => 0,
      "attempt_token" => "attempt-token-1",
      "candidate_id" => "candidate-1",
      "reviewer_session" => "reviewer-1",
      "review_packet" => review_packet_entry,
      "verdict" => %{
        "scenarios" => [
          %{"id" => "bounded-review-packet", "status" => "satisfied", "evidence" => evidence}
        ],
        "dispositions" => []
      },
      "developer_reference_snapshots" => %{},
      "reviewer_reference_snapshots" =>
        if Keyword.get(options, :inline_self_reference?, false) do
          %{
            ".kogen/runtime/scenario-tracking/#{@build_id}/record.json" => %{
              "content_base64" => Base.encode64("{}")
            }
          }
        else
          %{}
        end,
      "reference_snapshots" => %{}
    }

    record = %{"attempts" => [attempt]}
    File.write!(Path.join(tracking, "record.json"), Jason.encode!(record))

    raw_log_dir = Path.join(log_dir, "build-raw-streams")
    File.mkdir_p!(raw_log_dir)

    names_packet? = Keyword.get(options, :tool_call_names_packet?, true)

    events =
      [
        %{"type" => "system", "subtype" => "init", "session_id" => "reviewer-1"},
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Read",
                "input" =>
                  if(names_packet?,
                    do: %{"file_path" => review_packet_entry["path"]},
                    else: %{"file_path" => "dummy.txt"}
                  )
              }
            ]
          }
        },
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "text",
                "text" => "I will inspect #{review_packet_entry["path"]} first."
              }
            ]
          }
        },
        %{"type" => "result", "subtype" => "success", "duration_ms" => 4200}
      ]

    body = Enum.map_join(events, "\n", &Jason.encode!/1)
    File.write!(Path.join(raw_log_dir, "raw-stream-100-1.jsonl"), body <> "\n")

    {log_dir, candidate_dir}
  end
end
