Code.require_file("../support/live_rework_audit.ex", __DIR__)

defmodule Kogen.LiveReworkAuditTest do
  use ExUnit.Case, async: true

  @slug "live-reviewer-rework-probe"
  @intent "01960000-0000-7000-8000-00000000beef"

  test "accepts a complete ordered rework audit with inspectable Candidate trees" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)

    assert %{candidate: candidate, developer_session_id: "developer-1", archived_check_count: 1} =
             Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)

    assert is_binary(candidate)
  end

  test "retained compact summary resolves its copied archive after the fixture is gone" do
    root =
      Path.join(System.tmp_dir!(), "kogen-retained-audit-#{System.unique_integer([:positive])}")

    logs = Path.join(root, "logs")
    archive = Path.join([logs, "scenario-tracking", "build-1", "record.json"])
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.dirname(archive))

    attempt = %{
      "number" => 0,
      "attempt_token" => "token-1",
      "status" => "accepted",
      "developer_session_id" => "developer-1",
      "reviewer_session" => "reviewer-1",
      "candidate_id" => "candidate-1"
    }

    bytes =
      Jason.encode!(%{
        "schema_version" => 1,
        "status" => "accepted",
        "intent" => %{"id" => @intent},
        "attempts" => [attempt]
      })

    File.write!(archive, bytes)

    summary = %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => %{"id" => @intent},
      "build_id" => "build-1",
      "candidate_id" => "candidate-1",
      "developer_session_id" => "developer-1",
      "attempts" => [Map.put(attempt, "reviewer_session_id", "reviewer-1")],
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => 1,
        "path" => archive,
        "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        "byte_count" => byte_size(bytes)
      }
    }

    File.write!(Path.join(logs, "build-summary.json"), Jason.encode!(summary))
    assert :ok = Kogen.LiveReworkAudit.audit_retained!(logs)
  end

  test "rejects missing archived initial Check evidence" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)
    File.rm!(Path.join(logs, "verification-history-1.jsonl"))

    assert_raise ArgumentError, ~r/missing archived initial Check history/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "rejects Reviewer receipts in the wrong temporal order" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)

    File.write!(
      Path.join(logs, "reviewer-verdicts.jsonl"),
      receipt!("accept", [], "review-2", "final-tree", "attempt-1") <>
        "\n" <>
        receipt!(
          "rework",
          ["reviewer-notes.md is missing"],
          "review-1",
          "final-tree",
          "attempt-1"
        ) <> "\n"
    )

    assert_raise ArgumentError, ~r/first Reviewer receipt must be rework/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "rejects an initial checked Candidate that already has the notes file" do
    {fixture, logs} = audit_fixture!(initial_notes?: true)
    on_exit(fn -> File.rm_rf!(fixture) end)

    assert_raise ArgumentError,
                 ~r/initial checked Candidate already contains reviewer-notes.md/,
                 fn ->
                   Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
                 end
  end

  test "rejects raw-stream captures that place acceptance before the exact resume" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)

    File.rename!(
      Path.join(logs, "raw-stream-100-2.jsonl"),
      Path.join(logs, "raw-stream-100-9.jsonl")
    )

    File.rename!(
      Path.join(logs, "raw-stream-100-4.jsonl"),
      Path.join(logs, "raw-stream-100-2.jsonl")
    )

    File.rename!(
      Path.join(logs, "raw-stream-100-9.jsonl"),
      Path.join(logs, "raw-stream-100-4.jsonl")
    )

    assert_raise ArgumentError, ~r/retained stream capture order/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "rejects a final Check timestamp that predates the initial archived Check" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)

    [record] =
      Path.join(fixture, ".kogen/runtime/verification-history.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    File.write!(
      Path.join(fixture, ".kogen/runtime/verification-history.jsonl"),
      Jason.encode!(Map.put(record, "finished_at", "2026-09-08T23:59:59Z")) <> "\n"
    )

    File.write!(
      Path.join(fixture, ".kogen/runtime/verification.json"),
      Jason.encode!(Map.put(record, "finished_at", "2026-09-08T23:59:59Z"))
    )

    assert_raise ArgumentError, ~r/final Check predates the archived initial Check/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "rejects a current Check that disagrees with the last history record" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)
    history = Path.join(fixture, ".kogen/runtime/verification-history.jsonl")
    record = history |> File.read!() |> String.trim() |> Jason.decode!()

    File.write!(history, Jason.encode!(Map.put(record, "status", "failed")) <> "\n", [:append])

    assert_raise ArgumentError,
                 ~r/current Check must match the last retained history record/,
                 fn ->
                   Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
                 end
  end

  test "rejects a replacement Developer thread even with correct files and Checks" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)

    File.write!(
      Path.join(logs, "raw-stream-100-3.jsonl"),
      Jason.encode!(%{"type" => "thread.started", "thread_id" => "replacement"}) <> "\n"
    )

    assert_raise ArgumentError, ~r/exact Developer thread launched and resumed/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "requires exactly one resumption rather than a matching numeric prefix" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)
    evidence = Path.join(fixture, ".kogen/intents/complete/#{@slug}/evidence.md")

    File.write!(
      evidence,
      String.replace(File.read!(evidence), "resumptions used: 1", "resumptions used: 10")
    )

    assert_raise ArgumentError, ~r/exactly one outer resumption/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "owner audit rejects an incomplete required native completion" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)

    File.write!(
      Path.join(logs, "raw-stream-100-3.jsonl"),
      Jason.encode!(%{"type" => "thread.started", "thread_id" => "developer-1"}) <> "\n"
    )

    assert_raise ArgumentError, ~r/one turn.completed event/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "owner audit rejects a required capture bound to the wrong identity" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)
    write_stream!(logs, 3, "replacement-developer")

    assert_raise ArgumentError, ~r/exact Developer thread launched and resumed/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "rejects a Developer invocation that still carries a handoff schema" do
    {fixture, logs} = audit_fixture!(legacy_schema?: true)
    on_exit(fn -> File.rm_rf!(fixture) end)

    assert_raise ArgumentError, ~r/no handoff schema/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "rejects a Developer invocation whose digest disagrees with the recorded notes" do
    {fixture, logs} = audit_fixture!(digest_mismatch?: true)
    on_exit(fn -> File.rm_rf!(fixture) end)

    assert_raise ArgumentError, ~r/digest must match/, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  test "owner audit rejects malformed structured Reviewer evidence" do
    {fixture, logs} = audit_fixture!()
    on_exit(fn -> File.rm_rf!(fixture) end)
    receipts = Path.join(logs, "reviewer-verdicts.jsonl")
    [first, second] = receipts |> File.read!() |> String.split("\n", trim: true)
    malformed = second |> Jason.decode!() |> Map.delete("scenarios") |> Jason.encode!()
    File.write!(receipts, first <> "\n" <> malformed <> "\n")

    assert_raise ArgumentError, fn ->
      Kogen.LiveReworkAudit.audit!(fixture, logs, slug: @slug, intent_id: @intent)
    end
  end

  defp audit_fixture!(options \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-live-rework-audit-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    logs = Path.join(root, "logs")
    complete = Path.join(root, ".kogen/intents/complete/#{@slug}")
    runtime = Path.join(root, ".kogen/runtime")
    File.mkdir_p!(complete)
    File.mkdir_p!(runtime)
    File.mkdir_p!(logs)
    File.write!(Path.join(root, "dummy.txt"), "reviewer-rework-k4q9z\n")
    File.write!(Path.join(root, "reviewer-notes.md"), "reviewer-confirmed-k4q9z\n")
    git_baseline!(root)

    {initial_candidate, final_candidate} =
      candidate_trees!(root, Keyword.get(options, :initial_notes?, false))

    File.write!(Path.join(complete, "evidence.md"), evidence!(final_candidate))

    File.write!(
      Path.join(complete, "scenario-tracking.json"),
      tracking_fixture!(
        legacy_schema?: Keyword.get(options, :legacy_schema?, false),
        digest_mismatch?: Keyword.get(options, :digest_mismatch?, false)
      )
    )

    File.write!(
      Path.join(runtime, "verification.json"),
      check!(final_candidate, "2026-09-09T00:00:02Z")
    )

    File.write!(
      Path.join(runtime, "verification-history.jsonl"),
      check!(final_candidate, "2026-09-09T00:00:02Z") <> "\n"
    )

    File.write!(
      Path.join(logs, "verification-history-1.jsonl"),
      check!(initial_candidate, "2026-09-09T00:00:01Z") <> "\n"
    )

    File.write!(
      Path.join(logs, "reviewer-verdicts.jsonl"),
      receipt!(
        "rework",
        ["reviewer-notes.md is missing"],
        "review-1",
        initial_candidate,
        "attempt-1"
      ) <>
        "\n" <> receipt!("accept", [], "review-2", final_candidate, "attempt-2") <> "\n"
    )

    write_stream!(logs, 1, "developer-1")
    write_stream!(logs, 2, "review-1")
    write_stream!(logs, 3, "developer-1")
    write_stream!(logs, 4, "review-2")

    git_commit!(root)
    {root, logs}
  end

  defp evidence!(candidate),
    do:
      "- Candidate id: `#{candidate}`\n- Developer session id: `developer-1`\n- Reviewer session id: `review-2`\n- Outer resumptions used: 1\n"

  defp tracking_fixture!(options) do
    legacy_schema? = Keyword.get(options, :legacy_schema?, false)
    digest_mismatch? = Keyword.get(options, :digest_mismatch?, false)

    attempts =
      for {token, index} <- Enum.with_index(["attempt-1", "attempt-2"], 1) do
        text = "unverified Developer notes for #{token}"
        sha256 = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
        candidate_id = "candidate-#{index}"

        message_sha256 =
          if digest_mismatch? and index == 1, do: String.duplicate("0", 64), else: sha256

        invocation = %{
          "outcome" => "settled",
          "session_id" => "developer-1",
          "message" => text,
          "message_sha256" => message_sha256
        }

        invocation =
          if legacy_schema? and index == 1,
            do:
              Map.put(
                invocation,
                "schema",
                Jason.encode!(%{"properties" => %{"attempt_token" => %{"enum" => [token]}}})
              ),
            else: invocation

        %{
          "attempt_token" => token,
          "candidate_id" => candidate_id,
          "developer_session_id" => "developer-1",
          "outcome" => "settled",
          "developer_notes" => %{
            "label" =>
              "unverified Developer notes; recorded verbatim and never parsed by Kogen code",
            "sha256" => sha256,
            "byte_count" => byte_size(text),
            "content_base64" => Base.encode64(text),
            "text" => text
          },
          "developer_invocation" => invocation,
          "handoff" => %{
            "format" => "kogen-controller-handoff-report",
            "built_by" => "controller",
            "attempt_token" => token,
            "candidate_id" => candidate_id
          },
          "jev" => %{
            "outcome" => "answered",
            "model" => "jev-1.13.0",
            "request" => %{
              "body" => "{}",
              "sha256" => Base.encode16(:crypto.hash(:sha256, "{}"), case: :lower)
            }
          }
        }
      end

    Jason.encode!(%{"attempts" => attempts})
  end

  defp write_stream!(logs, sequence, session) do
    body =
      [
        %{"type" => "thread.started", "thread_id" => session},
        %{"type" => "turn.completed", "usage" => %{"input_tokens" => 1}}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    File.write!(Path.join(logs, "raw-stream-100-#{sequence}.jsonl"), body <> "\n")
  end

  defp check!(candidate, finished_at),
    do:
      Jason.encode!(%{
        "candidate" => candidate,
        "status" => "passed",
        "target" => "check",
        "exit_code" => 0,
        "session_id" => "developer-1",
        "finished_at" => finished_at
      })

  defp receipt!(verdict, findings, session, candidate, attempt_token) do
    scenario_status = if verdict == "accept", do: "satisfied", else: "needs_rework"

    Jason.encode!(%{
      "candidate_id" => candidate,
      "attempt_token" => attempt_token,
      "verdict" => verdict,
      "session_id" => session,
      "scenarios" => [
        %{
          "id" => "reviewer-directed-rework",
          "status" => scenario_status,
          "reason" =>
            if(verdict == "accept",
              do: "final bytes include reviewer-notes.md",
              else: "reviewer-notes.md is missing"
            ),
          "evidence" => [%{"path" => "reviewer-notes.md", "locator" => "entire file"}]
        }
      ],
      "dispositions" => [],
      "findings" =>
        Enum.map(findings, fn finding ->
          %{
            "scenario_ids" => ["reviewer-directed-rework"],
            "reason" => finding,
            "evidence" => [%{"path" => "reviewer-notes.md", "locator" => "missing"}]
          }
        end)
    })
  end

  defp git_baseline!(root) do
    env = [
      {"GIT_AUTHOR_NAME", "Audit"},
      {"GIT_AUTHOR_EMAIL", "audit@example.invalid"},
      {"GIT_COMMITTER_NAME", "Audit"},
      {"GIT_COMMITTER_EMAIL", "audit@example.invalid"}
    ]

    File.write!(Path.join(root, "baseline.txt"), "baseline\n")
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: root)
    {_out, 0} = System.cmd("git", ["add", "baseline.txt"], cd: root)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "baseline"], cd: root, env: env)
  end

  defp candidate_trees!(root, initial_notes?) do
    {_out, 0} = System.cmd("git", ["add", "dummy.txt", "reviewer-notes.md"], cd: root)
    {final_candidate, 0} = System.cmd("git", ["write-tree"], cd: root)
    private_index = Path.join(root, "private-index")
    File.cp!(Path.join(root, ".git/index"), private_index)

    env = [{"GIT_INDEX_FILE", private_index}]

    removed_path = if initial_notes?, do: "dummy.txt", else: "reviewer-notes.md"

    {_out, 0} =
      System.cmd("git", ["update-index", "--force-remove", removed_path],
        cd: root,
        env: env
      )

    {initial_candidate, 0} = System.cmd("git", ["write-tree"], cd: root, env: env)
    File.rm!(private_index)
    {String.trim(initial_candidate), String.trim(final_candidate)}
  end

  defp git_commit!(root) do
    env = [
      {"GIT_AUTHOR_NAME", "Audit"},
      {"GIT_AUTHOR_EMAIL", "audit@example.invalid"},
      {"GIT_COMMITTER_NAME", "Audit"},
      {"GIT_COMMITTER_EMAIL", "audit@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["add", "."], cd: root)

    {_out, 0} =
      System.cmd(
        "git",
        ["commit", "-q", "-m", "audit\n\nKogen-Intent-ID: #{@intent}\nKogen-Intent: #{@slug}"],
        cd: root,
        env: env
      )
  end
end
