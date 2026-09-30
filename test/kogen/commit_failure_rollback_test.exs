defmodule Kogen.CommitFailureRollbackTest do
  @moduledoc """
  R2: ordinary publication with honest manual handling of failure, not a
  recovery engine. Installs a real `commit-msg` git hook that always
  rejects the commit (simulating a pre-commit hook rejection, disk
  issue, or any other real `git commit` failure) and asserts:
  `Kogen.Build.run/1` restores the Candidate's Approved Intent exactly as
  it was, deletes the never-committed `complete/<slug>/`, returns the
  control package to Draft with its approved digest intact, and returns
  an honest error instead of ever reporting success — no CAS,
  no `commit-tree`, no general recovery machinery, just restoring the
  Candidate directories from data already on disk.
  """
  use Kogen.IsolatedCase, async: true

  @project_root Path.expand("../..", __DIR__)

  alias Kogen.Build.Tracking

  @slug "commit-fails-intent"

  @intent_yaml """
  id: 01960000-0000-7000-8000-00000000fa17
  slug: #{@slug}
  title: Commit fails intent
  status: approved
  may_change_guarded_paths:
    - dummy.txt
  """

  @scenarios_yaml """
  - id: fixture-scenario
    given: a fixture Candidate whose git commit is rejected by a hook
    when: Kogen.Build.run/1 reaches the accept step
    then: the Candidate's Approved Intent is restored, no Complete is left uncommitted, and control returns the package to Draft
    wrong_result: the Candidate loses its Approved Intent, complete/<slug>/ is left uncommitted, or the Draft package digest changes
    verified_by: [check]
    evidence: a real commit-msg hook that always rejects the commit
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
  offline_retries: 4
  """

  @makefile """
  .PHONY: check
  check:
  \t@true
  """

  test "restores the Approved Intent and leaves a clean worktree when git commit fails" do
    project_root = @project_root
    dest = Path.join(System.tmp_dir!(), "kogen-commitfail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    setup_fixture(project_root, dest)
    install_rejecting_commit_hook(dest)

    approved_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    draft_dir = Path.join(dest, ".kogen/intents/drafts/#{@slug}")
    intent_dir_original_files = approved_dir |> File.ls!() |> Enum.sort()
    original_package_digest = package_digest(approved_dir)

    fake_harness = Path.join(project_root, "test/support/fake_codex_simple_accept")
    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    head_before = git!(dest, ["rev-parse", "HEAD"])

    result = File.cd!(dest, fn -> Kogen.Build.run(@slug, nil, dest) end)

    assert {:error, reason} = result
    assert reason =~ "commit failed"
    assert reason =~ "Approved Intent restored"

    head_after = git!(dest, ["rev-parse", "HEAD"])
    assert head_after == head_before, "no Commit should have been made"

    complete_dir = Path.join(dest, ".kogen/intents/complete/#{@slug}")

    # The rejected commit leaves control unpublished and returns its package
    # to Draft. Candidate rollback separately restores its own Approved copy.
    refute File.dir?(approved_dir), "control must no longer offer failed approval to Build"
    assert File.dir?(draft_dir), "the terminally failed package must return to Draft"
    refute File.dir?(complete_dir), "no uncommitted Complete may be left looking like success"

    restored_files = draft_dir |> File.ls!() |> Enum.sort()
    assert restored_files == intent_dir_original_files

    assert File.read!(Path.join(draft_dir, "intent.yaml")) ==
             String.replace(@intent_yaml, "status: approved", "status: draft")

    assert File.read!(Path.join(draft_dir, "evidence.md")) == <<0, 255, 10, 13>>
    assert File.read!(Path.join(draft_dir, "build-evidence-1.md")) == "also supplied"
    assert File.read!(Path.join(draft_dir, "scenario-tracking.json")) == "user tracking zero\n"

    assert File.read!(Path.join(draft_dir, "scenario-tracking-1.json")) ==
             "user tracking one\n"

    [failed_runtime] = runtime_tracking_records(dest)
    failed_runtime_bytes = File.read!(failed_runtime)
    failed_record = Jason.decode!(failed_runtime_bytes)
    assert failed_record["status"] == "failed"
    assert failed_record["approved_package_digest"] == original_package_digest
    assert package_digest(draft_dir, :returned_draft) == original_package_digest
    refute File.dir?(Path.join(dest, ".kogen/runtime/raw"))

    assert_only_custody_paths_dirty!(dest, intent_dir_original_files)

    # The actual accept/commit/restore cycle ran in the Candidate: its own
    # copy of the Approved Intent (staged into Complete, then restored after
    # the rejected commit) is what the "Approved Intent restored" message
    # describes, and the retained Candidate proves the restoration happened
    # for real rather than trivially (control's copy was never touched).
    candidate = Kogen.CandidateFixture.candidate(dest)
    assert candidate["disposition"] == "retained"
    worktree = candidate["worktree_path"]
    assert File.dir?(worktree)
    assert worktree in Kogen.CandidateFixture.registered_worktrees(dest)

    candidate_approved_dir = Path.join(worktree, ".kogen/intents/approved/#{@slug}")
    candidate_complete_dir = Path.join(worktree, ".kogen/intents/complete/#{@slug}")

    assert File.dir?(candidate_approved_dir),
           "the Candidate's Approved Intent must be restored, not lost"

    refute File.dir?(candidate_complete_dir),
           "no uncommitted Complete may be left in the Candidate looking like success"

    candidate_restored_files = candidate_approved_dir |> File.ls!() |> Enum.sort()
    assert candidate_restored_files == intent_dir_original_files
    assert File.read!(Path.join(candidate_approved_dir, "intent.yaml")) == @intent_yaml
    assert File.read!(Path.join(candidate_approved_dir, "evidence.md")) == <<0, 255, 10, 13>>

    assert File.read!(Path.join(candidate_approved_dir, "build-evidence-1.md")) ==
             "also supplied"

    owner_record = candidate["owner_record"] |> File.read!() |> Jason.decode!()
    build_id = owner_record["build_id"]
    assert owner_record["status"] == "stopped: publication-failed"

    assert reason =~
             "Candidate kept: slug #{@slug}, build id #{build_id}, worktree #{worktree}, " <>
               "branch #{candidate["branch"]}, harness home #{candidate["harness_home"]}; " <>
               "remove it with `mix kogen.candidates.remove #{build_id}`"

    # Model a human explicitly reapproving the returned Draft before a new
    # Build. The package bytes, after the status transition, match the
    # original Approved digest again.
    draft_intent = Path.join(draft_dir, "intent.yaml")

    File.write!(
      draft_intent,
      String.replace(File.read!(draft_intent), "status: draft", "status: approved")
    )

    :ok = File.rename(draft_dir, approved_dir)
    assert package_digest(approved_dir) == original_package_digest

    File.rm!(Path.join(dest, ".git/hooks/commit-msg"))
    assert :ok = File.cd!(dest, fn -> Kogen.Build.run(@slug, nil, dest) end)
    refute File.exists?(approved_dir)
    refute File.exists?(draft_dir)
    assert File.read!(Path.join(complete_dir, "evidence.md")) == <<0, 255, 10, 13>>
    assert File.read!(Path.join(complete_dir, "build-evidence-1.md")) == "also supplied"
    assert File.read!(Path.join(complete_dir, "build-evidence-2.md")) =~ "Complete evidence"
    assert File.read!(Path.join(complete_dir, "scenario-tracking.json")) == "user tracking zero\n"

    assert File.read!(Path.join(complete_dir, "scenario-tracking-1.json")) ==
             "user tracking one\n"

    generated_summary =
      complete_dir
      |> Path.join("build-summary.json")
      |> File.read!()
      |> Jason.decode!()

    assert generated_summary["format"] == "kogen-build-summary"
    assert is_list(generated_summary["scenarios"])
    assert is_list(generated_summary["attempts"])
    assert is_list(generated_summary["findings"])
    assert generated_summary["full_record"]["byte_count"] > 0

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
    File.write!(config_path, @config_yaml)

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @scenarios_yaml)
    File.write!(Path.join(intent_dir, "evidence.md"), <<0, 255, 10, 13>>)
    File.write!(Path.join(intent_dir, "build-evidence-1.md"), "also supplied")
    File.write!(Path.join(intent_dir, "scenario-tracking.json"), "user tracking zero\n")
    File.write!(Path.join(intent_dir, "scenario-tracking-1.json"), "user tracking one\n")
    Kogen.VerificationFixture.install!(dest)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dest, "deps"))

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

  defp assert_only_custody_paths_dirty!(dest, files) do
    {porcelain, 0} =
      System.cmd("git", ["status", "--porcelain", "--untracked-files=all"], cd: dest)

    actual =
      porcelain
      |> String.split("\n", trim: true)
      |> Enum.map(fn <<status::binary-size(2), " ", path::binary>> -> {status, path} end)

    approved_paths = Enum.map(files, &".kogen/intents/approved/#{@slug}/#{&1}")
    draft_paths = Enum.map(files, &".kogen/intents/drafts/#{@slug}/#{&1}")
    expected_paths = Enum.sort(approved_paths ++ draft_paths)
    actual_paths = actual |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    assert actual_paths == expected_paths,
           "only paths in the approved-to-draft move may be dirty"

    assert Enum.all?(actual, fn
             {status, ".kogen/intents/approved/" <> _path} -> status in ["D ", " D"]
             {"??", ".kogen/intents/drafts/" <> _path} -> true
             _ -> false
           end),
           "Approved paths must be deleted and Draft files must be untracked"
  end

  defp package_digest(path, mode \\ :approved) do
    entries = package_entries(path, "")

    entries =
      if mode == :returned_draft do
        Enum.map(entries, fn
          {"intent.yaml", :regular, permissions, bytes} ->
            {"intent.yaml", :regular, permissions,
             Regex.replace(~r/^status:[ \t]*draft[ \t]*$/m, bytes, "status: approved")}

          entry ->
            entry
        end)
      else
        entries
      end

    Tracking.approved_digest(entries)
  end

  defp package_entries(root, relative) do
    path = Path.join(root, relative)
    stat = File.lstat!(path)

    case stat.type do
      :directory ->
        children =
          path
          |> File.ls!()
          |> Enum.sort()
          |> Enum.flat_map(&package_entries(root, Path.join(relative, &1)))

        [{relative, :directory, stat.mode} | children]

      :regular ->
        [{relative, :regular, stat.mode, File.read!(path)}]

      _ ->
        raise "unsupported package entry: #{path}"
    end
  end
end
