defmodule Kogen.CoreIntegrityTest do
  use ExUnit.Case, async: false

  alias Kogen.{Build, Check}

  @slug "core-integrity-intent"

  @intent_yaml """
  id: 01960000-0000-7000-8000-00000000c0de
  slug: #{@slug}
  title: Core integrity intent
  may_change_guarded_paths:
    - dummy.txt
  """

  @scenarios_yaml """
  - id: core-integrity
    given: a fixture Candidate
    when: the fake Developer stops
    then: a distinct Reviewer may accept it
    wrong_result: publication follows reused review context or a reserved Complete path
    verified_by: [check]
    evidence: fixture only
  """

  @config_yaml """
  harness: codex
  shaping:   {model: fake, effort: low}
  developer: {model: fake, effort: low}
  reviewer:  {model: fake, effort: low}
  outer_resumptions: 2
  """

  @makefile ".PHONY: check\ncheck:\n\t@true\n"

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  test "outer invalidation archives hook history only to the requested private log directory" do
    in_tmp_cwd(fn ->
      raw_dir = Path.join(File.cwd!(), "private-raw")
      prior_raw_dir = System.get_env("KOGEN_RAW_LOG_DIR")
      System.put_env("KOGEN_RAW_LOG_DIR", raw_dir)

      on_exit(fn -> restore_env("KOGEN_RAW_LOG_DIR", prior_raw_dir) end)

      File.mkdir_p!(Path.dirname(Check.history_path()))
      history = "{\"status\":\"passed\"}\n"
      File.write!(Check.history_path(), history)
      File.write!(Check.record_path(), "{}")

      assert :ok = Check.invalidate!()
      refute File.exists?(Check.history_path())
      refute File.exists?(Check.record_path())

      assert [archive] = Path.wildcard(Path.join(raw_dir, "verification-history-*.jsonl"))
      assert File.read!(archive) == history
    end)
  end

  test "Build stops when a Reviewer reuses the Developer session" do
    fixture = setup_fixture!(:same_reviewer_session)

    assert {:error, "Reviewer session must differ from the Developer session"} =
             run_build_with_fixture_harness(fixture)

    refute match?({:ok, _}, File.lstat(Path.join(fixture, ".kogen/intents/complete/#{@slug}")))
    assert File.dir?(Path.join(fixture, ".kogen/intents/approved/#{@slug}"))
  end

  test "Build stops before launching a provider when it cannot remove a stale Verification Record" do
    fixture = setup_fixture!(:same_reviewer_session)
    record_path = Path.join(fixture, Check.record_path())
    File.mkdir_p!(record_path)

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "could not clear stale Verification Record"
    refute File.exists?(Path.join(fixture, ".kogen/runtime/fake-harness-log"))
    refute File.exists?(Path.join(fixture, ".kogen/build.lock"))
  end

  test "Build refuses a symlinked Approved package entry before launching a provider" do
    fixture = setup_fixture!(:same_reviewer_session)
    approved = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    scenarios = Path.join(approved, "scenarios.yaml")
    source = Path.join(fixture, "linked-scenarios.yaml")

    File.write!(source, @scenarios_yaml)
    File.rm!(scenarios)
    File.ln_s!(source, scenarios)

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "symlink (unsupported)"
    refute File.exists?(Path.join(fixture, ".kogen/runtime/fake-harness-log"))
  end

  test "Build rechecks a dangling Complete path created by the Candidate before publication" do
    fixture = setup_fixture!(:late_dangling_complete)

    assert {:error, "Complete Intent already exists: #{@slug}"} =
             run_build_with_fixture_harness(fixture)

    assert {:ok, stat} = File.lstat(Path.join(fixture, ".kogen/intents/complete/#{@slug}"))
    assert stat.type == :symlink
    assert File.dir?(Path.join(fixture, ".kogen/intents/approved/#{@slug}"))
  end

  test "Build aborts without publication when the Reviewer verdict is malformed" do
    fixture = setup_fixture!(:malformed_reviewer)
    head_before = git!(fixture, ["rev-parse", "HEAD"])

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Reviewer failure"
    assert_unpublished!(fixture, head_before)
  end

  test "Build aborts without publication when the Reviewer process exits nonzero" do
    fixture = setup_fixture!(:reviewer_exits_nonzero)
    head_before = git!(fixture, ["rev-parse", "HEAD"])

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Reviewer failure"
    assert_unpublished!(fixture, head_before)
  end

  test "Build aborts without publication when Reviewer rework findings are empty" do
    fixture = setup_fixture!(:empty_rework_findings)
    head_before = git!(fixture, ["rev-parse", "HEAD"])

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Reviewer failure"
    assert_unpublished!(fixture, head_before)
  end

  defp setup_fixture!(mode) do
    project_root = File.cwd!()

    dir =
      Path.join(System.tmp_dir!(), "kogen-core-integrity-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    hook_dir = Path.join(dir, ".codex/hooks")
    File.mkdir_p!(hook_dir)
    hook = Path.join(hook_dir, "check.sh")
    File.cp!(Path.join(project_root, ".codex/hooks/check.sh"), hook)
    File.chmod!(hook, 0o755)
    File.cp!(Path.join(project_root, ".codex/hooks.json"), Path.join(dir, ".codex/hooks.json"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/verification_policy.py"),
      Path.join(hook_dir, "verification_policy.py")
    )

    prompt_dir = Path.join(dir, "priv/kogen/prompts")
    File.mkdir_p!(prompt_dir)

    for name <- ["developer.md", "reviewer.md"] do
      File.cp!(Path.join(project_root, "priv/kogen/prompts/#{name}"), Path.join(prompt_dir, name))
    end

    File.write!(Path.join(dir, "Makefile"), @makefile)

    File.write!(
      Path.join(dir, ".gitignore"),
      ".kogen/build.lock\n.kogen/runtime/\n.kogen/intents/approved/\n"
    )

    File.write!(
      Path.join(dir, ".kogen/config.yaml") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      @config_yaml
    )

    approved = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(approved)
    File.write!(Path.join(approved, "intent.yaml"), @intent_yaml)
    File.write!(Path.join(approved, "scenarios.yaml"), @scenarios_yaml)

    harness = Path.join(dir, "fake-codex")
    File.write!(harness, fake_harness(mode))
    File.chmod!(harness, 0o755)

    assert {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)
    assert {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    assert {_out, 0} =
             System.cmd("git", ["commit", "-q", "-m", "baseline"], cd: dir, env: @git_env)

    dir
  end

  defp run_build_with_fixture_harness(fixture) do
    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", Path.join(fixture, "fake-codex"))
    on_exit(fn -> restore_env("KOGEN_HARNESS", prior_harness) end)
    File.cd!(fixture, fn -> Build.run(@slug) end)
  end

  defp fake_harness(:same_reviewer_session), do: fake_harness_body("", "dev-session-1")

  defp fake_harness(:malformed_reviewer) do
    fake_harness_body(
      "",
      "reviewer-session-1",
      "printf '%s\\n' 'not a JSON verdict' > \"$output_file\""
    )
  end

  defp fake_harness(:reviewer_exits_nonzero) do
    fake_harness_body("", "reviewer-session-1", "exit 23")
  end

  defp fake_harness(:empty_rework_findings) do
    fake_harness_body(
      "",
      "reviewer-session-1",
      "printf '%s\\n' '{\"verdict\":\"rework\",\"findings\":[]}' > \"$output_file\""
    )
  end

  defp fake_harness(:late_dangling_complete) do
    fake_harness_body(
      "mkdir -p .kogen/intents/complete\nln -s missing .kogen/intents/complete/#{@slug}\n",
      "reviewer-session-1"
    )
  end

  defp fake_harness_body(
         developer_setup,
         reviewer_session,
         reviewer_response \\ "printf '%s\\n' '{\"verdict\":\"accept\",\"findings\":[]}' > \"$output_file\""
       ) do
    """
    #!/bin/sh
    set -eu
    cat >/dev/null || true
    reviewer=0
    output_file=
    previous=
    for arg in "$@"; do
      [ "$arg" = --output-schema ] && reviewer=1
      [ "$previous" = --output-last-message ] && output_file="$arg"
      previous="$arg"
    done
    if [ "$reviewer" -eq 1 ]; then
      #{reviewer_response}
      printf '%s\\n' '{"type":"thread.started","thread_id":"#{reviewer_session}"}' '{"type":"turn.completed","thread_id":"#{reviewer_session}"}'
      exit 0
    fi
    #{developer_setup}printf '%s\\n' '{"type":"thread.started","thread_id":"dev-session-1"}'
    printf '%s' '{"session_id":"dev-session-1"}' | sh .codex/hooks/check.sh >/dev/null
    printf '%s\\n' '{"type":"turn.completed","thread_id":"dev-session-1"}'
    """
  end

  defp in_tmp_cwd(fun) do
    dir =
      Path.join(System.tmp_dir!(), "kogen-check-archive-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    File.cd!(dir, fun)
  end

  defp restore_env(key, value) do
    if value, do: System.put_env(key, value), else: System.delete_env(key)
  end

  defp assert_unpublished!(fixture, head_before) do
    assert git!(fixture, ["rev-parse", "HEAD"]) == head_before
    assert File.dir?(Path.join(fixture, ".kogen/intents/approved/#{@slug}"))
    refute match?({:ok, _}, File.lstat(Path.join(fixture, ".kogen/intents/complete/#{@slug}")))
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
