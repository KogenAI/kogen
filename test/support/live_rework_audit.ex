defmodule Kogen.LiveReworkAudit do
  @moduledoc false
  Code.require_file("scenario_semantic.ex", __DIR__)

  # The live fixture deliberately retains these records outside its disposable
  # working tree. This module is intentionally test support: Build remains the
  # authority for lifecycle transitions, while the live driver audits the
  # provider-backed history after the fact.
  @required_notes "reviewer-confirmed-k4q9z\n"
  @required_dummy "reviewer-rework-k4q9z\n"

  def audit!(fixture, raw_log_dir, options) do
    slug = Keyword.fetch!(options, :slug)
    intent_id = Keyword.fetch!(options, :intent_id)
    complete_dir = Path.join(fixture, ".kogen/intents/complete/#{slug}")
    evidence_path = Path.join(complete_dir, "evidence.md")
    current_history = Path.join(fixture, ".kogen/runtime/verification-history.jsonl")
    current_record = Path.join(fixture, ".kogen/runtime/verification.json")

    require_file!(evidence_path, "Complete evidence")
    require_file!(current_history, "current Verification Record history")
    require_file!(current_record, "current Verification Record")
    require_exact!(Path.join(fixture, "dummy.txt"), @required_dummy, "final dummy.txt")

    require_exact!(
      Path.join(fixture, "reviewer-notes.md"),
      @required_notes,
      "final reviewer-notes.md"
    )

    evidence = File.read!(evidence_path)
    candidate = evidence_value!(evidence, "Candidate id")
    developer = evidence_value!(evidence, "Developer session id")
    accepting_reviewer = evidence_value!(evidence, "Reviewer session id")

    require!(
      Regex.match?(~r/^- Outer resumptions used: 1$/m, evidence),
      "Complete evidence must report exactly one outer resumption"
    )

    receipts = reviewer_receipts!(raw_log_dir)
    {rework_receipt, accept_receipt} = ordered_receipts!(receipts, accepting_reviewer, developer)
    rework_token = rework_receipt["attempt_token"]
    accept_token = accept_receipt["attempt_token"]

    require!(
      is_binary(rework_token) and rework_token != "",
      "Reviewer rework receipt needs an attempt token"
    )

    require!(
      is_binary(accept_token) and accept_token != "",
      "accepting Reviewer receipt needs an attempt token"
    )

    require!(
      rework_token != accept_token,
      "Reviewer rework and acceptance must bind distinct attempts"
    )

    {archived_records, current_records} = check_records!(raw_log_dir, current_history)
    current = json_file!(current_record, "current Verification Record")
    current_pass!(current, candidate, developer)

    require!(
      List.last(current_records) == current,
      "current Check must match the last retained history record"
    )

    final_candidate_bytes!(fixture, candidate)

    initial_candidate =
      passing_check_sequence!(archived_records, current_records, candidate, developer)

    reviewer_semantics!(rework_receipt, initial_candidate, rework_token, "rework")
    reviewer_semantics!(accept_receipt, candidate, accept_token, "accept")
    require_actionable_omission!(rework_receipt)

    initial_omission!(fixture, initial_candidate)

    developer_resume!(
      raw_log_dir,
      developer,
      rework_receipt["session_id"],
      accept_receipt["session_id"]
    )

    commit_provenance!(fixture, slug, intent_id)

    %{
      candidate: candidate,
      developer_session_id: developer,
      rework_reviewer_session_id: rework_receipt["session_id"],
      accepting_reviewer_session_id: accept_receipt["session_id"],
      archived_check_count: length(archived_records),
      current_check_count: length(current_records)
    }
  end

  defp reviewer_receipts!(dir) do
    path = Path.join(dir, "reviewer-verdicts.jsonl")
    require_file!(path, "ordered Reviewer receipt log")
    lines!(path, "ordered Reviewer receipt log")
  end

  defp ordered_receipts!(receipts, accepting_reviewer, developer) do
    require!(length(receipts) == 2, "expected exactly two ordered Reviewer receipts")

    [rework, accept] = receipts

    require!(rework["verdict"] == "rework", "first Reviewer receipt must be rework")
    require!(accept["verdict"] == "accept", "second Reviewer receipt must be accept")

    require!(
      accept["session_id"] == accepting_reviewer,
      "accepting Reviewer must match Complete evidence"
    )

    reviewer_ids = [rework["session_id"], accept["session_id"]]

    require!(
      Enum.all?(reviewer_ids, &(is_binary(&1) and &1 != "")),
      "Reviewer receipts need session ids"
    )

    require!(
      Enum.uniq(reviewer_ids) == reviewer_ids,
      "Reviewer rework and acceptance must use distinct sessions"
    )

    require!(
      developer not in reviewer_ids,
      "Reviewer sessions must differ from Developer session"
    )

    {rework, accept}
  end

  defp require_actionable_omission!(receipt) do
    findings = receipt["findings"]

    require!(
      is_list(findings) and findings != [],
      "first Reviewer rework must have actionable findings"
    )

    text =
      findings
      |> Enum.map(& &1["reason"])
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    require!(
      String.contains?(text, "reviewer-notes.md"),
      "first Reviewer findings must identify reviewer-notes.md"
    )
  end

  defp reviewer_semantics!(receipt, candidate, attempt_token, verdict) do
    Kogen.ScenarioSemantic.review_response!(receipt, %{
      candidate_id: candidate,
      attempt_token: attempt_token,
      scenario_ids: ["reviewer-directed-rework"]
    })

    require!(receipt["verdict"] == verdict, "Reviewer receipt has the wrong semantic verdict")
  end

  defp check_records!(raw_log_dir, current_history) do
    archives =
      raw_log_dir
      |> Path.join("verification-history-*.jsonl")
      |> Path.wildcard()
      |> Enum.sort()

    require!(archives != [], "missing archived initial Check history")

    {Enum.flat_map(archives, &lines!(&1, "archived Verification Record history")),
     lines!(current_history, "current Verification Record history")}
  end

  defp passing_check_sequence!(archived, current, final_candidate, developer) do
    archived_passes = Enum.filter(archived, &passing_for?(&1, developer))
    current_passes = Enum.filter(current, &passing_for?(&1, developer))

    require!(archived_passes != [], "initial Developer turn needs an archived passing Check")
    require!(current_passes != [], "resumed Developer turn needs a current passing Check")

    require!(
      Enum.any?(current_passes, &(&1["candidate"] == final_candidate)),
      "current passing Check must bind the final Candidate"
    )

    require!(
      Enum.any?(archived_passes, &(&1["candidate"] != final_candidate)),
      "archived passing Check must bind the pre-rework Candidate"
    )

    initial = List.last(archived_passes)
    final = List.last(current_passes)
    checked_before!(initial, final)
    initial["candidate"]
  end

  defp current_pass!(record, candidate, developer) do
    require!(
      passing_for?(record, developer),
      "current Verification Record must be a passing Check for the Developer"
    )

    require!(
      record["candidate"] == candidate,
      "current Verification Record must bind the final Candidate"
    )
  end

  defp initial_omission!(fixture, initial_candidate) do
    {object_type, 0} =
      System.cmd("git", ["cat-file", "-t", initial_candidate],
        cd: fixture,
        stderr_to_stdout: true
      )

    require!(
      String.trim(object_type) == "tree",
      "initial Check Candidate is not an inspectable Git tree"
    )

    {names, 0} =
      System.cmd("git", ["ls-tree", "--name-only", initial_candidate, "--", "reviewer-notes.md"],
        cd: fixture
      )

    require!(
      String.trim(names) == "",
      "initial checked Candidate already contains reviewer-notes.md"
    )
  end

  defp final_candidate_bytes!(fixture, candidate) do
    require!(
      git_show!(fixture, "#{candidate}:dummy.txt") == @required_dummy and
        git_show!(fixture, "#{candidate}:reviewer-notes.md") == @required_notes,
      "final checked Candidate must contain the exact final file bytes"
    )
  end

  defp checked_before!(initial, final) do
    initial_time = parse_time!(initial["finished_at"], "archived initial Check")
    final_time = parse_time!(final["finished_at"], "current final Check")

    require!(
      DateTime.compare(initial_time, final_time) != :gt,
      "final Check predates the archived initial Check"
    )
  end

  defp developer_resume!(dir, developer, rework_reviewer, accepting_reviewer) do
    streams =
      dir
      |> Path.join("raw-stream-*.jsonl")
      |> Path.wildcard()
      |> Enum.map(&stream!(&1))
      |> Enum.sort_by(& &1.sequence)

    require!(streams != [], "missing retained provider streams")

    developer_sequences = sequences_for_thread(streams, developer)
    rework_sequence = one_sequence_for_thread!(streams, rework_reviewer, "first Reviewer")

    accepting_sequence =
      one_sequence_for_thread!(streams, accepting_reviewer, "accepting Reviewer")

    require!(
      length(developer_sequences) == 2,
      "retained streams must show the exact Developer thread launched and resumed"
    )

    [initial_developer | later_developer] = developer_sequences
    resumed_developer = Enum.find(later_developer, &(&1 > rework_sequence))

    require!(
      is_integer(resumed_developer) and
        initial_developer < rework_sequence and rework_sequence < resumed_developer and
        resumed_developer < accepting_sequence,
      "retained stream capture order must be initial Developer, rework Reviewer, exact Developer resume, accepting Reviewer"
    )
  end

  defp stream!(path) do
    [_, sequence] = Regex.run(~r/raw-stream-\d+-(\d+)\.jsonl$/, path)
    events = json_events(path)
    require!(events != [], "provider stream has no structured events")
    %{sequence: String.to_integer(sequence), events: events}
  end

  defp sequences_for_thread(streams, thread_id) do
    for %{sequence: sequence, events: events} <- streams,
        Enum.any?(events, &(&1["type"] == "thread.started" and &1["thread_id"] == thread_id)),
        do: sequence
  end

  defp one_sequence_for_thread!(streams, thread_id, label) do
    case sequences_for_thread(streams, thread_id) do
      [sequence] -> sequence
      [] -> fail!("missing retained #{label} provider stream")
      _ -> fail!("#{label} provider stream must have one capture")
    end
  end

  defp commit_provenance!(fixture, slug, intent_id) do
    {message, 0} =
      System.cmd("sh", ["-c", "git log -1 --format=%B | git interpret-trailers --parse"],
        cd: fixture
      )

    trailers = String.split(message, "\n", trim: true)

    require!(
      "Kogen-Intent-ID: #{intent_id}" in trailers,
      "Commit is missing the exact Intent identity trailer"
    )

    require!(
      "Kogen-Intent: #{slug}" in trailers,
      "Commit is missing the exact Intent slug trailer"
    )

    require!(
      git_show!(fixture, "HEAD:dummy.txt") == @required_dummy and
        git_show!(fixture, "HEAD:reviewer-notes.md") == @required_notes,
      "published Commit must contain the exact Candidate file bytes"
    )

    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: fixture)
    require!(status == "", "fixture must be clean after publishing the audited Candidate")
  end

  defp git_show!(fixture, object_path) do
    case System.cmd("git", ["show", object_path], cd: fixture, stderr_to_stdout: true) do
      {content, 0} -> content
      _ -> fail!("published Candidate or Commit is missing #{object_path}")
    end
  end

  defp evidence_value!(evidence, label) do
    case Regex.run(~r/- #{Regex.escape(label)}: `([^`]+)`/, evidence) do
      [_, value] -> value
      _ -> fail!("Complete evidence is missing #{label}")
    end
  end

  defp lines!(path, label) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> event
        _ -> fail!("#{label} contains malformed JSON")
      end
    end)
  end

  # Codex can interleave diagnostic stderr with its JSON event stream. The raw
  # capture is still useful evidence, but only its structured event lines can
  # establish a thread identity; receipt and Check logs remain strict above.
  defp json_events(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> [event]
        _ -> []
      end
    end)
  end

  defp json_file!(path, label) do
    case path |> File.read!() |> Jason.decode() do
      {:ok, record} when is_map(record) -> record
      _ -> fail!("#{label} contains malformed JSON")
    end
  end

  defp parse_time!(value, label) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _ -> fail!("#{label} has no valid finished_at timestamp")
    end
  end

  defp parse_time!(_, label), do: fail!("#{label} has no valid finished_at timestamp")

  defp passing_for?(record, developer) do
    record["status"] == "passed" and record["target"] == "check" and record["exit_code"] == 0 and
      record["session_id"] == developer
  end

  defp require_exact!(path, expected, label) do
    require_file!(path, label)
    require!(File.read!(path) == expected, "#{label} must contain the exact final bytes")
  end

  defp require_file!(path, label), do: require!(File.regular?(path), "missing #{label}: #{path}")
  defp require!(true, _message), do: :ok
  defp require!(false, message), do: fail!(message)
  defp fail!(message), do: raise(ArgumentError, message)
end
