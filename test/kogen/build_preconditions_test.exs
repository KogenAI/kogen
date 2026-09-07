defmodule Kogen.BuildPreconditionsTest do
  @moduledoc """
  Scenario `build-refuses-unready-state`: execution precondition
  failures returns `{:error, one_line_reason}` naming the specific failed
  precondition and never invokes the harness. Runs in-process (via
  `File.cd!/2`) against real temporary git repos, since `Kogen.Build`,
  `Kogen.Git`, and `Kogen.Check` all resolve relative paths against the
  process's current working directory. Marked `async: false` because
  `File.cd!/2` and `KOGEN_HARNESS` are process/VM-global state.
  """
  use ExUnit.Case, async: false

  @slug "precondition-fixture-intent"

  @valid_intent """
  id: 01960000-0000-7000-8000-0000000000aa
  slug: #{@slug}
  title: Precondition fixture intent
  may_change_guarded_paths:
    - lib/**
  """

  @intent_missing_title """
  id: 01960000-0000-7000-8000-0000000000aa
  slug: #{@slug}
  may_change_guarded_paths:
    - lib/**
  """

  @scenarios_yaml """
  - id: fixture-scenario
    given: a fixture Candidate
    when: the fixture Developer stops
    then: nothing, this fixture never launches a Developer
    wrong_result: the harness gets invoked
    verified_by: [check]
    evidence: fixture only
  """

  @config_yaml """
  harness: codex
  shaping:   {model: gpt-5.6-sol, effort: high}
  developer: {model: gpt-5.6-terra, effort: high}
  reviewer:  {model: gpt-5.6-sol, effort: high}
  outer_resumptions: 2
  """

  @makefile """
  .PHONY: check

  check:
  \t@true
  """

  @gitignore """
  .kogen/build.lock
  .kogen/runtime/
  """

  @git_env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  describe "precondition failures never launch the harness" do
    test "intent.yaml missing title" do
      run_precondition_case(fn dir -> write_intent(dir, @intent_missing_title) end, fn reason ->
        assert reason =~ "missing required key: title"
      end)
    end

    test "dirty worktree" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)
          File.write!(Path.join(dir, "dirty.txt"), "uncommitted\n")
        end,
        fn reason ->
          assert reason =~ "worktree is not clean"
        end
      )
    end

    test "detached HEAD" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)
          {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
          {_out, 0} = System.cmd("git", ["checkout", "-q", String.trim(sha)], cd: dir)
        end,
        fn reason ->
          assert reason =~ "detached HEAD"
        end
      )
    end

    test "existing Complete package" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)
          complete = Path.join(dir, ".kogen/intents/complete/#{@slug}")
          File.mkdir_p!(complete)
          File.write!(Path.join(complete, "intent.yaml"), @valid_intent)
          commit_fixture!(dir)
        end,
        fn reason -> assert reason =~ "Complete Intent already exists" end
      )
    end

    test "missing configuration releases the acquired lock" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)
          File.rm!(Path.join(dir, ".kogen/config.yaml"))
          commit_fixture!(dir)
        end,
        fn reason -> assert reason =~ "missing .kogen/config.yaml" end
      )
    end

    test "missing check target releases the acquired lock" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)
          File.write!(Path.join(dir, "Makefile"), "other:\n\t@true\n")
          commit_fixture!(dir)
        end,
        fn reason -> assert reason =~ "Makefile has no check target" end
      )
    end

    for {target, expected} <- [
          {"not-declared", "undeclared make target"},
          {"--eval=bad", "refused unsafe target name"}
        ] do
      test "rejects verification target #{target} before provider launch" do
        run_precondition_case(
          fn dir ->
            write_intent(dir, @valid_intent)
            scenarios = String.replace(@scenarios_yaml, "[check]", inspect([unquote(target)]))

            File.write!(
              Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"),
              scenarios
            )

            commit_fixture!(dir)
          end,
          fn reason -> assert reason =~ unquote(expected) end
        )
      end
    end

    for scenarios <- ["- scalar\n", "- verified_by: check\n", "[]\n", "- verified_by: []\n"] do
      test "invalid scenario execution structure #{inspect(scenarios)} releases lock" do
        run_precondition_case(
          fn dir ->
            write_intent(dir, @valid_intent)

            File.write!(
              Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"),
              unquote(scenarios)
            )

            commit_fixture!(dir)
          end,
          fn reason -> assert reason =~ "scenarios.yaml missing or invalid" end
        )
      end
    end

    for {old, replacement, reason} <- [
          {"title: Precondition fixture intent", "title: []", "title"},
          {"  - lib/**", "  - 123", "may_change_guarded_paths"},
          {"slug: #{@slug}", "slug: other-intent", "slug does not match"}
        ] do
      test "invalid required Intent input #{reason} stops before provider launch" do
        run_precondition_case(
          fn dir ->
            write_intent(dir, String.replace(@valid_intent, unquote(old), unquote(replacement)))
          end,
          fn result -> assert result =~ unquote(reason) end
        )
      end
    end

    test "unsupported configured harness stops before provider launch" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)

          File.write!(
            Path.join(dir, ".kogen/config.yaml"),
            String.replace(@config_yaml, "harness: codex", "harness: unsupported")
          )

          commit_fixture!(dir)
        end,
        fn reason -> assert reason =~ "unsupported harness" end
      )
    end

    test "negative resumption budget stops before provider launch" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)

          File.write!(
            Path.join(dir, ".kogen/config.yaml"),
            String.replace(@config_yaml, "outer_resumptions: 2", "outer_resumptions: -1")
          )

          commit_fixture!(dir)
        end,
        fn reason -> assert reason =~ "outer_resumptions" end
      )
    end

    test "existing build.lock" do
      run_precondition_case(
        fn dir ->
          write_intent(dir, @valid_intent)
          lock_dir = Path.join(dir, ".kogen")
          File.mkdir_p!(lock_dir)
          File.write!(Path.join(lock_dir, "build.lock"), "")
        end,
        fn reason ->
          assert reason =~ "build lock already present"
        end
      )
    end
  end

  # -- fixture plumbing --------------------------------------------------

  defp run_precondition_case(setup_fun, assert_reason) do
    dir = tmp_repo!()
    setup_fun.(dir)

    # The fake harness and its marker live entirely outside the git repo
    # under test, so writing/invoking it can never itself dirty the
    # worktree and confound the precondition under test.
    harness_dir =
      Path.join(System.tmp_dir!(), "kogen-precond-harness-#{System.unique_integer([:positive])}")

    File.mkdir_p!(harness_dir)
    on_exit(fn -> File.rm_rf(harness_dir) end)

    marker = Path.join(harness_dir, "harness-invoked")
    fake_harness = write_fake_harness!(harness_dir, marker)

    previous_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    on_exit(fn ->
      if previous_harness do
        System.put_env("KOGEN_HARNESS", previous_harness)
      else
        System.delete_env("KOGEN_HARNESS")
      end
    end)

    lock_was_present = File.exists?(Path.join(dir, ".kogen/build.lock"))

    result =
      File.cd!(dir, fn ->
        Kogen.Build.run(@slug)
      end)

    assert {:error, reason} = result
    assert_reason.(reason)
    assert File.exists?(Path.join(dir, ".kogen/build.lock")) == lock_was_present
    refute File.exists?(marker), "the fake harness marker exists: the harness was invoked"
  end

  defp tmp_repo! do
    dir = Path.join(System.tmp_dir!(), "kogen-precond-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)

    File.write!(Path.join(dir, "Makefile"), @makefile)
    File.write!(Path.join(dir, ".gitignore"), @gitignore)
    File.mkdir_p!(Path.join(dir, ".kogen"))
    File.write!(Path.join(dir, ".kogen/config.yaml"), @config_yaml)

    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dir, env: @git_env)

    dir
  end

  defp write_intent(dir, intent_yaml) do
    intent_dir = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @scenarios_yaml)

    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "add intent fixture"], cd: dir, env: @git_env)
  end

  defp commit_fixture!(dir) do
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture setup"], cd: dir, env: @git_env)
  end

  defp write_fake_harness!(dir, marker) do
    path = Path.join(dir, "fake-harness-that-must-never-run")

    File.mkdir_p!(dir)

    File.write!(path, """
    #!/bin/sh
    mkdir -p "$(dirname "#{marker}")"
    echo "invoked: $*" >> "#{marker}"
    exit 1
    """)

    File.chmod!(path, 0o755)
    path
  end
end
