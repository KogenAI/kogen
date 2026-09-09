Code.require_file("../support/precondition_fixture.ex", __DIR__)

defmodule Kogen.BuildPreconditionsTest do
  @moduledoc """
  Scenario `build-refuses-unready-state`: execution precondition
  failures returns `{:error, one_line_reason}` naming the specific failed
  precondition and never invokes the harness. Runs in an isolated OS process (via
  `File.cd!/2`) against real temporary git repos, since `Kogen.Build`,
  `Kogen.Git`, and `Kogen.Check` all resolve relative paths against the
  process's current working directory. Each async case has private
  cwd and environment state.
  """
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
  shaping:   {model: gpt-6-astra, effort: low}
  developer: {model: gpt-6-astra, effort: low}
  reviewer:  {model: gpt-6-astra, effort: low}
  helpers:
    scout:  {model: gpt-5.6-luna, effort: low}
    worker: {model: gpt-5.6-terra, effort: medium}
    expert: {model: gpt-6-astra, effort: medium}
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

  @project_root Path.expand("../..", __DIR__)
  template =
    if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
      Kogen.PreconditionFixture.child_template!()
    else
      Kogen.PreconditionFixture.create!(
        @project_root,
        [
          {"Makefile", @makefile},
          {".gitignore", @gitignore},
          {".kogen/config.yaml", @config_yaml},
          {".kogen/intents/approved/#{@slug}/intent.yaml", @valid_intent},
          {".kogen/intents/approved/#{@slug}/scenarios.yaml", @scenarios_yaml}
        ],
        @git_env
      )
    end

  @template template

  unless System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
    ExUnit.after_suite(fn _ -> File.rm_rf(template) end)
  end

  @precondition_cases [
                        %{
                          case: "intent.yaml missing title",
                          operation: :missing_title,
                          expected: "missing required key: title"
                        },
                        %{
                          case: "dirty worktree",
                          operation: :dirty_worktree,
                          expected: "worktree is not clean"
                        },
                        %{
                          case: "detached HEAD",
                          operation: :detached_head,
                          expected: "detached HEAD"
                        },
                        %{
                          case: "existing Complete package",
                          operation: :complete_package,
                          expected: "Complete Intent already exists"
                        },
                        %{
                          case: "missing configuration",
                          operation: :missing_config,
                          expected: "missing .kogen/config.yaml"
                        },
                        %{
                          case: "missing check target",
                          operation: :missing_check_target,
                          expected: "Makefile has no check target"
                        },
                        %{
                          case: "missing verification policy",
                          operation: :missing_policy,
                          expected: "required verification policy file"
                        },
                        %{
                          case: "missing verification hook registration",
                          operation: :missing_hook_registration,
                          expected: "verification-policy hook is not registered"
                        },
                        %{
                          case: "undeclared verification target",
                          operation: {:verification_target, "not-declared"},
                          expected: "undeclared make target"
                        },
                        %{
                          case: "unsafe verification target",
                          operation: {:verification_target, "--eval=bad"},
                          expected: "refused unsafe target name"
                        },
                        %{
                          case: "scalar scenarios",
                          operation: {:scenarios, "- scalar\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "scalar verified_by",
                          operation: {:scenarios, "- verified_by: check\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "empty scenarios",
                          operation: {:scenarios, "[]\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "empty verified_by",
                          operation: {:scenarios, "- verified_by: []\n"},
                          expected: "scenarios.yaml missing or invalid"
                        },
                        %{
                          case: "non-string title",
                          operation:
                            {:intent_replacement, "title: Precondition fixture intent",
                             "title: []"},
                          expected: "title"
                        },
                        %{
                          case: "non-string guarded path",
                          operation: {:intent_replacement, "  - lib/**", "  - 123"},
                          expected: "may_change_guarded_paths"
                        },
                        %{
                          case: "mismatched slug",
                          operation:
                            {:intent_replacement, "slug: #{@slug}", "slug: other-intent"},
                          expected: "slug does not match"
                        },
                        %{
                          case: "unsupported configured harness",
                          operation: :unsupported_harness,
                          expected: "unsupported harness"
                        },
                        %{
                          case: "negative resumption budget",
                          operation: :negative_resumption_budget,
                          expected: "outer_resumptions"
                        },
                        %{
                          case: "existing build lock",
                          operation: :existing_lock,
                          expected: "build lock already present"
                        }
                      ]
                      |> Enum.map(&Map.put(&1, :template, @template))

  use Kogen.IsolatedCase, async: true, parameterize: @precondition_cases

  test "precondition failures never launch the harness", %{
    operation: operation,
    expected: expected
  } do
    run_precondition_case(operation, expected)
  end

  # -- fixture plumbing --------------------------------------------------

  defp run_precondition_case(operation, expected) do
    dir = tmp_repo!()
    setup_case!(dir, operation)

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
    assert reason =~ expected
    assert File.exists?(Path.join(dir, ".kogen/build.lock")) == lock_was_present
    refute File.exists?(marker), "the fake harness marker exists: the harness was invoked"
  end

  defp setup_case!(dir, :missing_title), do: write_intent(dir, @intent_missing_title)

  defp setup_case!(dir, :dirty_worktree) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, "dirty.txt"), "uncommitted\n")
  end

  defp setup_case!(dir, :detached_head) do
    write_intent(dir, @valid_intent)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    {_out, 0} = System.cmd("git", ["checkout", "-q", String.trim(sha)], cd: dir)
  end

  defp setup_case!(dir, :complete_package) do
    write_intent(dir, @valid_intent)
    complete = Path.join(dir, ".kogen/intents/complete/#{@slug}")
    File.mkdir_p!(complete)
    File.write!(Path.join(complete, "intent.yaml"), @valid_intent)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_config) do
    write_intent(dir, @valid_intent)
    File.rm!(Path.join(dir, ".kogen/config.yaml"))
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_check_target) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, "Makefile"), "other:\n\t@true\n")
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_policy) do
    write_intent(dir, @valid_intent)
    File.rm!(Path.join(dir, ".codex/hooks/verification_policy.py"))
    commit_fixture!(dir)
  end

  defp setup_case!(dir, :missing_hook_registration) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, ".codex/hooks.json"), ~s({"hooks":{"Stop":[]}}))
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:verification_target, target}) do
    write_intent(dir, @valid_intent)
    scenarios = String.replace(@scenarios_yaml, "[check]", inspect([target]))
    File.write!(Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"), scenarios)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:scenarios, scenarios}) do
    write_intent(dir, @valid_intent)
    File.write!(Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml"), scenarios)
    commit_fixture!(dir)
  end

  defp setup_case!(dir, {:intent_replacement, old, replacement}) do
    write_intent(dir, String.replace(@valid_intent, old, replacement))
  end

  defp setup_case!(dir, :unsupported_harness) do
    write_intent(dir, @valid_intent)

    File.write!(
      Path.join(dir, ".kogen/config.yaml"),
      String.replace(@config_yaml, "harness: codex", "harness: unsupported")
    )

    commit_fixture!(dir)
  end

  defp setup_case!(dir, :negative_resumption_budget) do
    write_intent(dir, @valid_intent)

    File.write!(
      Path.join(dir, ".kogen/config.yaml"),
      String.replace(@config_yaml, "outer_resumptions: 2", "outer_resumptions: -1")
    )

    commit_fixture!(dir)
  end

  defp setup_case!(dir, :existing_lock) do
    write_intent(dir, @valid_intent)
    lock_dir = Path.join(dir, ".kogen")
    File.mkdir_p!(lock_dir)
    File.write!(Path.join(lock_dir, "build.lock"), "")
  end

  defp tmp_repo! do
    dir = Kogen.PreconditionFixture.copy!(@template)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_intent(dir, intent_yaml) do
    intent_dir = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    intent_path = Path.join(intent_dir, "intent.yaml")
    scenarios_path = Path.join(intent_dir, "scenarios.yaml")

    changed? =
      File.read!(intent_path) != intent_yaml or File.read!(scenarios_path) != @scenarios_yaml

    if changed? do
      File.write!(intent_path, intent_yaml)
      File.write!(scenarios_path, @scenarios_yaml)

      {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)

      {_out, 0} =
        System.cmd("git", ["commit", "-q", "-m", "add intent fixture"], cd: dir, env: @git_env)
    end
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
