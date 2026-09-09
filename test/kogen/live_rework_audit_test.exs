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
      receipt!("accept", [], "review-2") <>
        "\n" <> receipt!("rework", ["reviewer-notes.md is missing"], "review-1") <> "\n"
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
      receipt!("rework", ["reviewer-notes.md is missing"], "review-1") <>
        "\n" <> receipt!("accept", [], "review-2") <> "\n"
    )

    File.write!(
      Path.join(logs, "raw-stream-100-1.jsonl"),
      Jason.encode!(%{"type" => "thread.started", "thread_id" => "developer-1"}) <> "\n"
    )

    File.write!(
      Path.join(logs, "raw-stream-100-2.jsonl"),
      Jason.encode!(%{"type" => "thread.started", "thread_id" => "review-1"}) <> "\n"
    )

    File.write!(
      Path.join(logs, "raw-stream-100-3.jsonl"),
      Jason.encode!(%{"type" => "thread.started", "thread_id" => "developer-1"}) <> "\n"
    )

    File.write!(
      Path.join(logs, "raw-stream-100-4.jsonl"),
      Jason.encode!(%{"type" => "thread.started", "thread_id" => "review-2"}) <> "\n"
    )

    git_commit!(root)
    {root, logs}
  end

  defp evidence!(candidate),
    do:
      "- Candidate id: `#{candidate}`\n- Developer session id: `developer-1`\n- Reviewer session id: `review-2`\n- Outer resumptions used: 1\n"

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

  defp receipt!(verdict, findings, session),
    do: Jason.encode!(%{"verdict" => verdict, "findings" => findings, "session_id" => session})

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
