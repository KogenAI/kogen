defmodule Kogen.LiveShapeToBuildTest do
  @moduledoc """
  The real, public, end-to-end lifecycle in bounded, disposable
  fixture: the real Shaping Controller (`mix kogen.shape`, driven through a genuine
  pty) drafts an Intent, receives explicit scripted test approval (test
  data only -- not approval of a real feature), and the real Builder
  (`mix kogen.build <slug>`) then builds *that exact* shaped-and-approved
  package -- not a separately hand-written Approved package claiming to
  be end-to-end.

  Every transition is enforced against real disk state, not swallowed:
  Draft files must exist before the scripted approval is sent; Approved
  files must exist and Draft must be gone afterward, carrying the same
  minted UUIDv7 identity that was printed at the start; the real Stop
  hook's Verification Record history must show an actual `failed` record
  followed by an actual `passed` record for the *same* Developer session,
  with zero outer resumptions (a higher `num_turns` alone is not treated
  as proof, since ordinary tool use also produces multiple turns); Review
  must accept; the resulting Commit must carry the Intent's trailers.

  Runs in an isolated, disposable fixture: a fresh clone with its own git
  history, cleaned up at the end -- placed under this checkout's own
  `.kogen/runtime/` so it inherits this directory's already-established
  Codex trust. The Shape driver still handles either trust state in
  code (`test/support/shape_to_build_probe.exp`), it just isn't required
  to prove the one-time trust dialog itself here. Raw provider streams
  and every intermediate receipt are written directly under this track's
  owned runtime directory as the run proceeds, not copied in afterward,
  so they survive independent of fixture cleanup. A second, clearly labeled
  Build-only fixture covers reviewer-directed rework: it uses an intentionally
  deferred companion file so a real first Reviewer must return actionable
  `rework`, after which the same real Developer thread resumes and a fresh
  real Reviewer accepts. It does not substitute for the connected Shape proof.
  """
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 900_000

  @slug "shape-to-build-probe"
  @review_rework_slug "live-reviewer-rework-probe"

  @makefile """
  .PHONY: check
  check:
  \t@test -f dummy.txt || (echo "dummy.txt is missing. Required exact content: shape2build-k4q9z" && exit 1)
  \t@grep -qx shape2build-k4q9z dummy.txt || (echo "dummy.txt content is wrong. Required exact content: shape2build-k4q9z" && exit 1)
  """

  @review_rework_makefile """
  .PHONY: check
  check:
  \t@test -f dummy.txt || (echo "dummy.txt is missing. Required exact content: reviewer-rework-k4q9z" && exit 1)
  \t@grep -qx reviewer-rework-k4q9z dummy.txt || (echo "dummy.txt content is wrong. Required exact content: reviewer-rework-k4q9z" && exit 1)
  """

  @review_rework_intent """
  id: 01960000-0000-7000-8000-00000000beef
  slug: #{@review_rework_slug}
  title: Live reviewer rework probe
  may_change_guarded_paths:
    - dummy.txt
    - reviewer-notes.md
  """

  @review_rework_scenarios """
  - id: reviewer-directed-rework
    given: an isolated provider-backed fixture with no dummy.txt or reviewer-notes.md
    when: the first Developer turn implements this test protocol
    then: it creates dummy.txt at the repository root containing exactly reviewer-rework-k4q9z, deliberately leaves reviewer-notes.md absent for the first independent Reviewer to identify, and creates reviewer-notes.md containing exactly reviewer-confirmed-k4q9z only after that Reviewer returns actionable rework in the exact same Developer conversation; a fresh second Reviewer must then accept the final Candidate
    wrong_result: the first Reviewer accepts without inspecting the intentionally deferred companion file, a replacement Developer session performs rework, or the final Candidate lacks the companion file
    verified_by: [check]
    evidence: provider-backed Build-only fixture preserves both structured reviewer receipts, Developer raw streams, Stop records, and the resulting Commit
  """

  test "real Shape drafts and is approved, then real Build corrects a real Stop-Check failure in one session and completes Review/Commit" do
    project_root = File.cwd!()
    log_dir = owned_log_dir(project_root)

    runtime_root = Path.join(project_root, ".kogen/runtime/live-shape2build")
    File.mkdir_p!(runtime_root)
    fixture = Path.join(runtime_root, "fixture-#{System.system_time(:nanosecond)}")
    File.mkdir_p!(fixture)

    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")
    setup_fixture(project_root, fixture)
    precompile!(fixture, log_dir)

    pty_log =
      Path.join(log_dir, "shape-pty-transcript-#{System.system_time(:second)}.log")

    {diagnostics, shape_exit} =
      System.cmd(
        "expect",
        [
          "-f",
          Path.join(project_root, "test/support/shape_to_build_probe.exp"),
          fixture,
          pty_log,
          @slug
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "shape-probe-diagnostics.txt"), diagnostics)

    assert shape_exit == 0, """
    real Shape probe did not complete (exit #{shape_exit}); this is a real failure, not swallowed.
    Diagnostics:
    #{diagnostics}
    Raw pty transcript: #{pty_log}
    """

    draft_dir = Path.join(fixture, ".kogen/intents/drafts/#{@slug}")
    approved_dir = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    approved_intent_path = Path.join(approved_dir, "intent.yaml")

    refute File.dir?(draft_dir), "the Draft directory must be gone after real approval"
    assert File.exists?(approved_intent_path), "the real Approved intent.yaml must exist"

    transcript = File.read!(pty_log)

    minted_uuid =
      Regex.run(
        ~r/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/,
        transcript
      )
      |> List.first()

    assert minted_uuid, "expected a freshly minted UUIDv7 printed in the transcript"

    approved_intent_content = File.read!(approved_intent_path)
    approved_scenarios_content = File.read!(Path.join(approved_dir, "scenarios.yaml"))

    assert approved_intent_content =~ minted_uuid,
           "the real minted identity (#{minted_uuid}) must be preserved into the Approved intent.yaml"

    # The Shaping Controller may describe the outcome, but the exact remediation value is
    # deliberately available only from the failing Stop-hook output.  If it
    # leaks into the shaped package, this would no longer demonstrate an
    # in-turn hook correction.
    refute approved_intent_content =~ "shape2build-k4q9z"
    refute approved_scenarios_content =~ "shape2build-k4q9z"

    # Real public Build, against the exact package the real Shaping Controller wrote
    # and the real scripted approval moved -- not a hand-written stand-in.
    raw_stream_dir = Path.join(log_dir, "build-raw-streams")

    {build_out, build_exit} =
      System.cmd("mix", ["kogen.build", @slug],
        cd: fixture,
        env: [{"KOGEN_RAW_LOG_DIR", raw_stream_dir}],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "build-console.log"), build_out)

    history_path = Path.join(fixture, ".kogen/runtime/verification-history.jsonl")

    if File.exists?(history_path) do
      File.cp!(history_path, Path.join(log_dir, "verification-history.jsonl"))
    end

    complete_dir = Path.join(fixture, ".kogen/intents/complete/#{@slug}")
    evidence_path = Path.join(complete_dir, "evidence.md")

    if File.exists?(evidence_path) do
      File.cp!(evidence_path, Path.join(log_dir, "evidence.md"))
    end

    {git_log, _} =
      System.cmd("git", ["log", "--format=%H%n%B", "-3"], cd: fixture, stderr_to_stdout: true)

    File.write!(Path.join(log_dir, "git-log.txt"), git_log)

    assert build_exit == 0, """
    real mix kogen.build did not succeed (exit #{build_exit}); this is a real failure, not swallowed.
    Console:
    #{build_out}
    Preserved evidence under: #{log_dir}
    """

    assert File.dir?(complete_dir)
    refute File.dir?(Path.join(fixture, ".kogen/intents/approved/#{@slug}"))

    evidence = File.read!(evidence_path)
    assert evidence =~ "Outer resumptions used: 0"

    developer_session_id =
      Regex.run(~r/Developer session id: `([^`]+)`/, evidence) |> List.last()

    assert developer_session_id, "expected a Developer session id in evidence.md"

    assert File.exists?(history_path),
           "the Verification Record history must exist -- the real Stop hook must have fired"

    records =
      history_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    same_session = Enum.filter(records, &(&1["session_id"] == developer_session_id))

    assert Enum.any?(same_session, &(&1["status"] == "failed")),
           "expected an actual failed Check record for session #{developer_session_id}; " <>
             "records: #{inspect(records)}"

    assert Enum.any?(same_session, &(&1["status"] == "passed")),
           "expected an actual passed Check record for session #{developer_session_id}; " <>
             "records: #{inspect(records)}"

    first_failed_index = Enum.find_index(same_session, &(&1["status"] == "failed"))
    first_passed_index = Enum.find_index(same_session, &(&1["status"] == "passed"))

    assert first_failed_index < first_passed_index,
           "the failed record must precede the passed record within the same session"

    subject = git!(fixture, ["log", "-1", "--format=%s"])
    assert subject == "Shape to build probe"

    {trailer_out, 0} =
      System.cmd("sh", ["-c", "git log -1 --format=%B | git interpret-trailers --parse"],
        cd: fixture
      )

    assert trailer_out =~ "Kogen-Intent-ID: #{minted_uuid}"
    assert trailer_out =~ "Kogen-Intent: #{@slug}"
    assert git_log =~ "Built by Kogen"
    refute git_log =~ "manual Developer invocation"

    File.rm_rf!(fixture)
  end

  test "real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture" do
    project_root = File.cwd!()
    log_dir = owned_log_dir(project_root)

    runtime_root = Path.join(project_root, ".kogen/runtime/live-reviewer-rework")
    File.mkdir_p!(runtime_root)
    fixture = Path.join(runtime_root, "fixture-#{System.system_time(:nanosecond)}")
    File.mkdir_p!(fixture)

    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")
    setup_fixture(project_root, fixture, @review_rework_makefile)
    precompile!(fixture, log_dir)
    write_review_rework_package(fixture)

    raw_stream_dir = Path.join(log_dir, "build-raw-streams")

    {build_out, build_exit} =
      System.cmd("mix", ["kogen.build", @review_rework_slug],
        cd: fixture,
        env: [{"KOGEN_RAW_LOG_DIR", raw_stream_dir}],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "build-console.log"), build_out)

    complete_dir = Path.join(fixture, ".kogen/intents/complete/#{@review_rework_slug}")
    evidence_path = Path.join(complete_dir, "evidence.md")
    history_path = Path.join(fixture, ".kogen/runtime/verification-history.jsonl")

    preserve_if_present(history_path, Path.join(log_dir, "verification-history.jsonl"))
    preserve_if_present(evidence_path, Path.join(log_dir, "evidence.md"))

    assert build_exit == 0, """
    real reviewer-rework Build failed (exit #{build_exit}); no provider result is inferred.
    Console:
    #{build_out}
    Preserved evidence under: #{log_dir}
    """

    assert File.dir?(complete_dir)
    assert File.read!(Path.join(fixture, "dummy.txt")) == "reviewer-rework-k4q9z\n"
    assert File.read!(Path.join(fixture, "reviewer-notes.md")) == "reviewer-confirmed-k4q9z\n"

    evidence = File.read!(evidence_path)
    assert evidence =~ "Outer resumptions used: 1"

    developer_session_id =
      Regex.run(~r/Developer session id: `([^`]+)`/, evidence) |> List.last()

    assert developer_session_id

    assert File.exists?(history_path), "the real Stop hook must record both Developer turns"

    same_session_records =
      verification_records(history_path, raw_stream_dir)
      |> Enum.filter(&(&1["session_id"] == developer_session_id))

    assert Enum.count(same_session_records, &(&1["status"] == "passed")) >= 2,
           "initial development and reviewer-directed rework must both settle through the same real Stop hook"

    assert File.exists?(Path.join(raw_stream_dir, "reviewer-verdicts.jsonl")),
           "the Harness must preserve actual structured reviewer receipts for live audit"

    reviewer_receipts =
      raw_stream_dir
      |> Path.join("reviewer-verdicts.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [
             %{"verdict" => "rework", "findings" => findings, "session_id" => first_reviewer},
             %{"verdict" => "accept", "session_id" => second_reviewer}
           ] = reviewer_receipts

    assert is_list(findings) and findings != []
    assert first_reviewer != second_reviewer

    raw_events = raw_stream_events(raw_stream_dir)

    assert Enum.count(
             raw_events,
             &(&1["type"] == "thread.started" and &1["thread_id"] == developer_session_id)
           ) >= 2,
           "the provider stream must show the exact original Developer thread started again for rework"

    {trailer_out, 0} =
      System.cmd("sh", ["-c", "git log -1 --format=%B | git interpret-trailers --parse"],
        cd: fixture
      )

    assert trailer_out =~ "Kogen-Intent-ID: 01960000-0000-7000-8000-00000000beef"
    assert trailer_out =~ "Kogen-Intent: #{@review_rework_slug}"

    File.rm_rf!(fixture)
  end

  defp owned_log_dir(project_root) do
    base =
      System.get_env("KOGEN_LIVE_LOG_DIR") ||
        Path.join(project_root, ".kogen/runtime/live-evidence")

    dir = Path.join(base, "shape-to-build-#{System.system_time(:nanosecond)}")
    File.mkdir_p!(dir)
    dir
  end

  defp setup_fixture(project_root, fixture, makefile \\ @makefile) do
    {_out, 0} =
      System.cmd(
        "rsync",
        [
          "-a",
          "--exclude=_build",
          "--exclude=deps",
          "--exclude=.git",
          "--exclude=.kogen/runtime",
          "--exclude=.kogen/build.lock",
          "--exclude=.kogen/intents",
          project_root <> "/",
          fixture <> "/"
        ]
      )

    File.rm(Path.join(fixture, "deps"))
    File.ln_s!(Path.join(project_root, "deps"), Path.join(fixture, "deps"))

    File.write!(Path.join(fixture, "Makefile"), makefile)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: fixture, env: env)
  end

  defp precompile!(fixture, log_dir) do
    {out, exit_code} =
      System.cmd("mix", ["compile", "--warnings-as-errors"], cd: fixture, stderr_to_stdout: true)

    File.write!(Path.join(log_dir, "fixture-precompile.log"), out)

    assert exit_code == 0, "fixture pre-compile failed (exit #{exit_code}):\n#{out}"
  end

  defp write_review_rework_package(fixture) do
    dir = Path.join(fixture, ".kogen/intents/approved/#{@review_rework_slug}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "intent.yaml"), @review_rework_intent)
    File.write!(Path.join(dir, "scenarios.yaml"), @review_rework_scenarios)
  end

  defp preserve_if_present(source, destination) do
    if File.exists?(source), do: File.cp!(source, destination)
  end

  defp verification_records(current_history_path, raw_stream_dir) do
    archived_paths =
      raw_stream_dir
      |> Path.join("verification-history-*.jsonl")
      |> Path.wildcard()

    [current_history_path | archived_paths]
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(&json_lines/1)
  end

  defp raw_stream_events(raw_stream_dir) do
    raw_stream_dir
    |> Path.join("raw-stream-*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(&events_from_stream/1)
  end

  defp events_from_stream(path) do
    json_lines(path)
  end

  defp json_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&decode_event/1)
  end

  defp decode_event(line) do
    case Jason.decode(line) do
      {:ok, event} -> [event]
      _ -> []
    end
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
