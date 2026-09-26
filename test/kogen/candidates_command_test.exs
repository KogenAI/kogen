defmodule Kogen.CandidatesCommandTest do
  @moduledoc """
  Scenario `candidate-commands`: `mix kogen.candidates` and
  `mix kogen.candidates.remove` operate on exactly one project's Candidates,
  under a `KOGEN_WORKSPACES_ROOT` whose path contains a space, next to another
  project's Candidates and a Kogen-foreign worktree.

  Every test builds its own pair of real Git control checkouts (`P`, the
  Shaper's project, and `Q`, an unrelated project sharing the same
  workspaces root) and fabricates Candidates by hand -- linked worktrees,
  owner records and, where needed, a build lock -- exactly as
  `Kogen.Build.Workspace` would have left them, so the commands under test
  are exercised without depending on `Workspace.create/2`.
  """

  use Kogen.IsolatedCase, async: true

  import ExUnit.CaptureIO

  alias Kogen.Build.Workspace
  alias Mix.Tasks.Kogen.Candidates
  alias Mix.Tasks.Kogen.Candidates.Remove, as: CandidatesRemove

  @env [
    {"GIT_AUTHOR_NAME", "Kogen Fixture"},
    {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
    {"GIT_COMMITTER_NAME", "Kogen Fixture"},
    {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
  ]

  # `Kogen.IsolatedCase` also runs setup in the parent VM, where swapping
  # KOGEN_WORKSPACES_ROOT would race other tests' Builds; the parent only
  # dispatches, so it gets placeholders for the pattern keys.
  setup do
    if Kogen.WorkspaceFixture.isolated_child?(), do: projects(), else: %{p: nil, q: nil}
  end

  defp projects do
    root = Path.join(System.tmp_dir!(), "kogen cand root #{System.unique_integer([:positive])}")
    prior_root = System.get_env("KOGEN_WORKSPACES_ROOT")
    System.put_env("KOGEN_WORKSPACES_ROOT", root)

    on_exit(fn ->
      File.rm_rf(root)

      if prior_root,
        do: System.put_env("KOGEN_WORKSPACES_ROOT", prior_root),
        else: System.delete_env("KOGEN_WORKSPACES_ROOT")
    end)

    p = control_repo("project-p")
    q = control_repo("project-q")

    on_exit(fn ->
      File.rm_rf(p.control)
      File.rm_rf(q.control)
    end)

    {:ok, p: p, q: q}
  end

  # -- Given: the fixed scenario ---------------------------------------------

  # Builds every Candidate and the foreign worktree the scenario describes,
  # writing the currently-held build lock to `p3`'s build id with a live pid
  # (the running Candidate) after having proved, with a separate lock write,
  # that a matching build id with a dead pid is correctly not live.
  defp scenario(p, q) do
    p1 =
      new_worktree(p.control, "alpha", "p1stopped", p.commit)
      |> write_owner!("stopped: integrity")

    File.write!(Path.join(p1.path, "untracked.txt"), "uncommitted edit\n")

    p2 = new_worktree(p.control, "beta", "p2accepted", p.commit)
    p2_commit = commit_in_worktree(p2, "beta change\n")
    p2 = write_owner!(p2, "accepted-unpublished: branch main moved", p2_commit)

    p3 = new_worktree(p.control, "gamma", "p3running", p.commit) |> write_owner!("running")
    p4 = new_worktree(p.control, "delta", "p4stale", p.commit) |> write_owner!("running")

    # Prove the dead-pid branch of `Workspace.live_lock?/2` directly, naming
    # the stale record's own build id, before the lock moves to the Candidate
    # that actually holds it for the rest of the scenario.
    write_lock(p.control, p4.build_id, dead_pid())
    refute Workspace.live_lock?(p.control, p4.build_id)
    write_lock(p.control, p3.build_id, live_pid())

    foreign_path = Path.join(p.path, ".kogen/runtime/build-worktrees/checkouts/foreign")
    File.mkdir_p!(Path.dirname(foreign_path))
    git!(p.control, ["worktree", "add", "-b", "foreign", foreign_path, "HEAD"])

    q1 =
      new_worktree(q.control, "zeta", "q1stopped", q.commit) |> write_owner!("stopped: integrity")

    %{p1: p1, p2: p2, p2_commit: p2_commit, p3: p3, p4: p4, q1: q1, foreign_path: foreign_path}
  end

  # -- Then: the list -----------------------------------------------------

  test "list shows only P's Candidates with build id, slug, title, status, start time, branch and path",
       %{p: p, q: q} do
    fixtures = scenario(p, q)

    records = p.control |> Workspace.list() |> Enum.map(fn {:ok, record} -> record end)
    ids = Enum.map(records, & &1["build_id"])

    assert Enum.sort(ids) ==
             Enum.sort([
               fixtures.p1.build_id,
               fixtures.p2.build_id,
               fixtures.p3.build_id,
               fixtures.p4.build_id
             ])

    refute fixtures.q1.build_id in ids
    refute Enum.any?(records, &(&1["worktree_path"] == fixtures.foreign_path))

    by_id = Map.new(records, &{&1["build_id"], &1})
    assert by_id[fixtures.p1.build_id]["status"] == "stopped: integrity"
    assert by_id[fixtures.p2.build_id]["status"] =~ "accepted-unpublished"
    assert by_id[fixtures.p3.build_id]["status"] == "running"
    assert by_id[fixtures.p4.build_id]["status"] == "stopped: interrupted"

    for candidate <- [fixtures.p1, fixtures.p2, fixtures.p3, fixtures.p4] do
      record = by_id[candidate.build_id]
      assert record["slug"] == candidate.slug
      assert record["title"] == candidate.title
      assert record["branch"] == candidate.branch
      assert record["worktree_path"] == candidate.path
      assert is_binary(record["started_at"])
    end
  end

  test "mix kogen.candidates prints every field for P's Candidates and none of Q's or the foreign worktree's",
       %{p: p, q: q} do
    fixtures = scenario(p, q)

    output =
      capture_io(fn ->
        File.cd!(p.control, fn -> Candidates.run([]) end)
      end)

    for candidate <- [fixtures.p1, fixtures.p2, fixtures.p3, fixtures.p4] do
      assert output =~ candidate.build_id
      assert output =~ candidate.slug
      assert output =~ candidate.title
      assert output =~ candidate.path
      assert output =~ candidate.branch
    end

    assert output =~ "stopped: interrupted"
    assert output =~ "running"
    refute output =~ fixtures.q1.build_id
    refute output =~ fixtures.foreign_path
  end

  # -- Then: remove deletes a stopped Candidate ------------------------------

  test "remove deletes a stopped Candidate's worktree, branch, harness home and owner record",
       %{p: p, q: q} do
    fixtures = scenario(p, q)
    p1 = fixtures.p1

    assert {:ok, lines} = Workspace.remove(p.control, p1.build_id)
    assert Enum.any?(lines, &(&1 =~ "removed worktree #{p1.path}"))
    assert Enum.any?(lines, &(&1 =~ "removed branch #{p1.branch}"))
    assert Enum.any?(lines, &(&1 =~ "removed harness home #{p1.harness_home}"))
    assert Enum.any?(lines, &(&1 =~ "removed owner record #{p1.owner_path}"))

    refute File.exists?(p1.path)
    refute branch_exists?(p.control, p1.branch)
    refute File.exists?(p1.harness_home)
    refute File.exists?(p1.owner_path)
  end

  # -- Then: remove refuses the running Candidate ----------------------------

  test "remove refuses the running Candidate", %{p: p, q: q} do
    fixtures = scenario(p, q)
    p3 = fixtures.p3

    assert {:error, reason} = Workspace.remove(p.control, p3.build_id)
    assert reason =~ "refused"
    assert reason =~ "running"

    assert File.exists?(p3.path)
    assert branch_exists?(p.control, p3.branch)
    assert File.exists?(p3.owner_path)
  end

  # -- Then: an accepted-unpublished commit not reachable is refused, then removable with the flag

  test "remove refuses a Candidate holding a commit not reachable from its admitted branch without --discard-accepted",
       %{p: p, q: q} do
    fixtures = scenario(p, q)
    p2 = fixtures.p2

    assert {:error, reason} = Workspace.remove(p.control, p2.build_id)
    assert reason =~ "refused"
    assert reason =~ "--discard-accepted"

    assert File.exists?(p2.path)
    assert branch_exists?(p.control, p2.branch)
    assert File.exists?(p2.owner_path)
  end

  test "remove deletes a Candidate holding a commit not reachable from its admitted branch when --discard-accepted is passed",
       %{p: p, q: q} do
    fixtures = scenario(p, q)
    p2 = fixtures.p2

    assert {:ok, lines} = Workspace.remove(p.control, p2.build_id, discard_accepted: true)
    assert Enum.any?(lines, &(&1 =~ "removed worktree"))

    refute File.exists?(p2.path)
    refute branch_exists?(p.control, p2.branch)
    refute File.exists?(p2.owner_path)
  end

  # -- Then: a commit the Shaper has fast-forwarded onto the admitted branch is removed without the flag

  test "remove deletes a Candidate holding a commit reachable from its admitted branch (after the Shaper fast-forwards it) without --discard-accepted",
       %{p: p, q: q} do
    _fixtures = scenario(p, q)

    candidate = new_worktree(p.control, "epsilon", "p5ff", p.commit)
    commit = commit_in_worktree(candidate, "epsilon change\n")
    candidate = write_owner!(candidate, "accepted-unpublished: branch main moved", commit)

    assert {:error, reason} = Workspace.remove(p.control, candidate.build_id)
    assert reason =~ "--discard-accepted"

    git!(p.control, ["merge", "--ff-only", commit])

    assert {:ok, lines} = Workspace.remove(p.control, candidate.build_id)
    assert Enum.any?(lines, &(&1 =~ "removed worktree"))
    refute File.exists?(candidate.path)
    refute branch_exists?(p.control, candidate.branch)
    refute File.exists?(candidate.owner_path)
  end

  test "remove deletes a Candidate marked published: cleanup refused once its commit is reachable, without --discard-accepted",
       %{p: p, q: q} do
    _fixtures = scenario(p, q)
    current = git!(p.control, ["rev-parse", "HEAD"])

    candidate = new_worktree(p.control, "zeta6", "p6published", current)
    commit = commit_in_worktree(candidate, "zeta change\n")
    git!(p.control, ["merge", "--ff-only", commit])
    candidate = write_owner!(candidate, "published: cleanup refused", commit)

    assert {:ok, lines} = Workspace.remove(p.control, candidate.build_id)
    assert Enum.any?(lines, &(&1 =~ "removed worktree"))
    refute File.exists?(candidate.path)
    refute branch_exists?(p.control, candidate.branch)
    refute File.exists?(candidate.owner_path)
  end

  # -- Then: remove refuses a build id belonging to another project ----------

  test "remove refuses an id that is not P's", %{p: p, q: q} do
    fixtures = scenario(p, q)
    q1 = fixtures.q1

    assert {:error, reason} = Workspace.remove(p.control, q1.build_id)
    assert reason =~ "refused"

    assert File.exists?(q1.path)
    assert File.exists?(q1.owner_path)
  end

  # -- Then: remove refuses a path that does not match its owner record -----

  test "remove refuses a Candidate whose owner record path does not match its actual worktree",
       %{p: p, q: q} do
    fixtures = scenario(p, q)

    candidate =
      new_worktree(p.control, "eta7", "p7tamper", p.commit) |> write_owner!("stopped: integrity")

    record = candidate.owner_path |> File.read!() |> Jason.decode!()
    tampered = Map.put(record, "worktree_path", fixtures.foreign_path)
    File.write!(candidate.owner_path, Jason.encode!(tampered, pretty: true))

    assert {:error, reason} = Workspace.remove(p.control, candidate.build_id)
    assert reason =~ "not under this project's workspace directory"

    assert File.exists?(fixtures.foreign_path)
    assert branch_exists?(p.control, "foreign")
  end

  # -- Then: remove refuses a path not registered in `git worktree list` ----

  test "remove refuses a Candidate whose worktree path is not registered in P's git worktree list",
       %{p: p, q: q} do
    _fixtures = scenario(p, q)

    candidate =
      new_worktree(p.control, "theta8", "p8unregistered", p.commit)
      |> write_owner!("stopped: integrity")

    git!(p.control, ["worktree", "remove", "--force", candidate.path])

    assert {:error, reason} = Workspace.remove(p.control, candidate.build_id)
    assert reason =~ "not registered"

    assert branch_exists?(p.control, candidate.branch)
    assert File.exists?(candidate.owner_path)
  end

  # -- Then: mix kogen.candidates.remove -------------------------------------

  test "mix kogen.candidates.remove deletes a stopped Candidate and prints what it removed",
       %{p: p, q: q} do
    _fixtures = scenario(p, q)

    candidate =
      new_worktree(p.control, "iota9", "p9mixremove", p.commit)
      |> write_owner!("stopped: integrity")

    output =
      capture_io(fn ->
        File.cd!(p.control, fn -> CandidatesRemove.run([candidate.build_id]) end)
      end)

    assert output =~ "removed worktree"
    assert output =~ "removed branch"
    assert output =~ "removed owner record"
    refute File.exists?(candidate.path)
    refute File.exists?(candidate.owner_path)
  end

  test "mix kogen.candidates.remove without --discard-accepted refuses an unreachable commit, and with it removes",
       %{p: p, q: q} do
    _fixtures = scenario(p, q)

    candidate = new_worktree(p.control, "kappa10", "p10mixremove", p.commit)
    commit = commit_in_worktree(candidate, "kappa change\n")
    candidate = write_owner!(candidate, "accepted-unpublished: branch main moved", commit)

    assert_raise Mix.Error, fn ->
      capture_io(fn ->
        File.cd!(p.control, fn -> CandidatesRemove.run([candidate.build_id]) end)
      end)
    end

    assert File.exists?(candidate.path)

    output =
      capture_io(fn ->
        File.cd!(p.control, fn ->
          CandidatesRemove.run([candidate.build_id, "--discard-accepted"])
        end)
      end)

    assert output =~ "removed worktree"
    refute File.exists?(candidate.path)
  end

  # -- Then: every survivor keeps its worktree, branch, harness home and owner record

  test "Q's Candidate is not listed by P and survives every removal made from P", %{p: p, q: q} do
    fixtures = scenario(p, q)
    q1 = fixtures.q1

    assert {:ok, _lines} = Workspace.remove(p.control, fixtures.p1.build_id)

    assert File.exists?(q1.path)
    assert File.exists?(q1.owner_path)

    q_worktrees = git!(q.control, ["worktree", "list", "--porcelain"])
    assert q_worktrees =~ q1.path
  end

  test "the running Candidate survives every remove attempt made against P", %{p: p, q: q} do
    fixtures = scenario(p, q)
    p3 = fixtures.p3

    assert {:error, _reason} = Workspace.remove(p.control, p3.build_id)
    assert {:error, _reason} = Workspace.remove(p.control, p3.build_id, discard_accepted: true)

    assert File.exists?(p3.path)
    assert branch_exists?(p.control, p3.branch)
    assert File.exists?(p3.owner_path)
  end

  test "the foreign worktree survives listing and every removal made from P", %{p: p, q: q} do
    fixtures = scenario(p, q)

    Workspace.remove(p.control, fixtures.p1.build_id)
    Workspace.remove(p.control, fixtures.p2.build_id, discard_accepted: true)

    assert File.exists?(fixtures.foreign_path)
    p_worktrees = git!(p.control, ["worktree", "list", "--porcelain"])
    assert p_worktrees =~ fixtures.foreign_path
    assert branch_exists?(p.control, "foreign")
  end

  test "the stale running record's Build is correctly detected as gone, distinct from a mismatched build id",
       %{p: p, q: q} do
    fixtures = scenario(p, q)

    # `p4` never held the current lock (it names `p3`): its effective status
    # is "stopped: interrupted" and it remains fully intact and removable.
    assert {:ok, record} =
             p.control
             |> Workspace.list()
             |> Enum.map(fn {:ok, record} -> record end)
             |> Enum.find(&(&1["build_id"] == fixtures.p4.build_id))
             |> then(&{:ok, &1})

    assert record["status"] == "stopped: interrupted"
    assert {:ok, _lines} = Workspace.remove(p.control, fixtures.p4.build_id)
    refute File.exists?(fixtures.p4.path)
  end

  # -- Fixture helpers --------------------------------------------------------

  defp control_repo(name) do
    control =
      Path.join(System.tmp_dir!(), "kogen-cand-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(control, "deps"))
    File.write!(Path.join(control, "deps/marker.txt"), "control deps\n")
    File.write!(Path.join(control, ".gitignore"), "/deps/\n/.kogen/\n")
    File.write!(Path.join(control, "README.md"), name <> "\n")

    git!(control, ["init", "-q", "-b", "main"])
    git!(control, ["add", "-A"])
    git!(control, ["commit", "-q", "-m", "fixture baseline"], @env)

    # `File.cwd!()` (what the mix tasks read after `File.cd!/2`) always
    # returns the OS-resolved, symlink-free path; a control path built from
    # `System.tmp_dir!()` may still carry macOS's `/var` -> `/private/var`
    # symlink, which would otherwise hash to a different project id than
    # `Workspace.project_dir/1` computes from the canonical path.
    control = canonicalize(control)
    commit = git!(control, ["rev-parse", "HEAD"])
    %{control: control, commit: commit, path: control}
  end

  defp canonicalize(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  defp new_worktree(control, slug, build_id, base) do
    branch = Workspace.branch(slug, build_id)

    # `Workspace.project_dir/1` only returns the canonical (realpath'd) form
    # once the directory exists on disk, exactly as `Workspace.create/2`
    # relies on: it `mkdir_p`s the raw path first, then canonicalizes. Doing
    # the same order here keeps every Candidate's stored path canonical, the
    # form `Workspace.remove/3` recomputes and compares against.
    File.mkdir_p!(Path.join(Workspace.root(), Workspace.project_id(control)))
    project = Workspace.project_dir(control)
    path = Path.join(project, "#{slug}-#{build_id}")
    harness_home = Path.join([project, "harness", build_id])

    git!(control, ["worktree", "add", "-b", branch, path, base])

    File.mkdir_p!(harness_home)
    File.write!(Path.join(harness_home, "marker.txt"), "harness\n")

    %{
      control: control,
      build_id: build_id,
      slug: slug,
      title: "Title for " <> build_id,
      branch: branch,
      path: path,
      harness_home: harness_home,
      owner_path: Workspace.owner_path(control, build_id),
      admitted_branch: "main",
      admitted_commit: base
    }
  end

  defp write_owner!(candidate, status, commit \\ nil) do
    record = %{
      "schema_version" => 1,
      "build_id" => candidate.build_id,
      "intent_id" => "intent-" <> candidate.build_id,
      "slug" => candidate.slug,
      "title" => candidate.title,
      "control_root" => candidate.control,
      "worktree_path" => candidate.path,
      "branch" => candidate.branch,
      "admitted_branch" => candidate.admitted_branch,
      "admitted_commit" => candidate.admitted_commit,
      "harness_home" => candidate.harness_home,
      "credential_bindings" => [],
      "started_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "status" => status,
      "candidate_commit" => commit
    }

    File.mkdir_p!(Path.dirname(candidate.owner_path))
    File.write!(candidate.owner_path, Jason.encode_to_iodata!(record, pretty: true))
    candidate
  end

  defp commit_in_worktree(candidate, contents) do
    File.write!(Path.join(candidate.path, "change.txt"), contents)
    git!(candidate.path, ["add", "-A"])
    git!(candidate.path, ["commit", "-q", "-m", "candidate change"], @env)
    git!(candidate.path, ["rev-parse", "HEAD"])
  end

  defp write_lock(control, build_id, pid) do
    lock = Workspace.lock_path(control)
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, Jason.encode!(%{"pid" => pid, "build_id" => build_id}))
  end

  defp live_pid, do: System.pid() |> String.to_integer()

  # A pid `kill -0` will never find live: `System.cmd/3` only returns once the
  # child has already exited, so the pid it printed is guaranteed dead.
  defp dead_pid do
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    String.to_integer(String.trim(out))
  end

  defp branch_exists?(control, branch) do
    match?(
      {_, 0},
      System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch], cd: control)
    )
  end

  defp git!(dir, args, env \\ []) do
    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> flunk("git #{inspect(args)} failed (#{status}): #{out}")
    end
  end
end
