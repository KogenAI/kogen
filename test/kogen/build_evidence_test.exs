Code.require_file("../support/review_packet_audit.ex", __DIR__)
Code.require_file("../support/live_tracking_retention.ex", __DIR__)
Code.require_file("../support/live_rework_audit.ex", __DIR__)

defmodule Kogen.BuildEvidenceTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.{Evidence, Tracking}
  alias Kogen.{LiveReworkAudit, LiveTrackingRetention, ReviewPacketAudit}

  test "resolves only the exact bound archive and rejects absence, corruption, identity, and versions" do
    root = Path.join(System.tmp_dir!(), "kogen-evidence-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, ".kogen/runtime/scenario-tracking/build-1"))
    record_path = ".kogen/runtime/scenario-tracking/build-1/record.json"

    attempt = %{
      "number" => 0,
      "attempt_token" => "token-1",
      "status" => "accepted",
      "developer_session_id" => "developer-1",
      "reviewer_session" => "reviewer-1",
      "candidate_id" => "candidate-1"
    }

    record =
      Jason.encode!(%{
        "schema_version" => 1,
        "status" => "accepted",
        "intent" => %{"id" => "intent-1"},
        "attempts" => [attempt]
      })

    File.write!(Path.join(root, record_path), record)
    summary_path = Path.join(root, "build-summary.json")

    summary = %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => %{"id" => "intent-1"},
      "build_id" => "build-1",
      "candidate_id" => "candidate-1",
      "developer_session_id" => "developer-1",
      "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-1")],
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => 1,
        "path" => record_path,
        "sha256" => sha256(record),
        "byte_count" => byte_size(record)
      }
    }

    write_summary!(summary_path, summary)
    assert {:ok, %{"intent" => %{"id" => "intent-1"}}} = Evidence.resolve(summary_path, root)

    File.write!(Path.join(root, record_path), record <> " ")
    assert {:error, mismatch} = Evidence.resolve(summary_path, root)
    assert mismatch =~ "byte count mismatch"

    File.rm!(Path.join(root, record_path))
    assert {:error, missing} = Evidence.resolve(summary_path, root)
    assert missing =~ "unavailable"

    File.write!(Path.join(root, record_path), record)
    write_summary!(summary_path, put_in(summary, ["intent", "id"], "wrong"))
    assert {:error, identity} = Evidence.resolve(summary_path, root)
    assert identity =~ "identity mismatch"

    write_summary!(summary_path, Map.put(summary, "candidate_id", "wrong"))
    assert {:error, candidate} = Evidence.resolve(summary_path, root)
    assert candidate =~ "Candidate mismatch"

    write_summary!(summary_path, Map.put(summary, "build_id", "wrong"))
    assert {:error, build} = Evidence.resolve(summary_path, root)
    assert build =~ "Build identity mismatch"

    write_summary!(summary_path, Map.put(summary, "developer_session_id", "wrong"))
    assert {:error, session} = Evidence.resolve(summary_path, root)
    assert session =~ "Developer session mismatch"

    write_summary!(summary_path, Map.put(summary, "schema_version", 99))
    assert {:error, unsupported} = Evidence.resolve(summary_path, root)
    assert unsupported =~ "unsupported Build summary"

    write_summary!(summary_path, put_in(summary, ["full_record", "schema_version"], 99))
    assert {:error, unsupported_record} = Evidence.resolve(summary_path, root)
    assert unsupported_record =~ "unsupported bound tracking"

    assert_version_2_record_resolves!()
  end

  # Version 2 records add the Developer notes, Jev evidence and the
  # controller-built report; version 1 records above stay readable.
  defp assert_version_2_record_resolves! do
    root = Path.join(System.tmp_dir!(), "kogen-evidence-v2-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, ".kogen/runtime/scenario-tracking/build-2"))
    record_path = ".kogen/runtime/scenario-tracking/build-2/record.json"

    attempt = %{
      "number" => 0,
      "attempt_token" => "token-2",
      "status" => "accepted",
      "developer_session_id" => "developer-2",
      "reviewer_session" => "reviewer-2",
      "candidate_id" => "candidate-2",
      "developer_notes" => %{"text" => "Done."},
      "jev" => %{"outcome" => "answered"},
      "handoff" => %{"format" => "kogen-controller-handoff-report"}
    }

    record =
      Jason.encode!(%{
        "schema_version" => 2,
        "status" => "accepted",
        "intent" => %{"id" => "intent-2"},
        "attempts" => [attempt]
      })

    File.write!(Path.join(root, record_path), record)
    summary_path = Path.join(root, "build-summary.json")

    summary = %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => %{"id" => "intent-2"},
      "build_id" => "build-2",
      "candidate_id" => "candidate-2",
      "developer_session_id" => "developer-2",
      "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-2")],
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => 2,
        "path" => record_path,
        "sha256" => sha256(record),
        "byte_count" => byte_size(record)
      }
    }

    write_summary!(summary_path, summary)
    assert {:ok, %{"schema_version" => 2}} = Evidence.resolve(summary_path, root)

    # The binding must still name the record's own version.
    write_summary!(summary_path, put_in(summary, ["full_record", "schema_version"], 1))
    assert {:error, _mismatch} = Evidence.resolve(summary_path, root)
  end

  test "a summary carrying route resolves only when it matches the record's frozen route, and a legacy summary without route still resolves" do
    root =
      Path.join(System.tmp_dir!(), "kogen-evidence-route-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, ".kogen/runtime/scenario-tracking/build-1"))
    record_path = ".kogen/runtime/scenario-tracking/build-1/record.json"

    attempt = %{
      "number" => 0,
      "attempt_token" => "token-1",
      "status" => "accepted",
      "developer_session_id" => "developer-1",
      "reviewer_session" => "reviewer-1",
      "candidate_id" => "candidate-1"
    }

    record_route = %{
      "name" => "codex",
      "harness" => "codex",
      "shaping" => %{"model" => "gpt-5.6-sol", "effort" => "low"},
      "developer" => %{"model" => "gpt-5.6-sol", "effort" => "low"},
      "reviewer" => %{"model" => "gpt-5.6-terra", "effort" => "medium"},
      "helpers" => %{
        "scout" => %{"model" => "gpt-5.6-luna", "effort" => "low"},
        "worker" => %{"model" => "gpt-5.6-luna", "effort" => "medium"},
        "expert" => %{"model" => "gpt-5.6-sol", "effort" => "medium"}
      }
    }

    record =
      Jason.encode!(%{
        "schema_version" => 1,
        "status" => "accepted",
        "intent" => %{"id" => "intent-1"},
        "route" => record_route,
        "attempts" => [attempt]
      })

    File.write!(Path.join(root, record_path), record)
    summary_path = Path.join(root, "build-summary.json")

    base_summary = %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => %{"id" => "intent-1"},
      "build_id" => "build-1",
      "candidate_id" => "candidate-1",
      "developer_session_id" => "developer-1",
      "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-1")],
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => 1,
        "path" => record_path,
        "sha256" => sha256(record),
        "byte_count" => byte_size(record)
      }
    }

    # No route on the summary (legacy): still resolves.
    write_summary!(summary_path, base_summary)
    assert {:ok, %{"intent" => %{"id" => "intent-1"}}} = Evidence.resolve(summary_path, root)

    # Matching route (name + harness only): resolves.
    matching_summary = Map.put(base_summary, "route", %{"name" => "codex", "harness" => "codex"})
    write_summary!(summary_path, matching_summary)
    assert {:ok, %{"intent" => %{"id" => "intent-1"}}} = Evidence.resolve(summary_path, root)

    # Mismatched route: refused.
    mismatched_summary =
      Map.put(base_summary, "route", %{"name" => "claude", "harness" => "claude"})

    write_summary!(summary_path, mismatched_summary)
    assert {:error, mismatch} = Evidence.resolve(summary_path, root)
    assert mismatch =~ "route mismatch"
  end

  test "record citations resolve in both the sidecar form and the older inline form" do
    root = Path.join(System.tmp_dir!(), "kogen-evidence-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    dir = ".kogen/runtime/scenario-tracking/build-1"
    record_path = Path.join(dir, "record.json")
    File.mkdir_p!(Path.join(root, dir <> "/record-versions"))
    cited = ~s({"attempts":[]}\n)
    sidecar = Path.join(dir, "record-versions/#{sha256(cited)}.json")
    File.write!(Path.join(root, sidecar), cited)

    sidecar_form = %{
      "path" => record_path,
      "sha256" => sha256(cited),
      "byte_count" => byte_size(cited),
      "binding" => "controller_record_version",
      "sidecar" => sidecar
    }

    inline_form = %{
      "sha256" => Base.encode16(:crypto.hash(:sha256, cited)),
      "content_base64" => Base.encode64(cited),
      "binding" => "controller_record_version"
    }

    resolve = fn snapshot ->
      attempt = %{
        "number" => 0,
        "attempt_token" => "token-1",
        "status" => "accepted",
        "developer_session_id" => "developer-1",
        "reviewer_session" => "reviewer-1",
        "candidate_id" => "candidate-1",
        "reviewer_reference_snapshots" => %{record_path => snapshot},
        "reference_snapshots" => %{record_path => snapshot}
      }

      record =
        Jason.encode!(%{
          "schema_version" => 2,
          "intent" => %{"id" => "intent-1"},
          "attempts" => [attempt]
        })

      File.write!(Path.join(root, record_path), record)
      summary_path = Path.join(root, "build-summary.json")

      write_summary!(summary_path, %{
        "format" => "kogen-build-summary",
        "schema_version" => 1,
        "intent" => %{"id" => "intent-1"},
        "build_id" => "build-1",
        "candidate_id" => "candidate-1",
        "developer_session_id" => "developer-1",
        "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-1")],
        "full_record" => %{
          "format" => "kogen-scenario-tracking-record",
          "schema_version" => 2,
          "path" => record_path,
          "sha256" => sha256(record),
          "byte_count" => byte_size(record)
        }
      })

      Evidence.resolve(summary_path, root)
    end

    assert {:ok, _record} = resolve.(sidecar_form)
    assert {:ok, _record} = resolve.(inline_form)

    File.write!(Path.join(root, sidecar), cited <> " ")
    assert {:error, mismatch} = resolve.(sidecar_form)
    assert mismatch =~ "sidecar mismatch"
    assert {:ok, _record} = resolve.(inline_form)

    File.rm!(Path.join(root, sidecar))
    assert {:error, missing} = resolve.(sidecar_form)
    assert missing =~ "sidecar unavailable"
  end

  test "retained evidence copied out of a deleted fixture resolves its record-version sidecars beside the record" do
    base =
      Path.join(
        System.tmp_dir!(),
        "kogen-evidence-relocate-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(base) end)
    fixture = Path.join(base, "fixture")
    tracking_dir = Path.join(fixture, ".kogen/runtime/scenario-tracking/build-3")
    File.mkdir_p!(tracking_dir)
    record_path = Path.join(tracking_dir, "record.json")

    # The Reviewer cited the record itself, so Tracking retains a sidecar.
    cited = Jason.encode!(%{"schema_version" => 2, "status" => "in_progress"})
    assert {:ok, snapshot} = Tracking.retain_record_version(%{path: record_path}, cited)
    assert File.regular?(Path.join([tracking_dir, "record-versions", sha256(cited) <> ".json"]))

    attempt = %{
      "number" => 0,
      "attempt_token" => "token-3",
      "status" => "accepted",
      "developer_session_id" => "developer-3",
      "reviewer_session" => "reviewer-3",
      "candidate_id" => "candidate-3",
      "reviewer_reference_snapshots" => %{snapshot["path"] => snapshot}
    }

    record =
      Jason.encode!(%{
        "schema_version" => 2,
        "status" => "accepted",
        "intent" => %{"id" => "intent-3"},
        "attempts" => [attempt]
      })

    File.write!(record_path, record)

    summary = %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => %{"id" => "intent-3"},
      "build_id" => "build-3",
      "candidate_id" => "candidate-3",
      "developer_session_id" => "developer-3",
      "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-3")],
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => 2,
        "path" => Path.relative_to(record_path, fixture),
        "sha256" => sha256(record),
        "byte_count" => byte_size(record)
      }
    }

    # In place, the sidecar resolves at its checkout-relative locator.
    in_place = Path.join(fixture, "build-summary.json")
    write_summary!(in_place, summary)
    assert {:ok, _record} = Evidence.resolve(in_place, fixture)

    # Retain record, sidecars and summary the way the rework fixture does.
    retain = fn log_dir, copy_sidecars? ->
      destination = Path.join([log_dir, "scenario-tracking", "build-3", "record.json"])
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(record_path, destination)

      if copy_sidecars?,
        do: ReviewPacketAudit.preserve_record_versions!(record_path, destination)

      summary_path = Path.join(log_dir, "build-summary.json")
      write_summary!(summary_path, put_in(summary, ["full_record", "path"], destination))
      summary_path
    end

    retained = retain.(Path.join(base, "logs"), true)
    control = retain.(Path.join(base, "logs-without-sidecars"), false)
    File.rm_rf!(fixture)

    assert {:ok, %{"status" => "accepted"}} = Evidence.resolve(retained, Path.join(base, "logs"))

    assert {:error, missing} = Evidence.resolve(control, Path.join(base, "logs-without-sidecars"))
    assert missing =~ "sidecar unavailable"

    retained_sidecar =
      Path.join([
        base,
        "logs/scenario-tracking/build-3/record-versions",
        sha256(cited) <> ".json"
      ])

    File.write!(retained_sidecar, cited <> " ")
    assert {:error, altered} = Evidence.resolve(retained, Path.join(base, "logs"))
    assert altered =~ "sidecar mismatch"
  end

  test "Kogen.LiveTrackingRetention.preserve! retains a nested Build's whole scenario-tracking tree, including record-version sidecars, so the retained evidence still resolves after the fixture is deleted" do
    base =
      Path.join(
        System.tmp_dir!(),
        "kogen-tracking-retention-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(base) end)

    # Main case: retain, delete the fixture, and the retained Build evidence
    # still resolves.
    main = build_self_citing_fixture!(base, "main")
    log_dir = Path.join(base, "log-main")
    File.mkdir_p!(log_dir)

    assert :ok =
             LiveTrackingRetention.preserve!(main.fixture, main.complete_dir, log_dir)

    File.rm_rf!(main.fixture)
    assert :ok = LiveReworkAudit.audit_retained!(log_dir)

    # Control: a retained sidecar deleted afterward still fails resolution.
    missing = build_self_citing_fixture!(base, "missing")
    log_missing = Path.join(base, "log-missing")
    File.mkdir_p!(log_missing)

    assert :ok =
             LiveTrackingRetention.preserve!(missing.fixture, missing.complete_dir, log_missing)

    File.rm_rf!(missing.fixture)
    File.rm!(retained_sidecar_path(log_missing, missing))

    assert_raise ArgumentError, ~r/sidecar unavailable/, fn ->
      LiveReworkAudit.audit_retained!(log_missing)
    end

    # Control: a retained sidecar altered afterward still fails resolution.
    altered = build_self_citing_fixture!(base, "altered")
    log_altered = Path.join(base, "log-altered")
    File.mkdir_p!(log_altered)

    assert :ok =
             LiveTrackingRetention.preserve!(altered.fixture, altered.complete_dir, log_altered)

    File.rm_rf!(altered.fixture)
    sidecar_path = retained_sidecar_path(log_altered, altered)
    File.write!(sidecar_path, File.read!(sidecar_path) <> " ")

    assert_raise ArgumentError, ~r/sidecar mismatch/, fn ->
      LiveReworkAudit.audit_retained!(log_altered)
    end

    # The live fixture no longer defines its own private retention helper and
    # calls the shared support module at both retention call sites instead.
    live_test_source = __DIR__ |> Path.join("live_shape_to_build_test.exs") |> File.read!()

    refute live_test_source =~ "defp preserve_tracking",
           "the live fixture must no longer define a private preserve_tracking/3"

    assert live_test_source =~ "Kogen.LiveTrackingRetention.preserve!(",
           "the live fixture must call Kogen.LiveTrackingRetention.preserve!/3"
  end

  # Builds a disposable fixture whose nested Build tracking record cites its
  # own bytes -- a real `record-versions/` sidecar written by
  # `Kogen.Build.Tracking.retain_record_version/2` -- plus the
  # `build-summary.json` a real Build would leave beside it.
  defp build_self_citing_fixture!(base, suffix) do
    fixture = Path.join(base, "fixture-#{suffix}")
    build_id = "build-#{suffix}"
    tracking_dir = Path.join(fixture, ".kogen/runtime/scenario-tracking/#{build_id}")
    File.mkdir_p!(tracking_dir)
    record_path = Path.join(tracking_dir, "record.json")

    cited = Jason.encode!(%{"schema_version" => 2, "status" => "in_progress"})
    assert {:ok, snapshot} = Tracking.retain_record_version(%{path: record_path}, cited)

    attempt = %{
      "number" => 0,
      "attempt_token" => "token-#{suffix}",
      "status" => "accepted",
      "developer_session_id" => "developer-#{suffix}",
      "reviewer_session" => "reviewer-#{suffix}",
      "candidate_id" => "candidate-#{suffix}",
      "reviewer_reference_snapshots" => %{snapshot["path"] => snapshot}
    }

    record =
      Jason.encode!(%{
        "schema_version" => 2,
        "status" => "accepted",
        "intent" => %{"id" => "intent-#{suffix}"},
        "attempts" => [attempt]
      })

    File.write!(record_path, record)

    complete_dir = Path.join(fixture, ".kogen/intents/complete/tracking-retention-#{suffix}")
    File.mkdir_p!(complete_dir)
    summary_path = Path.join(complete_dir, "build-summary.json")

    summary = %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => %{"id" => "intent-#{suffix}"},
      "build_id" => build_id,
      "candidate_id" => "candidate-#{suffix}",
      "developer_session_id" => "developer-#{suffix}",
      "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-#{suffix}")],
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => 2,
        "path" => Path.relative_to(record_path, fixture),
        "sha256" => sha256(record),
        "byte_count" => byte_size(record)
      }
    }

    write_summary!(summary_path, summary)

    %{
      fixture: fixture,
      complete_dir: complete_dir,
      build_id: build_id,
      sidecar_sha256: sha256(cited)
    }
  end

  defp retained_sidecar_path(log_dir, %{build_id: build_id, sidecar_sha256: sha256}) do
    Path.join([log_dir, "scenario-tracking", build_id, "record-versions", sha256 <> ".json"])
  end

  defp write_summary!(path, summary), do: File.write!(path, Jason.encode!(summary))
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
