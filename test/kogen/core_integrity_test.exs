defmodule Kogen.CoreIntegrityTest do
  use Kogen.IsolatedCase,
    async: true,
    parameterize: [
      %{scenario: :archives_hook_history},
      %{scenario: :same_reviewer_session},
      %{scenario: :stale_verification_record},
      %{scenario: :symlinked_approved_entry},
      %{scenario: :late_dangling_complete},
      %{scenario: :malformed_reviewer_verdict},
      %{scenario: :reviewer_exits_nonzero},
      %{scenario: :empty_rework_findings},
      %{scenario: :harness_documentation},
      %{scenario: :handoff_report_documentation}
    ]

  alias Kogen.{Build, Check}
  alias Kogen.Build.Workspace

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
  default_route: codex
  routes:
    codex:
      harness: codex
      shaping:   {model: fake, effort: low}
      developer: {model: fake, effort: low}
      reviewer:  {model: fake, effort: low}
      helpers:
        scout:  {model: fake, effort: low}
        worker: {model: fake, effort: medium}
        expert: {model: fake, effort: medium}
  outer_resumptions: 2
  verification_retries: 2
  """

  @makefile ".PHONY: check\ncheck:\n\t@true\n"

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  test "preserves core integrity for each scenario", %{scenario: scenario} do
    run_scenario(scenario)
  end

  # The user guide documents both adapters, the separate Kogen Claude Code
  # login, the proven models, and that only a selected route's paid targets
  # run; it must not claim Claude Code replaced Codex.
  defp run_scenario(:harness_documentation) do
    root = Path.expand("../..", __DIR__)
    guide = root |> Path.join("README.md") |> File.read!() |> String.replace(~r/\s+/, " ")

    for claim <- [
          "## Choosing a route",
          "`harness: claude`",
          "`harness: codex`",
          "mix kogen.claude.install",
          "mix kogen.claude.login --project",
          "mix kogen.claude.status",
          "Anthropic Console (API",
          "separate from personal Claude Code",
          "`claude-opus-5-5` and `claude-sonnet-5`",
          "Switching provider means",
          "that route's harness install",
          "## Managed Codex runtime and login",
          "Codex remains a supported"
        ] do
      assert guide =~ claim, "README must document: #{claim}"
    end

    refute guide =~ ~r/Claude Code (replaced|replaces) Codex/i
    refute guide =~ ~r/Claude subscription (through|via) Codex/i
    assert File.regular?(Path.join(root, "workflows/claude-code-runtime-upgrade.md"))
  end

  # The user guide must reflect the controller-built handoff report: the
  # Developer's final message is free prose Kogen never parses, Jev reads it
  # once per handoff, an objection at 0.85 stops the Build back to Shaping,
  # a missing proof selector is unfinished work worth one outer resumption,
  # and the dev.kogen.jev Keychain requirement is documented. It must no
  # longer describe invalid or malformed Developer handoffs, controller
  # handoff schemas, or schema-validated Developer turns.
  defp run_scenario(:handoff_report_documentation) do
    root = Path.expand("../..", __DIR__)
    guide = root |> Path.join("README.md") |> File.read!() |> String.replace(~r/\s+/, " ")

    for claim <- [
          "controller code builds the handoff report",
          "Kogen code never parses it",
          "jev-1.13.0",
          "0.85 confidence or higher stops the Build",
          "quoting the Developer's words and Jev's confidence",
          "reaches the Reviewer only as a labelled advisory note",
          "the Reviewer alone decides acceptance or rework",
          "unfinished work decided by code",
          "one outer resumption",
          "dev.kogen.jev",
          "security add-generic-password -s dev.kogen.jev -a <account> -w",
          "Build stops before launching the Developer",
          "Build sends the Developer's notes and the contract's scenario, risk, and finding IDs to TypeSafe"
        ] do
      assert guide =~ claim, "README must document: #{claim}"
    end

    refute guide =~ ~r/invalid Developer handoff/i
    refute guide =~ ~r/Developer handoff structure invalid/i
    refute guide =~ ~r/semantic invalid/i

    refute guide =~
             ~r/Developer('s)? (final )?message (is|carries)( its| a)? (validated|schema[- ]validated)/i

    refute guide =~ ~r/final Developer message against a\s*controller-owned schema/i
    refute guide =~ ~r/controller[- ]owned (handoff )?schema/i
    refute guide =~ ~r/malformed handoff/i
    refute guide =~ ~r/Invalid handoffs share/i
  end

  defp run_scenario(:archives_hook_history) do
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

  defp run_scenario(:same_reviewer_session) do
    fixture = setup_fixture!(:same_reviewer_session)

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Reviewer session must differ from the Developer session"
    assert reason =~ "tracking record:"

    refute match?({:ok, _}, File.lstat(Path.join(fixture, ".kogen/intents/complete/#{@slug}")))
    assert File.dir?(Path.join(fixture, ".kogen/intents/approved/#{@slug}"))
    assert_retained!(fixture, reason, "review-failure")
  end

  defp run_scenario(:stale_verification_record) do
    fixture = setup_fixture!(:same_reviewer_session)
    record_path = Path.join(fixture, Check.record_path())
    File.mkdir_p!(record_path)

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "could not clear stale Verification Record"
    refute File.exists?(Path.join(fixture, ".kogen/runtime/fake-harness-log"))
    refute File.exists?(Path.join(fixture, ".kogen/build.lock"))
    assert_retained!(fixture, reason, "integrity")
  end

  defp run_scenario(:symlinked_approved_entry) do
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

  defp run_scenario(:late_dangling_complete) do
    fixture = setup_fixture!(:late_dangling_complete)

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Candidate changed paths outside Approved guards"
    assert reason =~ "tracking record:"

    # The dangling `complete/<slug>` symlink was fabricated by the fake
    # Developer inside its own Candidate cwd; control's reserved Complete
    # path was never created, and its Approved package stays untouched.
    refute match?({:ok, _}, File.lstat(Path.join(fixture, ".kogen/intents/complete/#{@slug}")))
    assert File.dir?(Path.join(fixture, ".kogen/intents/approved/#{@slug}"))

    assert_retained!(fixture, reason, "integrity")

    candidate = Kogen.CandidateFixture.candidate(fixture)
    worktree = candidate["worktree_path"]
    assert {:ok, stat} = File.lstat(Path.join(worktree, ".kogen/intents/complete/#{@slug}"))
    assert stat.type == :symlink
  end

  defp run_scenario(:malformed_reviewer_verdict) do
    fixture = setup_fixture!(:malformed_reviewer)
    head_before = git!(fixture, ["rev-parse", "HEAD"])

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Reviewer failure"
    assert_unpublished!(fixture, head_before)
    assert_retained!(fixture, reason, "review-failure")
  end

  defp run_scenario(:reviewer_exits_nonzero) do
    fixture = setup_fixture!(:reviewer_exits_nonzero)
    head_before = git!(fixture, ["rev-parse", "HEAD"])

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Reviewer failure"
    assert_unpublished!(fixture, head_before)
    assert_retained!(fixture, reason, "review-failure")
  end

  defp run_scenario(:empty_rework_findings) do
    fixture = setup_fixture!(:empty_rework_findings)
    head_before = git!(fixture, ["rev-parse", "HEAD"])

    assert {:error, reason} = run_build_with_fixture_harness(fixture)
    assert reason =~ "Reviewer failure"
    assert_unpublished!(fixture, head_before)
    assert_retained!(fixture, reason, "review-failure")
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

    File.cp!(
      Path.join(project_root, ".codex/hooks/stop_runner.py"),
      Path.join(hook_dir, "stop_runner.py")
    )

    File.cp!(
      Path.join(project_root, ".codex/hooks/environment.py"),
      Path.join(hook_dir, "environment.py")
    )

    File.chmod!(hook, 0o755)
    File.cp!(Path.join(project_root, ".codex/hooks.json"), Path.join(dir, ".codex/hooks.json"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/verification_policy.py"),
      Path.join(hook_dir, "verification_policy.py")
    )

    prompt_dir = Path.join(dir, "priv/kogen/prompts")
    File.mkdir_p!(prompt_dir)

    for name <- ["developer.md", "reviewer.md", "execution-policy.md"] do
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
    Kogen.VerificationFixture.install!(dir)

    harness = Path.join(dir, "fake-codex")

    File.cp!(
      Path.join(project_root, "test/support/scenario_response.py"),
      Path.join(dir, "scenario_response.py")
    )

    File.write!(harness, fake_harness(mode))
    File.chmod!(harness, 0o755)

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dir, "deps"))

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
    File.cd!(fixture, fn -> Build.run(@slug, nil, fixture) end)
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
      "printf '%s' \"$input\" | python3 \"$response_helper\" reviewer rework | python3 -c 'import json,sys; value=json.load(sys.stdin); value[\"findings\"]=[]; print(json.dumps(value))' > \"$output_file\""
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
         reviewer_response \\ "printf '%s' \"$input\" | python3 \"$response_helper\" reviewer accept > \"$output_file\""
       ) do
    """
    #!/bin/sh
    set -eu
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    response_helper="$script_dir/scenario_response.py"
    input="$(cat)"
    reviewer=0
    [ "${KOGEN_ROLE:-}" = reviewer ] && reviewer=1
    output_file=
    previous=
    for arg in "$@"; do
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
    response="$(printf '%s' "$input" | python3 "$response_helper" developer)"
    if [ -n "$output_file" ]; then
      printf '%s\n' "$response" > "$output_file"
    fi
    printf '{"type":"item.completed","item":{"type":"agent_message","text":%s}}\\n' "$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
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

  # A stop keeps the Candidate worktree, branch and harness home exactly as
  # they are: control (its checkout and Approved package) is unchanged, the
  # tracking record's `candidate` block is `retained`, the stop message names
  # the slug, build id, worktree, branch and harness home next to the
  # tracking record path plus the removal command, and the Candidate's own
  # owner record independently agrees on `stopped: <category>`.
  defp assert_retained!(fixture, reason, expected_category) do
    candidate = Kogen.CandidateFixture.candidate(fixture)
    assert candidate["disposition"] == "retained"

    worktree = candidate["worktree_path"]
    assert File.dir?(worktree)
    assert File.dir?(candidate["harness_home"])
    assert worktree in Kogen.CandidateFixture.registered_worktrees(fixture)

    owner_record = candidate["owner_record"] |> File.read!() |> Jason.decode!()
    build_id = owner_record["build_id"]
    assert owner_record["status"] == "stopped: #{expected_category}"
    assert owner_record["control_root"] == Workspace.canonical(fixture)

    assert reason =~
             "Candidate kept: slug #{@slug}, build id #{build_id}, worktree #{worktree}, " <>
               "branch #{candidate["branch"]}, harness home #{candidate["harness_home"]}; " <>
               "remove it with `mix kogen.candidates.remove #{build_id}`"
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
