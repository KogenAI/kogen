defmodule Kogen.BuildEvidenceTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Evidence

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

  defp write_summary!(path, summary), do: File.write!(path, Jason.encode!(summary))
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
