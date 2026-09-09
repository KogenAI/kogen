Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.LifecycleTest do
  @moduledoc """
  The fake full lifecycle test required by `make check`: public Shape creates
  a Draft, explicit fixture approval moves that exact package to Approved,
  and public Build drives it through a failing Stop Check, independent Review
  rework, exact Developer resume, fresh accept, and Commit. It runs only the
  fake `codex` executable in a disposable fixture.
  The fixture's `check` target is deliberately small: it detects the broken
  source that the fake Developer first creates, then passes after that same
  Developer corrects it. The tracked Stop hook still owns both invocations.
  """
  use ExUnit.Case, async: true

  @moduletag :lifecycle
  @moduletag timeout: 300_000

  @slug "fake-shaped-intent"

  test "public Shape, explicit fixture approval, and public Build form one offline lifecycle" do
    src = File.cwd!()
    dest = Kogen.CompiledFixture.create!(src, "lifecycle")

    on_exit(fn -> File.rm_rf(dest) end)

    init_fixture_git!(dest)
    original_parent = git!(dest, ["rev-parse", "HEAD"])
    {intent_id, original_intent, original_scenarios} = shape_and_explicitly_approve!(dest)

    assert_delegation_prompt!(
      File.read!(Path.join(dest, ".kogen/runtime/shaping-prompt")),
      :shaping
    )

    assert git!(dest, ["status", "--porcelain"]) == ""

    fake_harness = Path.join(dest, "test/support/fake_codex")
    shim_dir = Path.join(dest, "test/support")
    raw_log_dir = Path.join(dest, ".kogen/runtime/fake-lifecycle-receipts")

    env = [
      {"KOGEN_HARNESS", fake_harness},
      {"KOGEN_RAW_LOG_DIR", raw_log_dir},
      {"PATH", shim_dir <> ":" <> System.get_env("PATH", "")}
    ]

    {output, exit_code} = Kogen.CompiledFixture.mix_task!(dest, ["kogen.build", @slug], env)

    assert exit_code == 0, "mix kogen.build failed:\n#{output}"

    refute File.exists?(Path.join(dest, ".kogen/runtime/path-shim-invoked")),
           "a codex binary other than the fake harness was executed"

    complete_dir = Path.join(dest, ".kogen/intents/complete/#{@slug}")
    approved_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")

    assert File.dir?(complete_dir)
    refute File.dir?(approved_dir)
    assert File.read!(Path.join(complete_dir, "intent.yaml")) == original_intent
    assert File.read!(Path.join(complete_dir, "scenarios.yaml")) == original_scenarios
    assert git!(dest, ["show", "HEAD:dummy.txt"]) == "reviewed fixture value"

    assert git!(dest, ["show", "HEAD:reviewer-rework-marker.txt"]) ==
             "Reviewer-directed rework applied"

    evidence = File.read!(Path.join(complete_dir, "evidence.md"))
    assert evidence =~ "Outer resumptions used: 1"
    assert evidence =~ "Reviewer verdict: accept"

    subject = git!(dest, ["log", "-1", "--format=%s"])
    assert subject == "Fake shaped intent"

    assert raw_commit_message!(dest) ==
             "Fake shaped intent\n\nKogen-Intent-ID: #{intent_id}\nKogen-Intent: #{@slug}\n"

    assert git!(dest, ["rev-parse", "HEAD^"]) == original_parent

    {trailer_out, 0} =
      System.cmd("sh", ["-c", "git log -1 --format=%B | git interpret-trailers --parse"],
        cd: dest
      )

    assert trailer_out =~ "Kogen-Intent-ID: #{intent_id}"
    assert trailer_out =~ "Kogen-Intent: #{@slug}"

    log_lines =
      Path.join(dest, ".kogen/runtime/fake-harness-log")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(log_lines) == 4
    assert Enum.count(log_lines, &String.contains?(&1, "--output-schema")) == 2
    assert Enum.count(log_lines, &String.contains?(&1, "exec resume")) == 1

    assert Enum.any?(log_lines, fn line ->
             String.contains?(line, "exec resume ") and
               String.ends_with?(line, " dev-session-1 -")
           end)

    resume_feedback = File.read!(Path.join(dest, ".kogen/runtime/developer-resume-prompts"))
    assert resume_feedback =~ "Reviewer findings: fake finding: try again"

    refute resume_feedback =~ "settled Check failure:",
           "a failed Check settlement would consume a second outer resumption"

    assert Enum.all?(log_lines, fn line ->
             line =~ "--model gpt-6-astra" and line =~ "model_reasoning_effort=\"low\""
           end)

    assert_delegation_prompt!(
      File.read!(Path.join(dest, ".kogen/runtime/developer-launch-prompt")),
      :developer
    )

    assert_delegation_prompt!(
      File.read!(Path.join(dest, ".kogen/runtime/reviewer-prompt-1")),
      :reviewer
    )

    check_records =
      (verification_history_archives(raw_log_dir) ++
         [Path.join(dest, ".kogen/runtime/verification-history.jsonl")])
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        path
        |> File.stream!()
        |> Enum.map(&(String.trim(&1) |> Jason.decode!()))
      end)
      |> Enum.filter(&(&1["session_id"] == "dev-session-1"))

    failed_check_index = Enum.find_index(check_records, &(&1["status"] == "failed"))
    passed_check_index = Enum.find_index(check_records, &(&1["status"] == "passed"))

    assert is_integer(failed_check_index), "the initial Developer Stop must record a failed Check"
    assert is_integer(passed_check_index), "the same Developer must later record a passed Check"

    assert failed_check_index < passed_check_index,
           "the failed Stop Check must precede the passing Check in one Developer thread"

    failed_reason = check_records |> Enum.at(failed_check_index) |> Map.fetch!("reason")

    assert failed_reason =~ "lib/kogen_fake_break.ex",
           "the retained failed settlement reason must identify the bounded fixture check"
  end

  defp init_fixture_git!(dest) do
    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)
  end

  defp shape_and_explicitly_approve!(dest) do
    env = [{"KOGEN_HARNESS", Path.join(dest, "test/support/fake_codex_shaper")}]

    {output, 0} = Kogen.CompiledFixture.mix_task!(dest, "kogen.shape", env)

    [intent_id] =
      Regex.run(~r/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/, output)

    draft_dir = Path.join(dest, ".kogen/intents/drafts/#{@slug}")
    approved_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    assert File.dir?(draft_dir), "public Shape did not persist the fixture Draft"

    original_intent = File.read!(Path.join(draft_dir, "intent.yaml"))
    original_scenarios = File.read!(Path.join(draft_dir, "scenarios.yaml"))
    assert original_intent =~ intent_id
    shaped = YamlElixir.read_from_string!(original_intent)

    assert shaped["shaped_against"] == %{
             "branch" => git!(dest, ["branch", "--show-current"]),
             "head" => git!(dest, ["rev-parse", "HEAD"])
           }

    {:ok, config} = Kogen.Intent.read_config(Path.join(dest, ".kogen/config.yaml"))
    assert shaped["shaping"]["model"] == config.shaping.model
    assert shaped["shaping"]["effort"] == config.shaping.effort

    # This rename is the fixture's explicit same-conversation approval. The
    # fake Shaping Controller itself deliberately writes only a Draft.
    File.mkdir_p!(Path.dirname(approved_dir))
    File.rename!(draft_dir, approved_dir)

    refute File.dir?(draft_dir)
    assert File.dir?(approved_dir)

    {intent_id, original_intent, original_scenarios}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end

  defp assert_delegation_prompt!(prompt, role) do
    prompt = String.replace(prompt, ~r/\s+/, " ")

    assert prompt =~ "explicitly authorized to proactively use"
    assert prompt =~ "gpt-5.6-luna` at `low"
    assert prompt =~ "gpt-5.6-terra` at `medium"
    assert prompt =~ "gpt-6-astra` at `medium"
    assert prompt =~ "fresh or minimal context"
    assert prompt =~ "smallest sufficient task packet"
    assert prompt =~ "native harness's current capacity"
    assert prompt =~ "automatic scout-to-worker-to-expert escalation chain"
    assert prompt =~ "profile unavailable, surface that failure"
    refute prompt =~ "{{scout_model}}"
    refute prompt =~ "{{worker_model}}"
    refute prompt =~ "{{expert_model}}"

    case role do
      :shaping ->
        assert prompt =~ "continue accepting the Shaper's steering while helpers work"
        assert prompt =~ "Draft authorship, and approval handling"

      :developer ->
        assert prompt =~ "non-overlapping paths within `may_change_guarded_paths`"
        assert prompt =~ "No helper may edit either of those protected inputs"
        assert prompt =~ "Wait for every child before Candidate capture"
        assert prompt =~ "run or delegate a declared verification gate"
        assert prompt =~ "exact Developer session"

      :reviewer ->
        assert prompt =~ "Every child is read-only and receives no Developer conversation"
        assert prompt =~ "Wait for every child before deciding"
        assert prompt =~ "schema-valid final verdict yourself"
    end
  end

  defp raw_commit_message!(dir) do
    {commit, 0} = System.cmd("git", ["cat-file", "commit", "HEAD"], cd: dir)
    [_headers, message] = String.split(commit, "\n\n", parts: 2)
    message
  end

  defp verification_history_archives(raw_log_dir) do
    raw_log_dir
    |> Path.join("verification-history-*.jsonl")
    |> Path.wildcard()
  end
end
