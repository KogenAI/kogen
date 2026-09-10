defmodule Kogen.CommitFailureRollbackTest do
  @moduledoc """
  R2: ordinary publication with honest manual handling of failure, not a
  recovery engine. Installs a real `commit-msg` git hook that always
  rejects the commit (simulating a pre-commit hook rejection, disk
  issue, or any other real `git commit` failure) and asserts:
  `Kogen.Build.run/1` restores the Approved Intent directory exactly as
  it was, deletes the never-committed `complete/<slug>/`, leaves
  `git status --porcelain` empty again, and returns an honest error
  instead of ever reporting success — no CAS, no `commit-tree`, no
  general recovery machinery, just restoring the two directories from
  data already on disk.
  """
  use Kogen.IsolatedCase, async: true

  @slug "commit-fails-intent"

  @intent_yaml """
  id: 01960000-0000-7000-8000-00000000fa17
  slug: #{@slug}
  title: Commit fails intent
  may_change_guarded_paths:
    - dummy.txt
  """

  @scenarios_yaml """
  - id: fixture-scenario
    given: a fixture Candidate whose git commit is rejected by a hook
    when: Kogen.Build.run/1 reaches the accept step
    then: the Approved Intent is restored, no Complete is left uncommitted, and the worktree is clean again
    wrong_result: approved/<slug>/ is gone, complete/<slug>/ is left untracked, or git status is dirty afterward
    verified_by: [check]
    evidence: a real commit-msg hook that always rejects the commit
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

  test "restores the Approved Intent and leaves a clean worktree when git commit fails" do
    project_root = File.cwd!()
    dest = Path.join(System.tmp_dir!(), "kogen-commitfail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    setup_fixture(project_root, dest)
    install_rejecting_commit_hook(dest)

    intent_dir_original_files =
      dest
      |> Path.join(".kogen/intents/approved/#{@slug}")
      |> File.ls!()
      |> Enum.sort()

    fake_harness = Path.join(project_root, "test/support/fake_codex_simple_accept")
    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    head_before = git!(dest, ["rev-parse", "HEAD"])

    result = File.cd!(dest, fn -> Kogen.Build.run(@slug) end)

    assert {:error, reason} = result
    assert reason =~ "commit failed"
    assert reason =~ "Approved Intent restored"

    head_after = git!(dest, ["rev-parse", "HEAD"])
    assert head_after == head_before, "no Commit should have been made"

    approved_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    complete_dir = Path.join(dest, ".kogen/intents/complete/#{@slug}")

    assert File.dir?(approved_dir), "the Approved Intent must be restored, not lost"
    refute File.dir?(complete_dir), "no uncommitted Complete may be left looking like success"

    restored_files = approved_dir |> File.ls!() |> Enum.sort()
    assert restored_files == intent_dir_original_files

    assert File.read!(Path.join(approved_dir, "intent.yaml")) == @intent_yaml
    assert File.read!(Path.join(approved_dir, "evidence.md")) == <<0, 255, 10, 13>>
    assert File.read!(Path.join(approved_dir, "build-evidence-1.md")) == "also supplied"
    assert File.read!(Path.join(approved_dir, "scenario-tracking.json")) == "user tracking zero\n"

    assert File.read!(Path.join(approved_dir, "scenario-tracking-1.json")) ==
             "user tracking one\n"

    [failed_runtime] = runtime_tracking_records(dest)
    failed_runtime_bytes = File.read!(failed_runtime)
    assert Jason.decode!(failed_runtime_bytes)["status"] == "failed"
    refute File.dir?(Path.join(dest, ".kogen/runtime/raw"))

    assert git!(dest, ["status", "--porcelain"]) == "",
           "the worktree must be exactly as clean as before this failed attempt"

    File.rm!(Path.join(dest, ".git/hooks/commit-msg"))
    assert :ok = File.cd!(dest, fn -> Kogen.Build.run(@slug) end)
    refute File.exists?(approved_dir)
    assert File.read!(Path.join(complete_dir, "evidence.md")) == <<0, 255, 10, 13>>
    assert File.read!(Path.join(complete_dir, "build-evidence-1.md")) == "also supplied"
    assert File.read!(Path.join(complete_dir, "build-evidence-2.md")) =~ "Complete evidence"
    assert File.read!(Path.join(complete_dir, "scenario-tracking.json")) == "user tracking zero\n"

    assert File.read!(Path.join(complete_dir, "scenario-tracking-1.json")) ==
             "user tracking one\n"

    generated_tracking =
      complete_dir
      |> Path.join("scenario-tracking-2.json")
      |> File.read!()
      |> Jason.decode!()

    assert generated_tracking["status"] == "accepted"
    assert is_list(generated_tracking["scenarios"])
    assert is_list(generated_tracking["attempts"])
    assert is_list(generated_tracking["findings"])

    runtime_records = runtime_tracking_records(dest)
    assert length(runtime_records) == 2
    assert failed_runtime_bytes in Enum.map(runtime_records, &File.read!/1)
    assert git!(dest, ["status", "--porcelain"]) == ""
  end

  defp setup_fixture(project_root, dest) do
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

    config_path = Path.join(dest, ".kogen/config.yaml")
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, @config_yaml)

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @scenarios_yaml)
    File.write!(Path.join(intent_dir, "evidence.md"), <<0, 255, 10, 13>>)
    File.write!(Path.join(intent_dir, "build-evidence-1.md"), "also supplied")
    File.write!(Path.join(intent_dir, "scenario-tracking.json"), "user tracking zero\n")
    File.write!(Path.join(intent_dir, "scenario-tracking-1.json"), "user tracking one\n")

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

  defp install_rejecting_commit_hook(dest) do
    hooks_dir = Path.join(dest, ".git/hooks")
    File.mkdir_p!(hooks_dir)

    hook_path = Path.join(hooks_dir, "commit-msg")

    File.write!(hook_path, """
    #!/bin/sh
    echo "rejected by test fixture commit-msg hook" >&2
    exit 1
    """)

    File.chmod!(hook_path, 0o755)
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end

  defp runtime_tracking_records(dest) do
    dest
    |> Path.join(".kogen/runtime/scenario-tracking/*/record.json")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
