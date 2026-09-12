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

    install_distinct_profiles!(dest)
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

    [_, reviewer_json_and_policy] = String.split(resume_feedback, "Reviewer findings: ", parts: 2)
    [reviewer_json | _] = String.split(reviewer_json_and_policy, "\n\n", parts: 2)
    reviewer_feedback = Jason.decode!(reviewer_json)

    assert reviewer_feedback["verdict"] == "rework"

    assert [%{"id" => "shaped-scenario", "status" => "needs_rework"}] =
             reviewer_feedback["scenarios"]

    assert [%{"scenario_ids" => ["shaped-scenario"]}] = reviewer_feedback["findings"]

    refute resume_feedback =~ "settled Check failure:",
           "a failed Check settlement would consume a second outer resumption"

    assert Enum.at(log_lines, 0) =~ "--model fixture-developer"
    assert Enum.at(log_lines, 0) =~ "model_reasoning_effort=\"developer-effort\""
    assert Enum.at(log_lines, 1) =~ "--model fixture-reviewer"
    assert Enum.at(log_lines, 1) =~ "model_reasoning_effort=\"reviewer-effort\""
    assert Enum.at(log_lines, 2) =~ "--model fixture-developer"
    assert Enum.at(log_lines, 2) =~ "model_reasoning_effort=\"developer-effort\""
    assert Enum.at(log_lines, 3) =~ "--model fixture-reviewer"
    assert Enum.at(log_lines, 3) =~ "model_reasoning_effort=\"reviewer-effort\""

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

  defp install_distinct_profiles!(dest) do
    File.write!(Path.join(dest, ".kogen/config.yaml"), """
    harness: codex
    shaping: {model: fixture-shaper, effort: shaping-effort}
    developer: {model: fixture-developer, effort: developer-effort}
    reviewer: {model: fixture-reviewer, effort: reviewer-effort}
    helpers:
      scout: {model: fixture-scout, effort: scout-effort}
      worker: {model: fixture-worker, effort: worker-effort}
      expert: {model: fixture-expert, effort: expert-effort}
    outer_resumptions: 2
    """)
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

    shaping_args = File.read!(Path.join(dest, ".kogen/runtime/shaping-args"))
    assert shaping_args =~ "--model\nfixture-shaper\n"
    assert shaping_args =~ ~s(model_reasoning_effort="shaping-effort")

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
    refute prompt =~ "{{"
    prompt = String.replace(prompt, ~r/\s+/, " ")

    assert length(String.split(prompt, "## Shared execution and delegation policy")) == 2

    assert prompt =~
             "Configured root (#{role}): `fixture-#{root_name(role)}` at `#{root_effort(role)}`."

    assert prompt =~ "**scout:** `fixture-scout` at `scout-effort`; native kind `explorer`."
    assert prompt =~ "**worker:** `fixture-worker` at `worker-effort`; native kind `worker`."
    assert prompt =~ "**expert:** `fixture-expert` at `expert-effort`; native kind `default`."
    assert prompt =~ "small sufficient packet"
    assert prompt =~ "fresh or minimal context"
    assert prompt =~ "automatic escalation chain"
    assert prompt =~ "Report native unavailability and execution failures"

    case role do
      :shaping ->
        assert prompt =~ "The human retains product and scope decisions"
        assert prompt =~ "You retain Draft authorship and approval handling"
        assert prompt =~ "continue accepting steering while helpers work"

      :developer ->
        assert prompt =~ "non-overlapping paths within `may_change_guarded_paths`"
        assert prompt =~ "No helper may edit either of those protected inputs"
        assert prompt =~ "Wait for every child before Candidate capture"
        assert prompt =~ "run or delegate a declared verification gate"
        assert prompt =~ "exact Developer session"

      :reviewer ->
        assert prompt =~ "Reviewer and every child are read-only, preserve the Candidate"
        assert prompt =~ "receive no Developer conversation as evidence"
        assert prompt =~ "Wait for every child before deciding"
        assert prompt =~ "schema-valid final verdict yourself"
    end
  end

  defp root_name(:shaping), do: "shaper"
  defp root_name(:developer), do: "developer"
  defp root_name(:reviewer), do: "reviewer"

  defp root_effort(:shaping), do: "shaping-effort"
  defp root_effort(:developer), do: "developer-effort"
  defp root_effort(:reviewer), do: "reviewer-effort"

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
