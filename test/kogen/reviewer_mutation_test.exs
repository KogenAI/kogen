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

  @claude_config_yaml """
  default_route: claude
  routes:
    claude:
      harness: claude
      shaping:   {model: claude-opus-5-5, effort: medium}
      developer: {model: claude-opus-5-5, effort: medium}
      reviewer:  {model: claude-opus-5-5, effort: medium}
      helpers:
        scout:  {model: claude-sonnet-5, effort: low}
        worker: {model: claude-sonnet-5, effort: medium}
        expert: {model: claude-opus-5-5, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  @hybrid_config_yaml """
  default_route: hybrid
  routes:
    hybrid:
      shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
      developer: {harness: claude, model: claude-opus-5-5, effort: medium}
      reviewer:  {harness: codex, model: gpt-6-sol, effort: high}
      expert:    {harness: codex, model: gpt-6-sol, effort: high}
      helpers:
        claude:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
        codex:
          scout:  {model: gpt-6-luna, effort: low}
          worker: {model: gpt-6-luna, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  @makefile """
  .PHONY: check
  check:
  \t@true
  """

  test "aborts instead of committing when the Reviewer mutates the Candidate" do
    aborts_on_reviewer_mutation!("codex")
  end

  test "aborts instead of committing when the Claude Code Reviewer mutates the Candidate" do
    aborts_on_reviewer_mutation!("claude")
  end

  # Scenario "reviewer-is-fresh-and-read-only" on a hybrid (role-level) route:
  # the Reviewer runs only on the adversarial Codex harness while the
  # Developer runs on the dominant Claude Code harness. A Codex-side Reviewer
  # that mutates the Candidate must still be caught and stop the Build.
  test "aborts instead of committing when the hybrid route's Codex Reviewer mutates the Candidate" do
    dest = setup_hybrid_reviewer_fixture!()

    System.put_env("FAKE_HYBRID_REVIEW", "accept")
    System.put_env("FAKE_HYBRID_REVIEWER_MUTATES", "1")

    head_before = git!(dest, ["rev-parse", "HEAD"])
    result = File.cd!(dest, fn -> Kogen.Build.run(@slug) end)

    assert {:error, reason} = result
    assert reason =~ "Candidate mutated during verification or Review"

    head_after = git!(dest, ["rev-parse", "HEAD"])
    assert head_after == head_before, "no Commit should have been made"

    refute File.dir?(Path.join(dest, ".kogen/intents/complete/#{@slug}"))

    assert File.exists?(Path.join(dest, "tampered.txt")),
           "sanity: the hybrid route's Codex Reviewer mutation really happened"
  end

  # Scenario "reviewer-verdict-must-be-schema-valid" on the same hybrid route:
  # a malformed verdict from the adversarial Codex Reviewer must still be
  # refused, naming the Reviewer's own frozen harness in the failure.
  test "refuses a malformed verdict from the hybrid route's Codex Reviewer" do
    dest = setup_hybrid_reviewer_fixture!()

    System.put_env("FAKE_HYBRID_REVIEWER_MALFORMED", "1")

    head_before = git!(dest, ["rev-parse", "HEAD"])
    result = File.cd!(dest, fn -> Kogen.Build.run(@slug) end)

    assert {:error, reason} = result
    assert reason =~ "Reviewer failure: "
    assert reason =~ "(reviewer on harness codex, gpt-6-sol at high)"

    head_after = git!(dest, ["rev-parse", "HEAD"])
    assert head_after == head_before, "no Commit should have been made"

    refute File.dir?(Path.join(dest, ".kogen/intents/complete/#{@slug}"))
  end

  defp aborts_on_reviewer_mutation!(harness) do
    project_root = File.cwd!()
    dest = Path.join(System.tmp_dir!(), "kogen-revmut-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    File.mkdir_p!(Path.join(dest, ".codex/hooks"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/check.sh"),
      Path.join(dest, ".codex/hooks/check.sh")
    )

    File.cp!(
      Path.join(project_root, ".codex/hooks/stop_runner.py"),
      Path.join(dest, ".codex/hooks/stop_runner.py")
    )

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)

    File.cp!(
      Path.join(project_root, ".codex/hooks/environment.py"),
      Path.join(dest, ".codex/hooks/environment.py")
    )

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
    File.write!(config_path, if(harness == "claude", do: @claude_config_yaml, else: @config_yaml))

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @scenarios_yaml)
    Kogen.VerificationFixture.install!(dest)

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

    fake_harness =
      if harness == "claude",
        do: Path.join(project_root, "test/support/fake_claude"),
        else: Path.join(project_root, "test/support/fake_codex_reviewer_mutates")

    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    if harness == "claude" do
      claude_root = Path.join(dest <> "-claude", "claude")
      File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
      on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)
      System.put_env("KOGEN_CLAUDE_ROOT", claude_root)
      System.put_env("FAKE_CLAUDE_REVIEWER_MUTATES", "1")
      System.put_env("FAKE_CLAUDE_REVIEW", "accept")
      System.put_env("FAKE_CLAUDE_STOP_BLOCK", "0")
    end

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

  # Shared fixture for the two hybrid-route Reviewer tests: a Developer on
  # Claude Code and a Reviewer on Codex, dispatched through the single
  # `fake_hybrid` executable. Sets `KOGEN_HARNESS`/`KOGEN_CLAUDE_ROOT` and the
  # `fake_hybrid` Reviewer environment variables the caller still needs to set
  # (`FAKE_HYBRID_REVIEW`, `FAKE_HYBRID_REVIEWER_MUTATES`, or
  # `FAKE_HYBRID_REVIEWER_MALFORMED`), all restored in `on_exit`.
  defp setup_hybrid_reviewer_fixture! do
    project_root = File.cwd!()

    dest =
      Path.join(System.tmp_dir!(), "kogen-revmut-hybrid-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    File.mkdir_p!(Path.join(dest, ".codex/hooks"))

    for hook <- ~w(check.sh stop_runner.py environment.py verification_policy.py) do
      File.cp!(
        Path.join(project_root, ".codex/hooks/#{hook}"),
        Path.join(dest, ".codex/hooks/#{hook}")
      )
    end

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)
    File.cp!(Path.join(project_root, ".codex/hooks.json"), Path.join(dest, ".codex/hooks.json"))

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
    File.write!(config_path, @hybrid_config_yaml)

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @scenarios_yaml)
    Kogen.VerificationFixture.install!(dest)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)

    fake_harness = Path.join(project_root, "test/support/fake_hybrid")
    claude_root = Path.join(dest <> "-claude", "claude")
    File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)

    original_env =
      Map.new(
        ~w(KOGEN_HARNESS KOGEN_CLAUDE_ROOT FAKE_CLAUDE_STOP_BLOCK FAKE_HYBRID_REVIEW
           FAKE_HYBRID_REVIEWER_MUTATES FAKE_HYBRID_REVIEWER_MALFORMED),
        &{&1, System.get_env(&1)}
      )

    on_exit(fn -> Enum.each(original_env, &restore_env/1) end)

    System.put_env("KOGEN_HARNESS", fake_harness)
    System.put_env("KOGEN_CLAUDE_ROOT", claude_root)
    System.put_env("FAKE_CLAUDE_STOP_BLOCK", "0")

    dest
  end

  defp restore_env({key, nil}), do: System.delete_env(key)
  defp restore_env({key, value}), do: System.put_env(key, value)

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
