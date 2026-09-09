defmodule Kogen.TwoOuterResumptionsTest do
  @moduledoc """
  Scenario "two-outer-resumptions-then-stop": a Developer whose Candidate
  keeps failing Review. The third non-accepting outcome must stop the
  Build with a reason, create no Commit, and consume exactly two
  `Codex resume` launches (never a third).

  Runs `Kogen.Build.run/1` in-process against a minimal fixture repo (no
  real Elixir/mix project needed here: `make check` in the fixture is a
  trivial always-passing target, since this test is about resumption
  counting, not about `make check` itself, which the full lifecycle test
  in test/kogen/lifecycle_test.exs already exercises for real).
  """
  use Kogen.IsolatedCase, async: true

  @slug "always-rework-intent"

  @intent_yaml """
  id: 01960000-0000-7000-8000-00000000a1ea
  slug: #{@slug}
  title: Always rework intent
  may_change_guarded_paths:
    - dummy.txt
  """

  @scenarios_yaml """
  - id: fake-scenario
    given: a fake Candidate
    when: the fake Reviewer always answers rework
    then: the Build stops after two outer resumptions
    wrong_result: a third resume happens, or a Commit is made
    verified_by: [check]
    evidence: fake Reviewer scripted to answer rework three times
  """

  @config_yaml """
  harness: codex
  shaping:   {model: fake, effort: low}
  developer: {model: fake, effort: low}
  reviewer:  {model: fake, effort: low}
  helpers:
    scout:  {model: fake, effort: low}
    worker: {model: fake, effort: medium}
    expert: {model: fake, effort: medium}
  outer_resumptions: 2
  """

  @makefile """
  .PHONY: check
  check:
  \t@true
  """

  test "stops after two outer resumptions when Review never accepts" do
    project_root = File.cwd!()
    dest = Path.join(System.tmp_dir!(), "kogen-rework-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    File.mkdir_p!(Path.join(dest, ".codex/hooks"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/check.sh"),
      Path.join(dest, ".codex/hooks/check.sh")
    )

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)
    File.cp!(Path.join(project_root, ".codex/hooks.json"), Path.join(dest, ".codex/hooks.json"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/verification_policy.py"),
      Path.join(dest, ".codex/hooks/verification_policy.py")
    )

    File.mkdir_p!(Path.join(dest, "priv/kogen/prompts"))

    for prompt <- ["developer.md", "reviewer.md"] do
      File.cp!(
        Path.join(project_root, "priv/kogen/prompts/#{prompt}"),
        Path.join(dest, "priv/kogen/prompts/#{prompt}")
      )
    end

    File.write!(Path.join(dest, "Makefile"), @makefile)
    File.write!(Path.join(dest, ".gitignore"), ".kogen/build.lock\n.kogen/runtime/\n")

    File.write!(
      Path.join(dest, ".kogen/config.yaml") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      @config_yaml
    )

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @scenarios_yaml)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)

    head_before = git!(dest, ["rev-parse", "HEAD"])

    fake_harness = Path.join(project_root, "test/support/fake_codex_always_rework")
    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    result =
      File.cd!(dest, fn ->
        Kogen.Build.run(@slug)
      end)

    assert {:error, reason} = result
    assert reason =~ "stopped after 2 outer resumptions"

    head_after = git!(dest, ["rev-parse", "HEAD"])
    assert head_after == head_before, "no Commit should have been made"

    refute File.dir?(Path.join(dest, ".kogen/intents/complete/#{@slug}"))
    assert File.dir?(intent_dir), "the approved Intent directory must be left as-is"
    refute File.exists?(Path.join(dest, ".kogen/build.lock")), "the lock must be released"

    log_lines =
      Path.join(dest, ".kogen/runtime/fake-harness-log")
      |> File.read!()
      |> String.split("\n", trim: true)

    resume_calls = Enum.count(log_lines, &String.contains?(&1, "exec resume"))
    reviewer_calls = Enum.count(log_lines, &String.contains?(&1, "--output-schema"))

    assert resume_calls == 2,
           "expected exactly two Codex resume launches, log:\n#{Enum.join(log_lines, "\n")}"

    assert reviewer_calls == 3,
           "expected exactly three Reviewer launches (all rework), log:\n#{Enum.join(log_lines, "\n")}"
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
