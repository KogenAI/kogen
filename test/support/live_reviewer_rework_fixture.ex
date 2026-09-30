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
Code.require_file("fixture_validation.ex", __DIR__)

defmodule Kogen.LiveReviewerReworkFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kogen.Build.{Contract, VerificationPlan, Workspace, WriteBoundary}
  alias Kogen.Harness.Claude
  alias Kogen.{Intent, LiveReworkAudit, ReviewPacketAudit, RootProfileAudit}

  @slug "live-reviewer-rework-probe"
  @intent_id "01960000-0000-7000-8000-00000000beef"
  @project_root Path.expand("../..", __DIR__)

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
    then: before writing any file, the first Developer turn dispatches exactly two separate native implementation helpers (never one helper twice, never a built-in agent) and waits for both -- helper A owns dummy.txt, creates it and then runs `printf 'reviewer-rework-k4q9z\\n' | cmp -s - dummy.txt && echo A OK`; helper B owns nothing, only runs `test ! -e reviewer-notes.md && echo B OK` -- and each returns its command output; the Developer then reruns both checks itself. It creates dummy.txt at the repository root containing exactly reviewer-rework-k4q9z followed by one LF newline, deliberately leaves reviewer-notes.md absent for the first independent Reviewer to identify, and creates reviewer-notes.md containing exactly reviewer-confirmed-k4q9z followed by one LF newline only after that Reviewer returns actionable rework in the exact same Developer conversation. For the first controlled phase, its final free-prose notes plainly disclose that reviewer-notes.md is intentionally absent pending the mandated independent Review -- not a contract objection -- and reference only files that actually exist; it does not fabricate the missing file or gate receipts. The fresh second Reviewer assesses only the final Candidate's exact bytes and current passing Check before accepting it. The outer live-test driver exclusively audits the historical omission, first Review, resume sequence and helper dispatch from retained streams, receipts, and Check archives; a nested Reviewer must not request inaccessible prior records or transcripts, and cannot certify its own future acceptance
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

  def run(route \\ nil) do
    project_root = @project_root
    route = route || System.get_env("KOGEN_ROUTE")

    {:ok, config} =
      Intent.read_config(Path.join(project_root, ".kogen/config.yaml"), route)

    route = config.route

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
    # resolve every harness assigned to the selected route to its Kogen login
    # scope, or if the hook toolchain is below its required version. These are
    # exactly the functions `prepare/1` runs (scenario
    # prepare-rehearsed-in-check): the live owner and `prepare` call the same
    # entry points, never a copy.
    assert_scopes_and_toolchain_ready!(fixture, project_root, config)

    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")
    setup_fixture(project_root, fixture, config)
    precompile!(fixture, log_dir)
    write_package!(fixture)

    # Fail closed locally before a provider-backed Build can be dispatched.
    assert_package_ready!(fixture)
    record = validate_fixture!(fixture)
    File.write!(Path.join(log_dir, "fixture-inputs.json"), Jason.encode!(record) <> "\n")

    raw_stream_dir = Path.join(log_dir, "build-raw-streams")

    codex_scope =
      if "codex" in role_harnesses(config) do
        {:ok, scope} = Kogen.Codex.effective_scope(fixture)
        scope
      end

    scope_before = if codex_scope, do: File.ls!(codex_scope.path), else: []

    # The nested Build controller runs under process custody: if this outer
    # driver dies (a canceled live run), the supervisor's parent-death
    # watchdog terminates the nested controller and its descendants instead
    # of leaving an orphaned Build doing provider work.
    {output, status} =
      nested_build!(fixture, route, [
        {"KOGEN_RAW_LOG_DIR", raw_stream_dir},
        {"ERL_CRASH_DUMP", Path.join(log_dir, "erl_crash-build.dump")},
        {"MIX_BUILD_PATH", Path.join(fixture, "_build")},
        {"KOGEN_JEV_TRANSPORT", nil},
        {"KOGEN_JEV_SECURITY", nil},
        # Only the nested Build's roles run the fixture's SessionStart probe.
        {"KOGEN_BOUNDARY_PROBE_OUTSIDE", Kogen.BoundaryProbeFixture.outside(fixture)}
      ])

    File.write!(Path.join(log_dir, "build-console.log"), output)
    complete = Path.join(fixture, ".kogen/intents/complete/#{@slug}")
    preserve(fixture, complete, log_dir)
    # Records, sidecars, packets and the complete package survive fixture
    # removal, including when the nested Build fails.
    retained = ReviewPacketAudit.retain_evidence!(fixture, log_dir, @slug)

    assert status == 0,
           "reviewer-rework Build failed (#{status}):\n#{output}\nretained: #{log_dir}"

    assert File.dir?(complete)
    assert_frozen_route!(log_dir, route, config)

    audit =
      LiveReworkAudit.audit!(fixture, raw_stream_dir, slug: @slug, intent_id: @intent_id)

    # The Build ran in the fixture with the fixture's config and login scope.
    # Each role is audited in its own assigned harness's native session store,
    # so a hybrid route proves the Reviewer really ran on the adversary.
    RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/developer"),
      %{audit.developer_session_id => Map.put(config.developer, :role, "developer")},
      RootProfileAudit.sessions_root(fixture, :developer, route)
    )

    RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/reviewer"),
      %{
        audit.rework_reviewer_session_id => Map.put(config.reviewer, :role, "reviewer"),
        audit.accepting_reviewer_session_id => Map.put(config.reviewer, :role, "reviewer")
      },
      RootProfileAudit.sessions_root(fixture, :reviewer, route)
    )

    File.write!(
      Path.join(log_dir, "native-receipt-summary.json"),
      Jason.encode!(audit.native_summary) <> "\n"
    )

    assert_runtime_versions!(fixture, route, config, raw_stream_dir, [
      {audit.developer_session_id, :developer},
      {audit.rework_reviewer_session_id, :reviewer},
      {audit.accepting_reviewer_session_id, :reviewer}
    ])

    assert_helper_dispatches!(
      log_dir,
      fixture,
      config,
      raw_stream_dir,
      audit.developer_session_id
    )

    assert [build_id] = retained.build_ids, "expected exactly one nested Build tracking id"

    assert_developer_bounded!(
      log_dir,
      build_id,
      fixture,
      if(codex_scope, do: codex_scope.path),
      scope_before,
      raw_stream_dir,
      [audit.developer_session_id]
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

  defp nested_build!(fixture, route, env) do
    argv = [System.find_executable("mix"), "kogen.build", @slug, "--route", route]

    case Kogen.ProcessCustody.run(argv, fixture,
           env: env,
           role: "nested-build",
           timeout_ms: 1_140_000,
           grace_ms: 10_000
         ) do
      {:ok, %{"exit_code" => status, "output" => output}} -> {output, status}
      {:error, reason} -> flunk("nested Build custody failed: #{inspect(reason)}")
    end
  end

  # Wrong-route substitution fails: the nested Build froze exactly the
  # explicitly selected route and its resolved role profiles.
  defp assert_frozen_route!(log_dir, route, config) do
    [record_path] = Path.wildcard(Path.join(log_dir, "scenario-tracking/*/record.json"))
    frozen = record_path |> File.read!() |> Jason.decode!() |> Map.fetch!("route")

    assert frozen["name"] == route,
           "nested Build froze route #{inspect(frozen["name"])}, expected #{route}"

    for role <- ~w(developer reviewer) do
      profile = Map.fetch!(config, String.to_existing_atom(role))

      assert %{"model" => profile.model, "effort" => profile.effort} ==
               Map.take(frozen[role], ["model", "effort"]),
             "nested Build froze #{role} #{inspect(frozen[role])}, expected #{inspect(profile)}"
    end
  end

  # Each role's actual runtime version comes from its own harness's native
  # receipt: Claude Code's stream `system/init`, and Codex's native rollout
  # `session_meta` (exec JSONL does not carry `cli_version`).
  defp assert_runtime_versions!(fixture, route, config, raw_dir, sessions) do
    streams =
      raw_dir
      |> Path.join("raw-stream-*.jsonl")
      |> Path.wildcard()
      |> Enum.map(&{&1, raw_events(&1)})

    for {session_id, role} <- sessions do
      assert_runtime_version!(Intent.role_harness(config, role), streams, session_id, role, fn ->
        RootProfileAudit.sessions_root(fixture, role, route)
      end)
    end
  end

  defp assert_runtime_version!("claude", streams, session_id, role, _sessions_root) do
    expected = Kogen.ClaudeCode.pinned_version()

    versions =
      for {_path, events} <- streams,
          %{
            "type" => "system",
            "subtype" => "init",
            "session_id" => ^session_id,
            "claude_code_version" => version
          } <- events,
          do: version

    assert expected in versions,
           "Claude #{role} receipt #{session_id} must identify #{expected}, got #{inspect(versions)}"
  end

  defp assert_runtime_version!("codex", _streams, session_id, role, sessions_root) do
    versions = RootProfileAudit.codex_cli_versions!(sessions_root.(), [session_id])

    assert versions == %{session_id => Kogen.ManagedRuntimeReady.codex_version()},
           "Codex #{role} rollout #{session_id} must identify #{Kogen.ManagedRuntimeReady.codex_version()}, got #{inspect(versions)}"
  end

  # The fixture's scenario explicitly requests two native implementation
  # helpers. Audit the assigned harness's retained native records, using the
  # selected route's worker profile as the expected model and effort.
  defp assert_helper_dispatches!(log_dir, fixture, config, raw_dir, developer_id) do
    worker = Intent.role_config(config, :developer).helpers.worker

    case Intent.role_harness(config, :developer) do
      "claude" ->
        events =
          raw_dir
          |> Path.join("raw-stream-*.jsonl")
          |> Path.wildcard()
          |> Enum.map(&raw_events/1)
          |> Enum.filter(fn events ->
            Enum.any?(events, &(&1["type"] == "system" and &1["session_id"] == developer_id))
          end)
          |> List.flatten()

        executed = Claude.executed_models(events)

        File.write!(
          Path.join(log_dir, "developer-helper-receipts.json"),
          Jason.encode!(executed) <> "\n"
        )

        assert executed["root"] == [config.developer.model],
               "Developer root model receipts: #{inspect(executed["root"])}"

        workers =
          Enum.filter(executed["helpers"], &(&1["agent"] == "kogen-worker"))

        assert length(Enum.uniq_by(workers, & &1["tool_use_id"])) >= 2,
               "expected two separate kogen-worker dispatches, got #{inspect(executed["helpers"])}"

        for helper <- workers do
          assert helper["models"] == [worker.model],
                 "helper #{helper["tool_use_id"]} ran #{inspect(helper["models"])}, expected #{worker.model}"
        end

      "codex" ->
        assert_codex_helper_dispatches!(log_dir, fixture, config, developer_id, worker)
    end
  end

  defp find_codex_parent(session_files, developer_id) do
    Enum.find(session_files, fn path ->
      Enum.any?(
        codex_rows!(path),
        &match?(%{"type" => "session_meta", "payload" => %{"id" => ^developer_id}}, &1)
      )
    end)
  end

  defp codex_spawn_dispatches(rows) do
    Enum.flat_map(rows, fn
      %{
        "type" => "response_item",
        "payload" => %{"type" => "function_call", "name" => "spawn_agent", "arguments" => args}
      } ->
        decode_spawn_arguments(args)

      _ ->
        []
    end)
  end

  defp decode_spawn_arguments(args) when is_map(args), do: [args]

  defp decode_spawn_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> [decoded]
      _ -> []
    end
  end

  defp decode_spawn_arguments(_args), do: []

  defp codex_child_rows(session_files, developer_id) do
    session_files
    |> Enum.map(&codex_rows!/1)
    |> Enum.filter(fn rows ->
      Enum.any?(rows, fn
        %{
          "type" => "session_meta",
          "payload" => %{"id" => id, "parent_thread_id" => ^developer_id}
        } ->
          id != developer_id

        _ ->
          false
      end)
    end)
  end

  defp codex_turn_profiles(rows) do
    rows
    |> Enum.flat_map(fn
      %{"type" => "turn_context", "payload" => %{"model" => model, "effort" => effort}} ->
        [[model, effort]]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp assert_codex_helper_dispatches!(log_dir, fixture, config, developer_id, worker) do
    sessions_root = RootProfileAudit.sessions_root(fixture, :developer, config.route)

    session_files = Path.wildcard(Path.join(sessions_root, "**/*.jsonl"))

    parent_path = find_codex_parent(session_files, developer_id)

    assert is_binary(parent_path), "missing Codex Developer session #{developer_id}"

    dispatches = codex_spawn_dispatches(codex_rows!(parent_path))

    assert length(dispatches) == 2,
           "expected two separate native worker dispatches, got #{inspect(dispatches)}"

    for dispatch <- dispatches do
      assert dispatch["agent_type"] in ["worker", "kogen-worker"],
             "unexpected helper kind: #{inspect(dispatch)}"

      assert dispatch["model"] == worker.model,
             "helper requested #{inspect(dispatch["model"])}, expected #{worker.model}"

      assert dispatch["reasoning_effort"] == worker.effort,
             "helper requested effort #{inspect(dispatch["reasoning_effort"])}, expected #{worker.effort}"
    end

    children = codex_child_rows(session_files, developer_id)

    assert length(children) == 2,
           "expected two native child sessions for #{developer_id}, got #{length(children)}"

    profiles = Enum.map(children, &codex_turn_profiles/1)

    assert profiles == List.duplicate([[worker.model, worker.effort]], 2),
           "Codex helper execution profiles #{inspect(profiles)} do not match #{inspect(worker)}"

    File.write!(
      Path.join(log_dir, "developer-helper-receipts.json"),
      Jason.encode!(%{"dispatches" => dispatches, "observed_profiles" => profiles}) <> "\n"
    )
  end

  defp codex_rows!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> [event]
        _ -> []
      end
    end)
  end

  defp raw_events(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> [event]
        _ -> []
      end
    end)
  end

  # `reviewer-reask-once` (paid): the real Claude Reviewer accepted the
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

  # The real Developer ran inside the nested Build's applied boundary, which
  # granted the Codex scope its Codex roles use; its SessionStart probe wrote
  # inside and was refused outside; no refused scope entry appeared.
  defp assert_developer_bounded!(
         log_dir,
         build_id,
         fixture,
         scope,
         scope_before,
         raw,
         developers
       ) do
    record =
      [log_dir, "scenario-tracking", build_id, "record.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    boundary = record["boundary"]
    worktree = record["candidate"]["worktree_path"]
    assert boundary["mode"] == "applied"

    if scope do
      assert boundary["grants"]["codex_scope"] == Workspace.canonical(scope)
      assert "hooks.json" in boundary["denied_scope_entries"]
    end

    developer_lines =
      Enum.filter(Kogen.BoundaryProbeFixture.lines(raw), &(&1["role"] == "developer"))

    assert developer_lines != [],
           "expected a probe receipt for the Developer session; hook sidecars: " <>
             inspect(Kogen.BoundaryProbeFixture.sidecars(raw))

    with_ids = Enum.filter(developer_lines, &is_binary(&1["session_id"]))
    for line <- with_ids, do: assert(line["session_id"] in developers, inspect(line))

    if length(with_ids) == length(developer_lines),
      do:
        assert(
          Enum.sort(Enum.uniq(Enum.map(with_ids, & &1["session_id"]))) == Enum.sort(developers)
        )

    Enum.each(developer_lines, &Kogen.BoundaryProbeFixture.assert_bounded!(&1, worktree))
    Kogen.BoundaryProbeFixture.assert_nothing_escaped!(fixture)

    if scope do
      appeared = File.ls!(scope) -- scope_before
      denied = WriteBoundary.codex_denied_entries()

      assert Enum.filter(appeared, &(&1 in denied)) == [],
             "refused scope entries appeared: #{inspect(appeared)}"
    end
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

  defp setup_fixture(root, fixture, config) do
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
    harnesses = Enum.map(Intent.roles(), &Intent.role_harness(config, &1))
    if "codex" in harnesses, do: Kogen.BoundaryProbeFixture.install_codex!(fixture)
    if "claude" in harnesses, do: Kogen.BoundaryProbeFixture.install_claude!(fixture)

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
  # resolve each harness assigned to the selected route to its Kogen login
  # scope, or if the hook toolchain is below its required version. Delegates to
  # `Kogen.ReviewPacketAudit`'s non-raising `prepare`-step readiness checks
  # and turns a failure into a test failure here, so the live owner and
  # `prepare/1` (below) run the exact same three functions.
  defp assert_scopes_and_toolchain_ready!(fixture, project_root, config) do
    case readiness(fixture, project_root, config) do
      :ok -> :ok
      {:error, reason} -> flunk(reason)
    end
  end

  # `VerificationPlan.load/1` validates that the fixture's copied catalog
  # (`priv/kogen/verification_targets.yaml`) matches its rendered Makefile
  # (`VerificationPlan.render_target_declarations/1` in `setup_fixture/2`
  # above), so a mismatch fails here rather than surfacing later.
  @doc """
  The written Approved package must load as a contract and plan against the
  fixture catalog. The live owner and `prepare/1` both run this, so a
  malformed fixture package fails in the provider-denied rehearsal instead
  of in the paid target.
  """
  def assert_package_ready!(fixture) do
    approved = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    assert {:ok, contract} = Contract.load(approved)
    assert contract.scenarios != []
    catalog = assert_catalog_ready!(fixture)

    assert {:ok, plan} =
             VerificationPlan.build(
               contract.scenarios,
               ["dummy.txt", "reviewer-notes.md"],
               catalog,
               fixture
             )

    plan
  end

  @doc """
  Validates the generated fixture exactly as the live target consumes it:
  required files, the Approved package through the real
  `Kogen.Intent.read/2` and `Kogen.Build.Contract.load/2` parsers, the
  fixture Makefile's `check` target, and a digest of the generated input
  bytes. `run/0` and `prepare/1` both call it right after the package is
  written, so the digest recorded before dispatch covers the consumed bytes.
  Returns the record or raises with every reason.
  """
  def validate_fixture!(fixture) do
    spec = %{
      "kind" => "live-reviewer-rework",
      "label" => @slug,
      "required" => ["Makefile", "mix.exs", "priv/kogen/verification_targets.yaml"],
      "yaml" => ["priv/kogen/verification_targets.yaml"],
      "approved" => ".kogen/intents/approved/#{@slug}",
      "makefile_targets" => ["check"]
    }

    case Kogen.FixtureValidation.validate(fixture, spec) do
      {:ok, record} -> record
      {:error, reasons} -> raise "generated fixture invalid: " <> Enum.join(reasons, "; ")
    end
  end

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
  defp readiness(fixture, project_root, config) do
    with :ok <- ready_harness_scopes(fixture, role_harnesses(config)) do
      traced(&ReviewPacketAudit.hook_toolchain_ready?/1, project_root, "hook_toolchain_ready?")
    end
  end

  defp ready_harness_scopes(fixture, harnesses) do
    Enum.reduce_while(harnesses, :ok, fn
      "claude", :ok ->
        result = traced(&ReviewPacketAudit.claude_scope_ready?/1, fixture, "claude_scope_ready?")
        if result == :ok, do: {:cont, :ok}, else: {:halt, result}

      "codex", :ok ->
        result = traced(&ReviewPacketAudit.codex_scope_ready?/1, fixture, "codex_scope_ready?")
        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp role_harnesses(config) do
    Intent.roles()
    |> Enum.map(&Intent.role_harness(config, &1))
    |> Enum.uniq()
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
    project_root = Keyword.get(opts, :project_root, @project_root)
    route = System.get_env("KOGEN_ROUTE")

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

      case Intent.read_config(Path.join(project_root, ".kogen/config.yaml"), route) do
        {:ok, config} ->
          case readiness(fixture, project_root, config) do
            :ok -> prepare_setup(project_root, fixture, log_dir, config)
            {:error, reason} -> {:error, {:environment, reason}}
          end

        {:error, reason} ->
          {:error, {:offline, "cannot resolve selected route: #{reason}"}}
      end
    after
      File.rm_rf!(raw_fixture)
      File.rm_rf!(log_dir)
    end
  end

  defp prepare_setup(project_root, fixture, log_dir, config) do
    Kogen.FixtureValidation.require_denied!()
    setup_fixture(project_root, fixture, config)
    precompile!(fixture, log_dir)
    write_package!(fixture)
    assert_package_ready!(fixture)
    record = validate_fixture!(fixture)

    if path = System.get_env("KOGEN_FIXTURE_VALIDATION_RECEIPT"),
      do: Kogen.FixtureValidation.append_record!(path, record)

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
