defmodule Kogen.ReviewerMutationTest do
  @moduledoc """
  Scenario "reviewer-is-fresh-and-read-only", the `wrong_result` half: if
  the Reviewer edits the Candidate (even while still answering `accept`),
  Kogen must recompute the Candidate id after Review, notice it no longer
  matches, and abort the Build with a mutation reason instead of
  committing whatever the Reviewer left behind.
  """
  use Kogen.IsolatedCase, async: true

  @slug "reviewer-mutates-intent"

  @intent_yaml """
  id: 01960000-0000-7000-8000-00000000bea7
  slug: #{@slug}
  title: Reviewer mutates intent
  may_change_guarded_paths:
    - dummy.txt
  """

  @scenarios_yaml """
  - id: fake-scenario
    given: a fake Candidate
    when: the fake Reviewer mutates the worktree before answering accept
    then: Kogen aborts the Build with a Candidate-mutation reason instead of committing
    wrong_result: the Reviewer's edit is silently committed
    verified_by: [check]
    evidence: fake Reviewer touches a file before answering accept
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

  test "aborts instead of committing when the Reviewer mutates the Candidate" do
    project_root = File.cwd!()
    dest = Path.join(System.tmp_dir!(), "kogen-revmut-#{System.unique_integer([:positive])}")
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

    for prompt <- ["developer.md", "reviewer.md", "execution-policy.md"] do
      File.cp!(
        Path.join(project_root, "priv/kogen/prompts/#{prompt}"),
        Path.join(dest, "priv/kogen/prompts/#{prompt}")
      )
    end

    File.write!(Path.join(dest, "Makefile"), @makefile)
    File.write!(Path.join(dest, ".gitignore"), ".kogen/build.lock\n.kogen/runtime/\n")

    config_path = Path.join(dest, ".kogen/config.yaml")
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, @config_yaml)

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

    fake_harness = Path.join(project_root, "test/support/fake_codex_reviewer_mutates")
    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    result = File.cd!(dest, fn -> Kogen.Build.run(@slug) end)

    assert {:error, reason} = result
    assert reason =~ "Candidate mutated during verification or Review"

    head_after = git!(dest, ["rev-parse", "HEAD"])
    assert head_after == head_before, "no Commit should have been made"

    refute File.dir?(Path.join(dest, ".kogen/intents/complete/#{@slug}"))

    assert File.exists?(Path.join(dest, "tampered.txt")),
           "sanity: the fake reviewer's mutation really happened"
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
