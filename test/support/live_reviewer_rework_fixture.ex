Code.require_file("review_packet_audit.ex", __DIR__)
Code.require_file("boundary_probe_fixture.ex", __DIR__)
# `run/0` calls these audits; requiring them here keeps every loader of this
# fixture (the live owner and `prepare_test.exs`) free of undefined-module
# warnings, whatever order test files load in.
Code.require_file("live_rework_audit.ex", __DIR__)
Code.require_file("root_profile_audit.ex", __DIR__)
# `prepare/1`'s setup path (never ExUnit) needs this one explicitly: `mix
# run` (the `prepare` catalog argv) does not load `test/support/*.ex` the
# way `mix test` does.
Code.require_file("dependency_fixture.ex", __DIR__)

defmodule Kogen.LiveReviewerReworkFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kogen.Build.{Contract, VerificationPlan, Workspace, WriteBoundary}
  alias Kogen.{Intent, LiveReworkAudit, ReviewPacketAudit, RootProfileAudit}

  @slug "live-reviewer-rework-probe"
  @intent_id "01960000-0000-7000-8000-00000000beef"
  @route "claude-dominant-adversarial-codex"

  # Mirrors `Kogen.Build.GuardedPaths`' `@volatile` list
  # (lib/kogen/build/guarded_paths.ex), which has no public accessor.
  # Controller volatile state a fixture copy must never inherit
  # (evidence/probe-prepare/REPORT.md P6b).
  @volatile ~w(.kogen/runtime .kogen/build.lock .kogen/codex .codex/sessions _build deps cover .elixir_ls)

  @check_rule """
  check:
  \t@test -f dummy.txt || (echo "dummy.txt is missing. Required exact content: reviewer-rework-k4q9z" && exit 1)
  \t@printf 'reviewer-rework-k4q9z\\n' | cmp -s - dummy.txt || (echo "dummy.txt must contain reviewer-rework-k4q9z followed by exactly one LF newline" && exit 1)
  """

  @intent """
  id: #{@intent_id}
  slug: #{@slug}
  title: Live reviewer rework probe
  may_change_guarded_paths:
    - dummy.txt
    - reviewer-notes.md
  """

  @scenarios """
  - id: reviewer-directed-rework
    given: an isolated provider-backed fixture with no dummy.txt or reviewer-notes.md
    when: the first Developer turn implements this test protocol
    then: it creates dummy.txt at the repository root containing exactly reviewer-rework-k4q9z followed by one LF newline, deliberately leaves reviewer-notes.md absent for the first independent Reviewer to identify, and creates reviewer-notes.md containing exactly reviewer-confirmed-k4q9z followed by one LF newline only after that Reviewer returns actionable rework in the exact same Developer conversation. For the first controlled phase, its final free-prose notes plainly disclose that reviewer-notes.md is intentionally absent pending the mandated independent Review -- not a contract objection -- and reference only files that actually exist; it does not fabricate the missing file or gate receipts. The fresh second Reviewer assesses only the final Candidate's exact bytes and current passing Check before accepting it. The outer live-test driver exclusively audits the historical omission, first Review, and resume sequence from retained streams, receipts, and Check archives; a nested Reviewer must not request inaccessible prior records or transcripts, and cannot certify its own future acceptance
    wrong_result: the first Reviewer accepts without inspecting the intentionally deferred companion file, a replacement Developer session performs rework, or the final Candidate lacks the companion file
    verified_by: [check]
    evidence: provider-backed Build-only fixture preserves both structured reviewer receipts, Developer raw streams, Stop records, and the resulting Commit
    proof:
      offline: [test/kogen/live_rework_audit_test.exs, test/kogen/verification_ownership_lifecycle_test.exs]
      paid_target: none
      paid_reason: "offline-sufficient: the fixture check deterministically rejects missing or malformed candidate bytes"
      affected_paths: [dummy.txt, reviewer-notes.md]
  """

  @risks """
  - id: seeded-fixture-is-not-user-ownership
    scenario_ids: [reviewer-directed-rework]
    description: Fixture seed state is not acceptance evidence.
  """

  def run do
    project_root = File.cwd!()

    # Never the default: this fixture proves the Reviewer really runs on the
    # adversarial harness, so it names the hybrid route explicitly.
    {:ok, config} =
      Intent.read_config(Path.join(project_root, ".kogen/config.yaml"), @route)

    log_dir = owned_log_dir(project_root)

    raw_fixture =
      Path.join(
        System.tmp_dir!(),
        "kogen-reviewer-rework-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(raw_fixture)
    on_exit(fn -> File.rm_rf!(raw_fixture) end)

    # The fixture project root is created under System.tmp_dir!() and then
    # resolved to its canonical, symlink-free path (fixture-outside-checkout):
    # macOS aliases /tmp and /var/folders through symlinks, and both the
    # Codex environment and Claude Code's path-keyed login scopes need the
    # canonical form. Nothing is created under the checkout's
    # .kogen/runtime/live-reviewer-rework.
    fixture = ReviewPacketAudit.assert_outside_checkout!(raw_fixture, project_root)

    # Fail closed, before any provider dispatch, if the fixture does not
    # resolve to a logged-in Kogen Claude Code login scope (Developer) or a
    # logged-in Kogen Codex login scope (Reviewer, Expert), or if the hook
    # toolchain is below its required version. These are exactly the
    # functions `prepare/1` runs (scenario prepare-rehearsed-in-check): the
    # live owner and `prepare` call the same entry points, never a copy.
    assert_scopes_and_toolchain_ready!(fixture, project_root)

    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")
    setup_fixture(project_root, fixture)
    precompile!(fixture, log_dir)
    write_package!(fixture)

    # Fail closed locally before a provider-backed Build can be dispatched.
    approved = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    assert {:ok, contract} = Contract.load(approved)
    assert contract.scenarios != []
    catalog = assert_catalog_ready!(fixture)

    assert {:ok, _plan} =
             VerificationPlan.build(
               contract.scenarios,
               ["dummy.txt", "reviewer-notes.md"],
               catalog,
               fixture
             )

    raw_stream_dir = Path.join(log_dir, "build-raw-streams")
    {:ok, codex_scope} = Kogen.Codex.effective_scope(fixture)
    scope_before = File.ls!(codex_scope.path)

    {output, status} =
      System.cmd("mix", ["kogen.build", @slug, "--route", @route],
        cd: fixture,
        env: [
          {"KOGEN_RAW_LOG_DIR", raw_stream_dir},
          {"MIX_BUILD_PATH", Path.join(fixture, "_build")},
          {"KOGEN_JEV_TRANSPORT", nil},
          {"KOGEN_JEV_SECURITY", nil},
          # Only the nested Build's roles run the fixture's SessionStart probe.
          {"KOGEN_BOUNDARY_PROBE_OUTSIDE", Kogen.BoundaryProbeFixture.outside(fixture)}
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "build-console.log"), output)
    complete = Path.join(fixture, ".kogen/intents/complete/#{@slug}")
    preserve(fixture, complete, log_dir)
    # Records, sidecars, packets and the complete package survive fixture
    # removal, including when the nested Build fails.
    retained = ReviewPacketAudit.retain_evidence!(fixture, log_dir, @slug)

    assert status == 0,
           "reviewer-rework Build failed (#{status}):\n#{output}\nretained: #{log_dir}"

    assert File.dir?(complete)

    audit =
      LiveReworkAudit.audit!(fixture, raw_stream_dir, slug: @slug, intent_id: @intent_id)

    # The Build ran in the fixture with the fixture's config and login scope.
    # Each role is audited in its own assigned harness's native session store,
    # so a hybrid route proves the Reviewer really ran on the adversary.
    RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/developer"),
      %{audit.developer_session_id => Map.put(config.developer, :role, "developer")},
      RootProfileAudit.sessions_root(fixture, :developer, @route)
    )

    RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/reviewer"),
      %{
        audit.rework_reviewer_session_id => Map.put(config.reviewer, :role, "reviewer"),
        audit.accepting_reviewer_session_id => Map.put(config.reviewer, :role, "reviewer")
      },
      RootProfileAudit.sessions_root(fixture, :reviewer, @route)
    )

    File.write!(
      Path.join(log_dir, "native-receipt-summary.json"),
      Jason.encode!(audit.native_summary) <> "\n"
    )

    assert [build_id] = retained.build_ids, "expected exactly one nested Build tracking id"

    assert_codex_bounded!(
      log_dir,
      build_id,
      fixture,
      codex_scope.path,
      scope_before,
      raw_stream_dir,
      [audit.rework_reviewer_session_id, audit.accepting_reviewer_session_id]
    )

    ReviewPacketAudit.audit!(log_dir, build_id, {:git, fixture, audit.candidate})

    assert_reviewer_reask!(
      log_dir,
      build_id,
      fixture,
      config,
      audit.accepting_reviewer_session_id
    )

    File.rm_rf!(fixture)
    assert :ok = LiveReworkAudit.audit_retained!(log_dir)
  end

  # `reviewer-reask-once` (paid): the real Codex Reviewer accepted the
  # per-launch schema, so its accepting verdict names exactly the enum's
  # scenario ids. Then one real re-ask resumes that same session, in the
  # fixture project's own Codex scope (where the session lives), with the
  # controller's own re-ask text and an error naming a nonexistent evidence
  # path. The repaired verdict must be schema-valid, come from the same
  # session and keep its `verdict` value.
  @reask_scenario_ids ["reviewer-directed-rework"]

  defp assert_reviewer_reask!(log_dir, build_id, fixture, config, session_id) do
    record =
      [log_dir, "scenario-tracking", build_id, "record.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    accepted = record["attempts"] |> List.last() |> Map.fetch!("verdict")
    assert accepted["verdict"] == "accept"
    assert Enum.map(accepted["scenarios"], & &1["id"]) == @reask_scenario_ids

    prompt =
      Kogen.Build.reask_prompt(%{
        "errors" => [
          %{
            "pointer" => "/scenarios/0/evidence/0/path",
            "rule" => "file does not exist: reviewer-reask-probe-missing.md"
          }
        ]
      })

    assert {:ok, runtime} = Kogen.Harness.open_roles(config, [:reviewer], fixture)

    try do
      context =
        runtime
        |> Kogen.Harness.role_context(:reviewer)
        |> Map.put(:cwd, fixture)
        |> Kogen.Harness.with_ledger([])
        |> Kogen.Harness.with_scenarios(@reask_scenario_ids)

      result =
        Kogen.Harness.resume_reviewer(
          session_id,
          prompt,
          config.reviewer.model,
          config.reviewer.effort,
          context
        )

      File.write!(Path.join(log_dir, "reviewer-reask.txt"), inspect(result, limit: :infinity))
      assert {:ok, verdict} = result
      assert verdict.session_id == session_id
      assert verdict.verdict == accepted["verdict"]
      assert Enum.map(verdict.response["scenarios"], & &1["id"]) == @reask_scenario_ids
    after
      Kogen.Harness.close(runtime)
    end
  end

  # The real Codex Reviewer returned both verdicts inside the nested Build's
  # applied boundary, which granted the Codex scope; its SessionStart probe
  # wrote inside and was refused outside; no refused scope entry appeared.
  defp assert_codex_bounded!(log_dir, build_id, fixture, scope, scope_before, raw, reviewers) do
    record =
      [log_dir, "scenario-tracking", build_id, "record.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    boundary = record["boundary"]
    worktree = record["candidate"]["worktree_path"]
    assert boundary["mode"] == "applied"
    assert boundary["grants"]["codex_scope"] == Workspace.canonical(scope)
    assert "hooks.json" in boundary["denied_scope_entries"]

    reviewer_lines =
      Enum.filter(Kogen.BoundaryProbeFixture.lines(raw), &(&1["role"] == "reviewer"))

    assert length(reviewer_lines) >= 2, "expected one probe receipt per Codex Reviewer session"

    with_ids = Enum.filter(reviewer_lines, &is_binary(&1["session_id"]))
    for line <- with_ids, do: assert(line["session_id"] in reviewers, inspect(line))

    if length(with_ids) == length(reviewer_lines),
      do:
        assert(
          Enum.sort(Enum.uniq(Enum.map(with_ids, & &1["session_id"]))) == Enum.sort(reviewers)
        )

    Enum.each(reviewer_lines, &Kogen.BoundaryProbeFixture.assert_bounded!(&1, worktree))
    Kogen.BoundaryProbeFixture.assert_nothing_escaped!(fixture)

    appeared = File.ls!(scope) -- scope_before
    denied = WriteBoundary.codex_denied_entries()

    assert Enum.filter(appeared, &(&1 in denied)) == [],
           "refused scope entries appeared: #{inspect(appeared)}"
  end

  def write_package!(fixture) do
    dir = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "intent.yaml"), @intent)
    File.write!(Path.join(dir, "scenarios.yaml"), @scenarios)
    File.write!(Path.join(dir, "risks.yaml"), @risks)
  end

  defp owned_log_dir(root) do
    base = System.get_env("KOGEN_LIVE_LOG_DIR") || Path.join(root, ".kogen/runtime/live-evidence")
    dir = Path.join(base, "reviewer-rework-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Copies `root` into `fixture` excluding `Kogen.Build.GuardedPaths`' volatile
  set (`@volatile` above) plus this fixture's own `.git`/`.kogen/intents`
  exclusions, then verifies none of the volatile paths landed. Isolated from
  `setup_fixture/2`'s git/mix bootstrap so it is directly testable with a
  small planted tree (mirrors `test/support/shaping_evaluation/driver.py`'s
  `copy_fixture_source_tree`).
  """
  def copy_source!(root, fixture) do
    excludes =
      Enum.map(@volatile, &("--exclude=" <> &1)) ++
        ["--exclude=.git", "--exclude=.kogen/intents"]

    {_out, 0} =
      System.cmd("rsync", ["-a"] ++ excludes ++ [root <> "/", fixture <> "/"])

    volatile_copied = Enum.filter(@volatile, &File.exists?(Path.join(fixture, &1)))

    if volatile_copied != [] do
      raise "fixture copy retained volatile GuardedPaths state: #{inspect(volatile_copied)}"
    end

    :ok
  end

  defp setup_fixture(root, fixture) do
    VerificationPlan.trace("Kogen.LiveReviewerReworkFixture.setup_fixture")
    copy_source!(root, fixture)

    # Warm seed: deps are copied (not rebuilt) so `precompile!/2` compiles
    # against an already-fetched dependency tree in the fixture's isolated
    # copy, instead of re-resolving them from network or cache each time.
    Kogen.DependencyFixture.copy!(Path.join(root, "deps"), Path.join(fixture, "deps"))
    {:ok, catalog} = VerificationPlan.load(root)

    other_targets =
      catalog.entries
      |> Enum.reject(&(&1["name"] == "check"))
      |> VerificationPlan.render_target_declarations()

    File.write!(Path.join(fixture, "Makefile"), @check_rule <> other_targets)
    Kogen.BoundaryProbeFixture.install_codex!(fixture)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: fixture, env: env)
  end

  defp precompile!(fixture, log_dir) do
    VerificationPlan.trace("Kogen.LiveReviewerReworkFixture.precompile!")

    {out, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: fixture,
        env: [{"MIX_BUILD_PATH", Path.join(fixture, "_build")}],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "fixture-precompile.log"), out)
    assert status == 0, "fixture precompile failed (#{status}):\n#{out}"
  end

  # Fail closed, before any provider dispatch, if the fixture does not
  # resolve to a logged-in Kogen Claude Code login scope (Developer) or a
  # logged-in Kogen Codex login scope (Reviewer, Expert), or if the hook
  # toolchain is below its required version. Delegates to
  # `Kogen.ReviewPacketAudit`'s non-raising `prepare`-step readiness checks
  # and turns a failure into a test failure here, so the live owner and
  # `prepare/1` (below) run the exact same three functions.
  defp assert_scopes_and_toolchain_ready!(fixture, project_root) do
    case readiness(fixture, project_root) do
      :ok -> :ok
      {:error, reason} -> flunk(reason)
    end
  end

  # `VerificationPlan.load/1` validates that the fixture's copied catalog
  # (`priv/kogen/verification_targets.yaml`) matches its rendered Makefile
  # (`VerificationPlan.render_target_declarations/1` in `setup_fixture/2`
  # above), so a mismatch fails here rather than surfacing later.
  defp assert_catalog_ready!(fixture) do
    VerificationPlan.trace("Kogen.LiveReviewerReworkFixture.assert_catalog_ready!")
    assert {:ok, catalog} = VerificationPlan.load(fixture)
    catalog
  end

  # The three functions run before any provider dispatch, shared verbatim
  # between the live owner (`run/0`, through `assert_scopes_and_toolchain_ready!/2`)
  # and `prepare/1`. Each traced call writes to `KOGEN_REHEARSAL_TRACE`
  # (`Kogen.Build.VerificationPlan.trace/1`), which `scripts/check/rehearsals.exs`
  # asserts against `prepare_trace_assertions` for the controlled passing
  # scope, and which `Kogen.ReviewPacketAudit.claude_scope_ready?/1`,
  # `codex_scope_ready?/1` and `hook_toolchain_ready?/1` fail closed for
  # (controlled through `KOGEN_PREPARE_SCOPE_OVERRIDE` /
  # `KOGEN_PREPARE_TOOLCHAIN_OVERRIDE`) with the controlled failing scope.
  defp readiness(fixture, project_root) do
    with :ok <- traced(&ReviewPacketAudit.claude_scope_ready?/1, fixture, "claude_scope_ready?"),
         :ok <- traced(&ReviewPacketAudit.codex_scope_ready?/1, fixture, "codex_scope_ready?") do
      traced(&ReviewPacketAudit.hook_toolchain_ready?/1, project_root, "hook_toolchain_ready?")
    end
  end

  defp traced(fun, arg, name) do
    VerificationPlan.trace("Kogen.ReviewPacketAudit." <> name)
    fun.(arg)
  end

  @doc """
  The `prepare` command contract for `live-reviewer-rework`
  (scenario prepare-rehearsed-in-check): runs `run/0`'s own setup -- fixture
  copy (excluding `Kogen.Build.GuardedPaths`' volatile set), warm dependency
  seed, compiling the fixture in its isolated copy, catalog/Makefile match,
  login-scope resolution and hook-toolchain resolution -- through the exact
  same functions `run/0` calls, then cleans the fixture up. It never reaches
  a provider. Returns `:ok`, `{:error, {:environment, reason}}` for a
  logged-out scope or a below-version hook toolchain, or
  `{:error, {:offline, reason}}` for anything the Candidate caused (a broken
  copy, a failing compile, a catalog/Makefile mismatch).
  """
  def prepare(opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())

    raw_fixture =
      Path.join(
        System.tmp_dir!(),
        "kogen-reviewer-rework-prepare-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(raw_fixture)

    log_dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-reviewer-rework-prepare-log-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(log_dir)

    try do
      fixture = ReviewPacketAudit.assert_outside_checkout!(raw_fixture, project_root)

      case readiness(fixture, project_root) do
        :ok -> prepare_setup(project_root, fixture, log_dir)
        {:error, reason} -> {:error, {:environment, reason}}
      end
    after
      File.rm_rf!(raw_fixture)
      File.rm_rf!(log_dir)
    end
  end

  defp prepare_setup(project_root, fixture, log_dir) do
    setup_fixture(project_root, fixture)
    precompile!(fixture, log_dir)
    write_package!(fixture)
    assert_catalog_ready!(fixture)
    :ok
  rescue
    error -> {:error, {:offline, Exception.format(:error, error, __STACKTRACE__)}}
  end

  @doc """
  CLI entry point for the `prepare` catalog field: `env MIX_ENV=test mix run
  --no-start -e Kogen.LiveReviewerReworkFixture.prepare_main()`. Exits 0 on
  success. On an environment failure it prints the one
  `KOGEN_PREPARE_RESULT\t{"class":"environment","reason":…}` frame the
  generic `prepare` result contract requires, then halts nonzero. Any other
  failure halts nonzero with no frame (a Candidate/`offline` failure).
  """
  def prepare_main do
    case prepare() do
      :ok ->
        System.halt(0)

      {:error, {:environment, reason}} ->
        IO.puts(
          "KOGEN_PREPARE_RESULT\t" <>
            Jason.encode!(%{"class" => "environment", "reason" => reason})
        )

        System.halt(1)

      {:error, {:offline, reason}} ->
        IO.puts(:stderr, "live-reviewer-rework prepare failed: " <> reason)
        System.halt(1)
    end
  end

  defp preserve(fixture, complete, log_dir) do
    for {source, name} <- [
          {Path.join(fixture, ".kogen/runtime/verification-history.jsonl"),
           "verification-history.jsonl"},
          {Path.join(complete, "evidence.md"), "evidence.md"}
        ],
        File.exists?(source),
        do: File.cp!(source, Path.join(log_dir, name))

    retained =
      for path <-
            Path.wildcard(Path.join(fixture, ".kogen/runtime/scenario-tracking/*/record.json")) do
        destination =
          Path.join([
            log_dir,
            "scenario-tracking",
            Path.basename(Path.dirname(path)),
            "record.json"
          ])

        File.mkdir_p!(Path.dirname(destination))
        File.cp!(path, destination)
        ReviewPacketAudit.preserve_record_versions!(path, destination)
        {Path.relative_to(path, fixture), destination}
      end

    retained = Map.new(retained)

    for path <- Path.wildcard(Path.join(complete, "build-summary*.json")) do
      summary = path |> File.read!() |> Jason.decode!()
      source = get_in(summary, ["full_record", "path"])
      destination = Map.fetch!(retained, source)
      updated = put_in(summary, ["full_record", "path"], destination)
      File.write!(Path.join(log_dir, Path.basename(path)), Jason.encode!(updated) <> "\n")
    end
  end
end
