defmodule Kogen.BuildWorkspaceTest do
  @moduledoc """
  Candidate worktrees and harness homes: admission, routing, publication,
  refusal, retention, Shaping during a Build and retained record sidecars,
  with real Git fixtures and fake roles that record the OS process state
  they see from inside the launched process.
  """
  use Kogen.IsolatedCase, async: true

  Code.require_file("../support/live_tracking_retention.ex", __DIR__)

  alias Kogen.Build.{Evidence, Workspace}
  alias Kogen.CandidateFixture, as: Candidate
  alias Kogen.WorkspaceFixture, as: Fixture

  @slug Fixture.slug()

  # A fake role that records what it sees at its first launch, from inside
  # the launched process, then fails like a provider: the Build stops and
  # keeps its Candidate exactly as the role found it.
  @probe_role """
  #!/bin/sh
  set -u
  cat >/dev/null
  out="$KOGEN_HARNESS_HOME/probe"
  mkdir -p "$out"
  pwd -P >"$out/pwd"
  git rev-parse --show-toplevel >"$out/toplevel"
  for p in .kogen/build.lock .kogen/runtime .kogen/codex .codex/sessions _build deps/fixture_dep/mix.exs; do
    if [ -e "$p" ]; then echo "$p" >>"$out/present"; fi
  done
  : >>"$out/present"
  exit 1
  """

  setup do
    if Fixture.isolated_child?() do
      control = Fixture.create!()
      on_exit(fn -> File.rm_rf(control) end)
      %{control: control}
    else
      # The parent only dispatches; the pattern keys must still exist.
      %{control: nil}
    end
  end

  describe "candidate-creation" do
    setup context do
      if Fixture.isolated_child?(),
        do: admit_probe(context.control),
        else: Map.new(~w(result foreign home before head record)a, &{&1, nil})
    end

    defp admit_probe(control) do
      # An unrelated linked worktree created by plain git, plus control
      # volatile state that must never reach a Candidate.
      foreign = Path.join(control, ".kogen/runtime/build-worktrees/checkouts/foreign")
      File.mkdir_p!(Path.dirname(foreign))
      Fixture.git!(control, ["worktree", "add", "-q", "-b", "foreign-branch", foreign])
      File.mkdir_p!(Path.join(control, ".kogen/codex"))
      File.write!(Path.join(control, ".kogen/codex/state"), "control codex state\n")
      File.mkdir_p!(Path.join(control, ".codex/sessions"))
      File.write!(Path.join(control, ".codex/sessions/rollout"), "control session\n")
      File.write!(Path.join(control, ".kogen/runtime/control-only"), "control runtime\n")

      tools = Fixture.tmp_dir!("probe-role")
      role = Fixture.fake!(tools, "probe_role", @probe_role)

      # The real Kogen directory stands in as a sentinel under a disposable
      # HOME: with KOGEN_WORKSPACES_ROOT set, nothing may appear there.
      home = Fixture.tmp_dir!("sentinel-home")
      before = Fixture.control_state(control)
      head = Fixture.git!(control, ["rev-parse", "HEAD"])

      result =
        Fixture.build!(control,
          harness: role,
          env: [
            {"HOME", home},
            {"KOGEN_WORKSPACES_ROOT", System.get_env("KOGEN_WORKSPACES_ROOT")}
          ]
        )

      %{
        result: result,
        foreign: foreign,
        home: home,
        before: before,
        head: head,
        record: Candidate.record(control)
      }
    end

    test "one new linked worktree at <root>/<project-id>/<slug>-<build-id>/ on kogen/<slug>/<build-id> at A",
         %{control: control, record: record, head: head, foreign: foreign} do
      build_id = record_id(control)
      block = record["candidate"]
      root = System.fetch_env!("KOGEN_WORKSPACES_ROOT")
      assert root =~ " ", "the workspaces root must contain a space"
      project_id = Kogen.ClaudeCode.project_id(control)
      assert project_id == Workspace.project_id(control)

      expected = Path.join([Workspace.canonical(root), project_id, "#{@slug}-#{build_id}"])
      assert block["worktree_path"] == expected
      assert block["branch"] == "kogen/#{@slug}/#{build_id}"
      assert Fixture.git!(control, ["rev-parse", "refs/heads/kogen/#{@slug}/#{build_id}"]) == head
      assert Fixture.git!(expected, ["rev-parse", "HEAD"]) == head

      registered = Candidate.registered_worktrees(control)
      assert Enum.sort(registered) == Enum.sort([control, Workspace.canonical(foreign), expected])

      refute String.starts_with?(expected, control <> "/"),
             "the Candidate must not nest in control"
    end

    test "the harness home exists outside the Candidate and outside control", %{
      control: control,
      record: record
    } do
      home = record["candidate"]["harness_home"]
      assert home == Workspace.harness_home(control, record_id(control))
      assert File.dir?(home)
      refute String.starts_with?(home, record["candidate"]["worktree_path"] <> "/")
      refute String.starts_with?(home, control <> "/")
    end

    test "the owner record names worktree, branch, admitted commit, control root, home and bindings",
         %{control: control, record: record, head: head} do
      block = record["candidate"]
      [owner] = Fixture.owner_records(control)
      assert owner["build_id"] == record_id(control)
      assert owner["worktree_path"] == block["worktree_path"]
      assert owner["branch"] == block["branch"]
      assert owner["admitted_branch"] == "main"
      assert owner["admitted_commit"] == head
      assert owner["control_root"] == control
      assert owner["harness_home"] == block["harness_home"]
      assert [%{"harness" => "codex", "runtime_version" => "test"}] = owner["credential_bindings"]
      assert owner["slug"] == @slug
      assert owner["intent_id"] == Fixture.intent_id()
      assert is_binary(owner["started_at"])
    end

    test "the owner record status is running before any provider launch and stopped afterwards",
         %{control: control, result: result} do
      # The probe role is the first provider launch; it failed, so the
      # Build stopped and marked the record at exit.
      assert {:error, reason} = result
      assert reason =~ "harness failure during Developer turn"
      [owner] = Fixture.owner_records(control)
      assert owner["status"] == "stopped: provider-failure"
      assert Candidate.record(control)["candidate"]["disposition"] == "retained"
    end

    test "the Candidate has a plain deps/ copy, no _build/, and the Approved bytes in its ignored copy",
         %{control: control, record: record} do
      worktree = record["candidate"]["worktree_path"]

      assert File.read!(Path.join(worktree, "deps/fixture_dep/mix.exs")) ==
               File.read!(Path.join(control, "deps/fixture_dep/mix.exs"))

      assert {:ok, %{type: :regular, links: 1}} =
               File.lstat(Path.join(worktree, "deps/fixture_dep/mix.exs"))

      refute File.exists?(Path.join(worktree, "_build"))

      for name <- ["intent.yaml", "scenarios.yaml"] do
        assert File.read!(Path.join([worktree, ".kogen/intents/approved", @slug, name])) ==
                 File.read!(Path.join([control, ".kogen/intents/approved", @slug, name]))
      end

      assert Fixture.git!(worktree, ["check-ignore", ".kogen/intents/approved/#{@slug}"]) != ""
    end

    test "the Candidate receives none of control's volatile state while control holds the lock",
         %{control: control, record: record} do
      probe = Path.join(record["candidate"]["harness_home"], "probe")
      present = probe |> Path.join("present") |> File.read!() |> String.split("\n", trim: true)

      # At the first launch the Candidate held its deps copy and nothing of
      # control's volatile state, although control held its build lock.
      assert present == ["deps/fixture_dep/mix.exs"]

      assert File.read!(Path.join(probe, "pwd")) |> String.trim() ==
               record["candidate"]["worktree_path"]

      refute File.exists?(Path.join(record["candidate"]["worktree_path"], ".kogen/codex"))
      refute File.exists?(Path.join(record["candidate"]["worktree_path"], ".codex/sessions"))
      assert File.exists?(Path.join(control, ".kogen/runtime/control-only"))
    end

    test "control's HEAD, index, tracked bytes and git status --porcelain are unchanged",
         %{control: control, before: before} do
      assert Fixture.control_state(control) == before
    end

    test "the foreign worktree is untouched", %{control: control, foreign: foreign} do
      assert File.dir?(foreign)
      assert Fixture.git!(foreign, ["symbolic-ref", "--short", "HEAD"]) == "foreign-branch"
      assert Workspace.canonical(foreign) in Candidate.registered_worktrees(control)
    end

    test "a sentinel real Kogen root stays empty", %{home: home} do
      refute File.exists?(Path.join(home, "Library/Application Support/Kogen"))
      assert File.ls!(home) == []
    end
  end

  describe "candidate-creation binding order" do
    # A fake Claude Code whose readiness step (`auth status`) snapshots the
    # owner record at the moment it starts, from inside the launched process,
    # then reports a login; its model launch fails like a provider.
    @readiness_role """
    #!/bin/sh
    set -u
    if [ "$*" = "auth status" ]; then
      project="$(dirname "$(dirname "$KOGEN_HARNESS_HOME")")"
      owner="$project/candidates/$(basename "$KOGEN_HARNESS_HOME").json"
      cp "$owner" "$KOGEN_HARNESS_HOME/owner-at-readiness.json"
      printf '{"loggedIn": true, "authMethod": "claude.ai"}\\n'
      exit 0
    fi
    cat >/dev/null
    exit 1
    """

    @claude_route """
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

    test "the owner record names nonempty credential bindings when readiness starts",
         %{control: control} do
      File.write!(Path.join(control, ".kogen/config.yaml"), @claude_route)
      Fixture.git!(control, ["add", "-A"])
      Fixture.git!(control, ["commit", "-q", "-m", "use the claude route"])

      base = Fixture.tmp_dir!("binding-order")
      claude_root = Path.join(base, "claude-root")
      scope = Path.join(claude_root, "accounts/shared")
      File.mkdir_p!(scope)
      role = Fixture.fake!(base, "readiness_role", @readiness_role)

      assert {:error, reason} =
               Fixture.build!(control,
                 harness: role,
                 env: [{"KOGEN_CLAUDE_ROOT", claude_root}]
               )

      assert reason =~ "harness failure during Developer turn"

      home = Candidate.record(control)["candidate"]["harness_home"]
      snapshot = Path.join(home, "owner-at-readiness.json")
      assert File.regular?(snapshot), "readiness never ran, or could not read the owner record"
      at_readiness = snapshot |> File.read!() |> Jason.decode!()

      assert at_readiness["status"] == "running"

      assert [%{"harness" => "claude", "scope_name" => "shared"} = binding] =
               at_readiness["credential_bindings"]

      assert binding["scope_path"] == Path.expand(scope)
      assert binding["runtime_version"] == "test"
    end
  end

  describe "candidate-creation refusals" do
    test "a missing control deps/ stops before any launch naming mix deps.get, never in control",
         %{control: control} do
      File.rm_rf!(Path.join(control, "deps"))
      before = Fixture.control_state(control)
      assert {:error, reason} = Fixture.build!(control)
      assert reason =~ "control deps/ is missing"
      assert reason =~ "mix deps.get"
      assert Fixture.owner_records(control) == []
      assert Candidate.registered_worktrees(control) == [control]

      refute File.exists?(
               Path.join(Fixture.project_dir(control), "harness/#{record_id(control)}")
             )

      assert Fixture.control_state(control) == before
      refute File.exists?(Path.join(control, "dummy.txt.fake")), "no role ran in control"
    end

    test "a pre-existing Candidate path is refused and never reused",
         %{control: control} do
      {admission, build_id} = admission(control, "existing-path")
      path = Path.join(Fixture.project_dir(control), "#{@slug}-#{build_id}")
      File.mkdir_p!(path)
      File.write!(Path.join(path, "foreign"), "keep\n")

      assert {:error, reason} = Workspace.create(admission, [])
      assert reason =~ "Candidate worktree path already exists and is never reused"
      assert File.read!(Path.join(path, "foreign")) == "keep\n"
      refute File.exists?(Workspace.owner_path(control, build_id))
      refute File.exists?(Workspace.harness_home(control, build_id))
    end

    test "a pre-existing Candidate branch is refused and never reused", %{control: control} do
      {admission, build_id} = admission(control, "existing-branch")
      Fixture.git!(control, ["branch", "kogen/#{@slug}/#{build_id}"])

      assert {:error, reason} = Workspace.create(admission, [])
      assert reason =~ "Candidate branch already exists and is never reused"
      refute File.exists?(Workspace.owner_path(control, build_id))
      assert Candidate.registered_worktrees(control) == [control]
    end

    test "a pre-existing owner record is refused and never reused", %{control: control} do
      {admission, build_id} = admission(control, "existing-owner")
      owner = Workspace.owner_path(control, build_id)
      File.mkdir_p!(Path.dirname(owner))
      File.write!(owner, "foreign owner\n")

      assert {:error, reason} = Workspace.create(admission, [])
      assert reason =~ "Candidate owner record already exists and is never reused"
      assert File.read!(owner) == "foreign owner\n"
      refute File.exists?(Workspace.harness_home(control, build_id))
    end

    test "a failed git worktree add removes only what this admission created", %{control: control} do
      {admission, build_id} = admission(control, "failed-add")
      admission = %{admission | commit: String.duplicate("0", 40)}

      assert {:error, reason} = Workspace.create(admission, [])
      assert reason =~ "git worktree add failed"
      refute File.exists?(Workspace.owner_path(control, build_id))
      refute File.exists?(Workspace.harness_home(control, build_id))
      refute File.exists?(Path.join(Fixture.project_dir(control), "#{@slug}-#{build_id}"))
      assert Candidate.registered_worktrees(control) == [control]

      refute match?(
               {_, 0},
               Fixture.git(control, [
                 "show-ref",
                 "--verify",
                 "refs/heads/kogen/#{@slug}/#{build_id}"
               ])
             )
    end
  end

  describe "publication-unmoved-main" do
    test "one commit on A is fast-forwarded onto B with control synchronized and clean",
         %{control: control} do
      Fixture.write_intent!(control, @slug, guards: ["dummy.txt", "reviewer-rework-marker.txt"])
      head = Fixture.git!(control, ["rev-parse", "HEAD"])
      before = Candidate.registered_worktrees(control)

      assert :ok =
               Fixture.build!(control,
                 harness: Fixture.support("fake_codex"),
                 env: [{"FAKE_CHECK_FAIL", "0"}]
               )

      assert Fixture.git!(control, ["rev-parse", "HEAD^"]) == head
      assert Fixture.git!(control, ["log", "-1", "--format=%s"]) == "Workspace fixture #{@slug}"
      assert Fixture.git!(control, ["status", "--porcelain"]) == ""

      assert Fixture.git!(control, ["rev-parse", "HEAD^{tree}"]) ==
               Fixture.git!(control, ["write-tree"])

      assert File.read!(Path.join(control, "dummy.txt")) == "reviewed fixture value\n"
      assert File.exists?(Path.join(control, ".kogen/intents/complete/#{@slug}/intent.yaml"))
      assert Candidate.registered_worktrees(control) == before
    end

    test "control's Approved copy, worktree, branch and owner record are removed; the harness home is kept",
         %{control: control} do
      assert :ok = Fixture.build!(control)
      block = Candidate.candidate(control)
      refute File.exists?(Path.join(control, ".kogen/intents/approved/#{@slug}"))
      refute File.exists?(block["worktree_path"])

      refute match?(
               {_, 0},
               Fixture.git(control, ["show-ref", "--verify", "refs/heads/" <> block["branch"]])
             )

      assert Fixture.owner_records(control) == []
      assert File.dir?(block["harness_home"])
      assert Candidate.receipts(control) != [], "the harness home keeps the session evidence"
      assert block["disposition"] == "published"
    end

    test "build-summary.json and evidence.md resolve the full record from control", %{
      control: control
    } do
      assert :ok = Fixture.build!(control)
      complete = Path.join(control, ".kogen/intents/complete/#{@slug}")
      summary = Path.join(complete, "build-summary.json")
      full = summary |> File.read!() |> Jason.decode!() |> Map.fetch!("full_record")
      refute Path.type(full["path"]) == :absolute
      assert File.exists?(Path.join(control, full["path"]))

      assert {:ok, record} =
               File.cd!(Fixture.tmp_dir!("resolve-cwd"), fn ->
                 Evidence.resolve(summary, control)
               end)

      assert record["candidate"]["disposition"] == "published"
      assert File.read!(Path.join(complete, "evidence.md")) =~ "`#{full["path"]}`"
    end

    test "no merge commit, rebase or re-verification happens", %{control: control} do
      assert :ok = Fixture.build!(control)
      assert Fixture.git!(control, ["rev-list", "--merges", "HEAD"]) == ""
      assert Fixture.git!(control, ["rev-list", "--count", "HEAD"]) == "2"
      [attempt] = Candidate.record(control)["attempts"]
      assert length(attempt["verification"]["cycles"]) == 1
    end

    # A refused worktree removal after the fast-forward keeps B published, the
    # Candidate retained, and exits zero with a warning; the remove command
    # then removes it without --discard-accepted.
    test "refused cleanup after the fast-forward is published-retained and removable without the flag",
         %{control: control} do
      # An ordinary commit hook leaves an untracked file in the Candidate
      # after the commit, so `git worktree remove` (never --force) refuses.
      hook = Path.join(control, ".git/hooks/post-commit")
      File.write!(hook, "#!/bin/sh\necho stray > \"$(pwd)/untracked-after-commit.txt\"\n")
      File.chmod!(hook, 0o755)
      head = Fixture.git!(control, ["rev-parse", "HEAD"])

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn -> assert :ok = Fixture.build!(control) end)

      block = Candidate.candidate(control)
      published = Fixture.git!(control, ["rev-parse", "HEAD"])
      assert Fixture.git!(control, ["rev-parse", "HEAD^"]) == head
      assert warning =~ block["worktree_path"]
      assert warning =~ "mix kogen.candidates.remove #{record_id(control)}"
      assert block["disposition"] == "published-retained"
      assert block["candidate_commit"] == published
      [owner] = Fixture.owner_records(control)
      assert owner["status"] =~ "published: cleanup refused: "
      assert File.dir?(block["worktree_path"])
      File.rm!(hook)

      assert {:ok, lines} = Workspace.remove(control, record_id(control))
      assert "removed worktree #{block["worktree_path"]}" in lines
      refute File.exists?(block["worktree_path"])
      assert Fixture.git!(control, ["rev-parse", "HEAD"]) == published
    end
  end

  describe "publication-refused" do
    for {cause, script, expected} <- [
          {"B moved",
           ~S"""
           cd "$FIXTURE_CONTROL" && git commit -q --allow-empty -m moved
           """, "branch main moved from"},
          {"control is dirty",
           ~S"""
           echo dirty >> "$FIXTURE_CONTROL/README.md"
           """, "control checkout is not clean"},
          {"control is on another branch",
           ~S"""
           git -C "$FIXTURE_CONTROL" checkout -q -b elsewhere
           """, "control checkout is on branch elsewhere, not main"}
        ] do
      # B, control's index, tree and Approved package stay unchanged; the
      # Candidate is retained with the accepted commit.
      test "publication refuses when #{cause}, retaining the accepted Candidate",
           %{control: control} do
        # Fault injection between the Candidate commit and the fast-forward:
        # an ordinary commit hook changes control once.
        hook = Path.join(control, ".git/hooks/post-commit")

        File.write!(hook, """
        #!/bin/sh
        [ -n "${FIXTURE_HOOK_DONE:-}" ] && exit 0
        export FIXTURE_HOOK_DONE=1
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
        #{unquote(script)}
        """)

        File.chmod!(hook, 0o755)
        approved = File.read!(Path.join(control, ".kogen/intents/approved/#{@slug}/intent.yaml"))

        assert {:error, reason} =
                 Fixture.build!(control, env: [{"FIXTURE_CONTROL", control}])

        File.rm!(hook)
        block = Candidate.candidate(control)
        build_id = record_id(control)
        commit = block["candidate_commit"]
        assert reason =~ unquote(expected)
        assert reason =~ "Admitted main at #{block["admitted_commit"]}"
        assert reason =~ block["worktree_path"]
        assert reason =~ block["branch"]
        assert reason =~ "Candidate commit #{commit}"
        assert reason =~ "tracking record: "
        assert reason =~ "mix kogen.candidates.remove #{build_id} --discard-accepted"
        assert block["disposition"] == "retained"
        [owner] = Fixture.owner_records(control)
        assert owner["status"] == "accepted-unpublished: " <> refusal_reason(reason)
        assert owner["candidate_commit"] == commit
        assert Fixture.git!(control, ["rev-parse", block["branch"]]) == commit
        assert File.dir?(block["worktree_path"])
        assert File.dir?(block["harness_home"])

        assert File.read!(Path.join(control, ".kogen/intents/approved/#{@slug}/intent.yaml")) ==
                 approved

        refute Fixture.git!(control, ["rev-parse", "main"]) == commit
      end
    end
  end

  describe "shaping-during-build" do
    setup do
      if Fixture.isolated_child?(),
        do: shaping_fixture(),
        else: %{shaping_control: nil, role: nil, claude_root: nil}
    end

    defp shaping_fixture do
      control = Fixture.create!(route: :claude)
      tools = Fixture.tmp_dir!("waiting-role")
      claude_root = Fixture.claude_root!()
      on_exit(fn -> File.rm_rf(control) end)

      # Other packages that a Shaping session owns in control's ignored tree.
      other = Path.join(control, ".kogen/intents/drafts/other-draft")
      File.mkdir_p!(other)
      File.write!(Path.join(other, "intent.yaml"), "id: other\n")
      moving = Path.join(control, ".kogen/intents/drafts/moving-package")
      File.mkdir_p!(moving)
      File.write!(Path.join(moving, "intent.yaml"), "id: moving\n")

      %{
        shaping_control: control,
        role: Fixture.waiting_role!(tools, Fixture.support("fake_claude")),
        claude_root: claude_root
      }
    end

    test "Drafts, other packages, approvals and the shared login used in control mid-Build never reach the Build, which is accepted and published",
         %{shaping_control: control, role: role, claude_root: claude_root} do
      scope = Path.join(claude_root, "accounts/shared")

      task =
        Task.async(fn ->
          Fixture.build!(control, harness: role, env: [{"KOGEN_CLAUDE_ROOT", claude_root}])
        end)

      home = Fixture.await_waiting!(control)
      File.mkdir_p!(Path.join(control, ".kogen/intents/drafts/new-draft"))
      File.write!(Path.join(control, ".kogen/intents/drafts/new-draft/intent.yaml"), "id: new\n")

      File.write!(
        Path.join(control, ".kogen/intents/drafts/other-draft/intent.yaml"),
        "id: edited\n"
      )

      File.rename!(
        Path.join(control, ".kogen/intents/drafts/moving-package"),
        Path.join(control, ".kogen/intents/approved/moving-package")
      )

      # A scope-native Shape-side launch uses the same login meanwhile.
      runtime = %{"executable" => Fixture.support("fake_claude"), "version" => "test"}

      assert {:configured, _} =
               Kogen.ClaudeCode.login_status(runtime, %{name: :shared, path: scope})

      File.write!(Path.join(home, "go"), "")
      assert :ok = Task.await(task, 180_000)

      record = Candidate.record(control)
      paths = changed_paths(record)
      refute Enum.any?(paths, &String.starts_with?(&1, ".kogen/intents/"))
      assert "dummy.txt" in paths
      assert File.read!(Path.join(control, "dummy.txt")) == "initial fixture value\n"

      assert File.read!(Path.join(control, ".kogen/intents/drafts/new-draft/intent.yaml")) ==
               "id: new\n"

      assert File.read!(Path.join(control, ".kogen/intents/drafts/other-draft/intent.yaml")) ==
               "id: edited\n"

      assert File.read!(Path.join(control, ".kogen/intents/approved/moving-package/intent.yaml")) ==
               "id: moving\n"

      refute File.exists?(Path.join(control, ".kogen/intents/approved/#{@slug}"))
      assert Fixture.git!(control, ["status", "--porcelain"]) == ""

      for receipt <- Candidate.receipts(control) do
        assert receipt["env"]["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == scope
      end
    end

    test "an edit to the Build's own Approved copy inside the Candidate still fails the Build as an approved mutation",
         %{shaping_control: control, role: role, claude_root: claude_root} do
      edit = "printf 'mutated\\n' >> .kogen/intents/approved/#{@slug}/intent.yaml"

      task =
        Task.async(fn ->
          Fixture.build!(control,
            harness: role,
            env: [{"KOGEN_CLAUDE_ROOT", claude_root}, {"FIXTURE_DEV_EDIT", edit}]
          )
        end)

      home = Fixture.await_waiting!(control)
      File.write!(Path.join(home, "go"), "")
      assert {:error, reason} = Task.await(task, 180_000)
      assert reason =~ "Approved Intent changed during Build"
      assert reason =~ "Candidate kept"
      block = Candidate.candidate(control)
      assert block["disposition"] == "retained"

      assert File.read!(
               Path.join([
                 block["worktree_path"],
                 ".kogen/intents/approved",
                 @slug,
                 "intent.yaml"
               ])
             ) =~
               "mutated"

      refute File.read!(Path.join(control, ".kogen/intents/approved/#{@slug}/intent.yaml")) =~
               "mutated"
    end

    test "a tracked-file edit in control during the Build makes publication refuse with the Candidate retained",
         %{shaping_control: control, role: role, claude_root: claude_root} do
      task =
        Task.async(fn ->
          Fixture.build!(control, harness: role, env: [{"KOGEN_CLAUDE_ROOT", claude_root}])
        end)

      home = Fixture.await_waiting!(control)
      File.write!(Path.join(control, "README.md"), "edited in control during the Build\n")
      File.write!(Path.join(home, "go"), "")
      assert {:error, reason} = Task.await(task, 180_000)
      assert reason =~ "control checkout is not clean"
      block = Candidate.candidate(control)
      assert block["disposition"] == "retained"
      assert File.dir?(block["worktree_path"])
      assert Fixture.git!(control, ["rev-parse", "main"]) == block["admitted_commit"]
    end
  end

  describe "failure-retention" do
    for {category, status, opts} <- [
          {"verification exhaustion", "stopped: verification-exhausted",
           harness: "fake_codex", env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]},
          {"outer-allowance exhaustion", "stopped: outer-allowance-exhausted",
           harness: "fake_codex_always_rework", env: []},
          {"a Jev cannot-comply stop", "stopped: cannot-comply",
           harness: "fake_codex_simple_accept",
           env: [
             {"FAKE_JEV_ANSWERS",
              ~s({"objection:scenario:fixture-scenario": ["objection", 0.99]})}
           ]},
          {"an integrity failure", "stopped: integrity",
           harness: "fake_codex", env: [], guards: ["unrelated.txt"]},
          {"a provider failure", "stopped: provider-failure", harness: :failing, env: []},
          {"a malformed Review", "stopped: review-failure", harness: :malformed, env: []}
        ] do
      test "a Build stopped by #{category} keeps its Candidate, names it and is never reused by the next Build",
           %{control: control} do
        opts = unquote(Macro.escape(opts))
        if guards = opts[:guards], do: Fixture.write_intent!(control, @slug, guards: guards)
        before = Fixture.control_state(control)
        harness = retention_harness(opts[:harness])

        assert {:error, reason} = Fixture.build!(control, harness: harness, env: opts[:env])

        first = Candidate.candidate(control)
        build_id = record_id(control)
        assert reason =~ "slug #{@slug}, build id #{build_id}"
        assert reason =~ "worktree #{first["worktree_path"]}"
        assert reason =~ "branch #{first["branch"]}"
        assert reason =~ "tracking record: "
        assert reason =~ "mix kogen.candidates.remove #{build_id}"
        assert first["disposition"] == "retained"
        [owner] = Fixture.owner_records(control)
        assert owner["status"] == unquote(status)
        assert File.dir?(first["worktree_path"])
        assert File.dir?(first["harness_home"])
        assert Fixture.control_state(control) == before
        assert File.dir?(Path.join(control, ".kogen/intents/approved/#{@slug}"))
        snapshot = tree_snapshot(first)

        # The next Build of the same Intent gets its own Candidate and home.
        assert {:error, _} = Fixture.build!(control, harness: harness, env: opts[:env])

        [second] =
          control
          |> Candidate.records()
          |> Enum.map(& &1["candidate"])
          |> Enum.reject(&(&1["worktree_path"] == first["worktree_path"]))

        refute second["worktree_path"] == first["worktree_path"]
        refute second["harness_home"] == first["harness_home"]
        assert tree_snapshot(first) == snapshot
        assert length(Fixture.owner_records(control)) == 2
      end
    end
  end

  describe "candidate-routing" do
    test "a Build run from a third directory works in the Candidate and never in that directory or control",
         %{control: control} do
      third = Fixture.tmp_dir!("third-sentinel")
      File.write!(Path.join(third, "third-sentinel.txt"), "third\n")
      File.mkdir_p!(Path.join(control, ".kogen/runtime"))

      File.write!(
        Path.join(control, ".kogen/runtime/control-only-edit"),
        "ignored control edit\n"
      )

      assert :ok = Fixture.build!(control, cwd: third)
      block = Candidate.candidate(control)

      for receipt <- Candidate.receipts(control) do
        assert receipt["pwd"] == block["worktree_path"]
        assert receipt["toplevel"] == block["worktree_path"]
      end

      assert File.ls!(third) == ["third-sentinel.txt"]
      refute "third-sentinel.txt" in changed_paths(Candidate.record(control))
      refute ".kogen/runtime/control-only-edit" in changed_paths(Candidate.record(control))
    end

    test "Build.run refuses an absent, non-checkout or linked-worktree control root before admission",
         %{control: control} do
      assert {:error, reason} = Kogen.Build.run(@slug, nil, Path.join(control, "absent"))
      assert reason =~ "not a Git checkout root"

      plain = Fixture.tmp_dir!("not-a-checkout")
      assert {:error, reason} = Kogen.Build.run(@slug, nil, plain)
      assert reason =~ "not a Git checkout root"

      linked = Path.join(Fixture.tmp_dir!("linked-parent"), "linked")
      Fixture.git!(control, ["worktree", "add", "-q", "-b", "linked-control", linked])
      assert {:error, reason} = Kogen.Build.run(@slug, nil, linked)
      assert reason =~ "must be a main worktree"
      assert Fixture.owner_records(control) == []
    end

    test "a change to control's .git/config during the Build stops it before verification",
         %{control: control} do
      tools = Fixture.tmp_dir!("config-edit")
      role = Fixture.waiting_role!(tools, Fixture.support("fake_codex_simple_accept"))
      task = Task.async(fn -> Fixture.build!(control, harness: role) end)
      home = Fixture.await_waiting!(control)
      Fixture.git!(control, ["config", "kogen.fixture", "changed"])
      File.write!(Path.join(home, "go"), "")
      assert {:error, reason} = Task.await(task, 180_000)
      assert reason =~ "Git configuration or ignore policy changed"

      assert Candidate.record(control)["attempts"] |> List.last() |> Map.get("verification") ==
               nil
    end
  end

  describe "shape-to-build-retains-record-sidecars" do
    test "a published Build that cited its own record resolves from retained evidence after the fixture and Candidate are gone, and a missing or altered sidecar fails",
         %{control: control} do
      tools = Fixture.tmp_dir!("citing-reviewer")
      role = Fixture.fake!(tools, "citing_reviewer", citing_reviewer())
      assert :ok = Fixture.build!(control, harness: role)

      record = Candidate.record(control)
      [attempt] = record["attempts"]

      snapshots =
        Map.values(attempt["reference_snapshots"] || %{}) ++
          Map.values(attempt["reviewer_reference_snapshots"] || %{})

      sidecar = Enum.find_value(snapshots, & &1["sidecar"])

      assert sidecar =~
               ~r"^\.kogen/runtime/scenario-tracking/[^/]+/record-versions/[0-9a-f]{64}\.json$"

      assert File.regular?(Path.join(control, sidecar))
      refute File.exists?(Candidate.worktree(control))
      refute File.exists?(Path.join(Candidate.harness_home(control), ".kogen"))

      packet = attempt["review_packet"]["path"]
      assert packet =~ ~r{^\.kogen/runtime/scenario-tracking/[^/]+/review-packets/0\.json$}

      logs = Fixture.tmp_dir!("retained-logs")
      complete = Path.join(control, ".kogen/intents/complete/#{@slug}")
      Kogen.LiveTrackingRetention.preserve!(control, complete, logs)
      File.rm_rf!(control)

      summary = Path.join(logs, "build-summary.json")
      assert {:ok, _record} = Evidence.resolve(summary, logs)

      [retained] = Path.wildcard(Path.join(logs, "scenario-tracking/*/record-versions/*.json"))
      bytes = File.read!(retained)
      File.write!(retained, bytes <> " ")
      assert {:error, reason} = Evidence.resolve(summary, logs)
      assert reason =~ "sidecar"
      File.rm!(retained)
      assert {:error, reason} = Evidence.resolve(summary, logs)
      assert reason =~ "sidecar unavailable"
    end
  end

  defp citing_reviewer do
    """
    #!/bin/sh
    set -eu
    if [ "${KOGEN_ROLE:-}" = reviewer ]; then
      input="$(cat)"
      printf '%s' "$input" | python3 #{inspect(Fixture.support("launch_receipt.py"))} "$@"
      out=; prev=
      for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
      tracking="$(printf '%s' "$input" | python3 -c 'import json,sys; lines=sys.stdin.read().splitlines(); i=max(i for i,v in enumerate(lines) if v=="KOGEN_TASK_CONTEXT"); print(json.loads(lines[i+1])["tracking_path"])')"
      printf '%s' "$input" | python3 #{inspect(Fixture.support("scenario_response.py"))} reviewer accept |
        python3 -c 'import json,sys; v=json.load(sys.stdin); ev=[{"path":sys.argv[1],"locator":"the Build own tracking record"}]; v["scenarios"][0]["evidence"]=ev; print(json.dumps(v))' "$tracking" >"$out"
      printf '{"type":"thread.started","thread_id":"citing-reviewer"}\\n{"type":"turn.completed","thread_id":"citing-reviewer"}\\n'
      exit 0
    fi
    exec #{inspect(Fixture.support("fake_codex_simple_accept"))} "$@"
    """
  end

  defp retention_harness(:failing) do
    Fixture.fake!(
      Fixture.tmp_dir!("failing-role"),
      "failing_role",
      "#!/bin/sh\ncat >/dev/null\nexit 3\n"
    )
  end

  defp retention_harness(:malformed) do
    Fixture.fake!(Fixture.tmp_dir!("malformed-reviewer"), "malformed_reviewer", """
    #!/bin/sh
    if [ "${KOGEN_ROLE:-}" = reviewer ]; then
      cat >/dev/null
      out=; prev=
      for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
      printf 'not a verdict' >"$out"
      printf '{"type":"thread.started","thread_id":"malformed"}\\n{"type":"turn.completed","thread_id":"malformed"}\\n'
      exit 0
    fi
    exec #{inspect(Fixture.support("fake_codex_simple_accept"))} "$@"
    """)
  end

  defp retention_harness(name), do: Fixture.support(name)

  # Every file's path and bytes under a kept Candidate and its harness home,
  # plus the branch tip.
  defp tree_snapshot(block) do
    files =
      for root <- [block["worktree_path"], block["harness_home"]],
          path <- Path.wildcard(Path.join(root, "**"), match_dot: true),
          not String.contains?(path, "/.git/"),
          File.regular?(path),
          into: %{},
          do: {path, File.read!(path)}

    {files, Fixture.git!(block["control_root"], ["rev-parse", block["branch"]])}
  end

  # Every path each settled Candidate id changed relative to the admitted
  # commit (the object store is shared), plus the report's changed paths.
  defp changed_paths(record) do
    block = record["candidate"]

    record["attempts"]
    |> Enum.flat_map(fn attempt ->
      tree =
        case attempt["candidate_id"] do
          nil ->
            []

          id ->
            block["control_root"]
            |> Fixture.git!(["diff", "--name-only", block["admitted_commit"], id])
            |> String.split("\n", trim: true)
        end

      reported =
        (get_in(attempt, ["handoff", "scenarios"]) || [])
        |> Enum.flat_map(&(&1["changed_affected_paths"] || []))
        |> Enum.map(& &1["path"])

      tree ++ reported
    end)
    |> Enum.uniq()
  end

  defp refusal_reason(message) do
    [_, reason] = Regex.run(~r/Accepted Candidate not published: (.+?)\. Admitted /s, message)
    reason
  end

  defp record_id(control) do
    control
    |> Path.join(".kogen/runtime/scenario-tracking/*/record.json")
    |> Path.wildcard()
    |> Enum.sort_by(&File.stat!(&1, time: :posix).ctime)
    |> List.last()
    |> case do
      nil -> "none"
      path -> path |> Path.dirname() |> Path.basename()
    end
  end

  defp admission(control, label) do
    build_id = "#{label}-#{System.unique_integer([:positive])}"

    {%{
       control: control,
       slug: @slug,
       build_id: build_id,
       intent_id: Fixture.intent_id(),
       title: "Workspace fixture",
       branch: "main",
       commit: Fixture.git!(control, ["rev-parse", "HEAD"])
     }, build_id}
  end
end
