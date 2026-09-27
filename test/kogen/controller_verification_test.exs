Code.require_file("../support/scripted_build_fixture.ex", __DIR__)
Code.require_file("../support/controller_build_fixture.ex", __DIR__)

defmodule Kogen.ControllerVerificationTest do
  @moduledoc """
  Scenario `controller-owns-verification`: the Build controller (the trusted
  code the Build started with) runs `make check` and then the selected
  targets itself, as children outside the Developer process tree, and is the
  only writer of the context/state/history files and of the local
  Verification Record and its history. The Stop hook, still registered, does
  nothing without a v1 context.

  Scenario `failed-verification-resumes-same-developer`: a failed cycle
  resumes the exact Developer session, counts only against
  `verification_retries`, and the third consecutive failure stops the Build
  before Jev and Review; an outer (Review rework) resumption starts a fresh
  verification context.

  Scenario `bound-per-target-receipts`: every receipt carries its full
  binding, status comes only from the exit code, time limit and cleanup, a
  lingering process group member is terminated, and settlement rejects a
  tampered binding, a rolled-back history or an altered log digest.

  Scenario `no-special-gate-target`: no target name is special; the Build
  runs exactly the union of the approved `verified_by` lists.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{ReviewPacket, Tracking, Verification, VerificationRunner}
  alias Kogen.ControllerBuildFixture, as: F
  alias Kogen.ScriptedBuildFixture, as: Fixture

  # --- controller-owns-verification -----------------------------------

  test "the controller settles verification from its own run; forged Candidate state files are ignored" do
    dir = Fixture.fixture!()
    runtime = Path.join(dir, ".kogen/runtime")

    # The real verification and tracking directories live only in control
    # (never copied into the Candidate), so a forgery attempt can only ever
    # write inside the Candidate's own tree, superficially resembling the
    # controller's layout; the controller's real record on control must stay
    # unaffected regardless.
    forge = """
    mkdir -p .kogen/runtime/scenario-tracking/forged-build/verification/attempt-0-forged
    printf '{"candidate":"forged","status":"passed","target":"check","exit_code":0,"session_id":"forged","attempt_token":"forged","finished_at":"1970-01-01T00:00:00.000Z"}\n' > .kogen/runtime/verification.json
    printf '{"schema_version":2,"context_sha256":"forged","attempt_token":"forged","outer_attempt":0,"developer_session_id":"forged","candidate_id":"forged","cycles":[],"failures_since_pass":0,"terminal_state":"passed"}' > .kogen/runtime/scenario-tracking/forged-build/verification/attempt-0-forged/state.json
    """

    assert {:error, reason} =
             Fixture.run(dir, fail_all: [1], edits: %{1 => forge})

    assert reason =~ "offline retries exhausted (offline_retries: 4) after cycle 5"

    # The real local Verification Record reflects only the controller's own
    # cycles, never the Developer-forged claim.
    assert {:ok, record} = Kogen.Check.read_record(dir)
    assert record["status"] == "failed"
    assert record["candidate"] != "forged"
    assert record["session_id"] != "forged"

    [record_path] =
      Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))

    tracking = record_path |> File.read!() |> Jason.decode!()
    [attempt] = tracking["attempts"]
    verification = attempt["verification"]
    assert verification["terminal_state"] == "offline_exhausted"
    assert verification["candidate_id"] != "forged"

    [attempt_verification_dir] =
      Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/verification/attempt-*"))

    state = attempt_verification_dir |> Path.join("state.json") |> File.read!() |> Jason.decode!()
    assert state["terminal_state"] == "offline_exhausted"
    assert state["candidate_id"] != "forged"

    refute File.exists?(Path.join(runtime, "stop-check.log")),
           "the Stop hook is a bootstrap remnant and must never write its own settlement"
  end

  test "the Stop hook writes nothing and runs no target while the controller settles every cycle itself" do
    dir = Fixture.fixture!()

    assert :ok = Fixture.run(dir, fail_first: [1], reviews: "accept")

    runtime = Path.join(dir, ".kogen/runtime")
    refute File.exists?(Path.join(runtime, "stop-check.log"))
    refute File.exists?(Path.join(runtime, "verification-hook.lock"))
    refute File.exists?(Path.join(runtime, "verification-retries.json"))

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]

    # Every Developer turn's Stop invocation answered plain, inactive continue.
    responses =
      Path.join(runtime, "fake-hook-responses")
      |> then(fn path -> if File.exists?(path), do: File.read!(path), else: "" end)

    if responses != "" do
      for line <- String.split(responses, "\n", trim: true) do
        assert line == "{\"continue\":true}"
      end
    end
  end

  test "no launched Developer, Reviewer or target child receives an inherited verification or tracking context, and the outer state stays untouched" do
    dir = Fixture.fixture!()

    decoy_dir =
      Path.join(System.tmp_dir!(), "kogen-outer-context-#{System.unique_integer([:positive])}")

    File.mkdir_p!(decoy_dir)
    on_exit(fn -> File.rm_rf(decoy_dir) end)

    outer_context_path = Path.join(decoy_dir, "outer-context.json")
    outer_tracking_path = Path.join(decoy_dir, "outer-tracking.json")
    outer_context_bytes = Jason.encode!(%{"schema_version" => 1, "mode" => "unified"})
    outer_tracking_bytes = "outer tracking state, never touched\n"
    File.write!(outer_context_path, outer_context_bytes)
    File.write!(outer_tracking_path, outer_tracking_bytes)

    prior_context = System.get_env("KOGEN_VERIFICATION_CONTEXT")
    prior_tracking = System.get_env("KOGEN_TRACKING_CONTEXT")
    prior_retry_limit = System.get_env("KOGEN_VERIFICATION_RETRY_LIMIT")
    System.put_env("KOGEN_VERIFICATION_CONTEXT", outer_context_path)
    System.put_env("KOGEN_TRACKING_CONTEXT", outer_tracking_path)
    System.put_env("KOGEN_VERIFICATION_RETRY_LIMIT", "9")

    on_exit(fn ->
      if prior_context,
        do: System.put_env("KOGEN_VERIFICATION_CONTEXT", prior_context),
        else: System.delete_env("KOGEN_VERIFICATION_CONTEXT")

      if prior_tracking,
        do: System.put_env("KOGEN_TRACKING_CONTEXT", prior_tracking),
        else: System.delete_env("KOGEN_TRACKING_CONTEXT")

      if prior_retry_limit,
        do: System.put_env("KOGEN_VERIFICATION_RETRY_LIMIT", prior_retry_limit),
        else: System.delete_env("KOGEN_VERIFICATION_RETRY_LIMIT")
    end)

    # If the Developer's (or any target's) child process inherited a
    # plausible-looking v1 context, the real, unmodified Stop script would act
    # on it: `test/support/scripted_build_fixture.ex`'s provider raises unless
    # every Stop response is exactly the inactive `{"continue":true}`.
    assert :ok = Fixture.run(dir, reviews: "accept")

    assert File.read!(outer_context_path) == outer_context_bytes,
           "the outer Build's own verification context must never be touched"

    assert File.read!(outer_tracking_path) == outer_tracking_bytes,
           "the outer Build's own tracking context must never be touched"

    assert Kogen.Build.context_scrub() == [
             {"KOGEN_VERIFICATION_CONTEXT", nil},
             {"KOGEN_TRACKING_CONTEXT", nil},
             {"KOGEN_VERIFICATION_RETRY_LIMIT", nil}
           ]
  end

  test "a failed-then-passed cycle pair leaves a local Verification Record and history the LiveReworkAudit fields read, archived only when a new outer attempt starts" do
    dir = Fixture.fixture!()
    archive_dir = Path.join(dir, ".kogen/runtime/archives")

    # `Kogen.ScriptedBuildFixture.run/2` deliberately clears
    # `KOGEN_RAW_LOG_DIR` for its own callers, so this archiving assertion
    # drives `Kogen.Build.run/1` directly with the same fixture directory and
    # provider, keeping `KOGEN_RAW_LOG_DIR` set for the whole Build.
    assert :ok =
             run_with_raw_log_dir!(dir, archive_dir, fail_first: [1], reviews: "rework,accept")

    assert {:ok, record} = Kogen.Check.read_record(dir)

    for key <- ~w(candidate status target exit_code session_id attempt_token finished_at) do
      assert Map.has_key?(record, key), "Verification Record is missing #{key}"
    end

    assert record["target"] == "check"
    assert record["status"] == "passed"
    assert record["exit_code"] == 0

    archives =
      Path.wildcard(Path.join(archive_dir, "verification-history-*.jsonl"))

    assert length(archives) == 1,
           "the history is archived exactly once, only when the second outer attempt starts"

    archived_lines =
      archives
      |> hd()
      |> File.stream!()
      |> Enum.map(&(String.trim(&1) |> Jason.decode!()))

    assert Enum.map(archived_lines, & &1["status"]) == ["failed", "passed"],
           "the archived history keeps the first attempt's failed-then-passed cycle pair"

    live_lines =
      dir
      |> Path.join(".kogen/runtime/verification-history.jsonl")
      |> File.stream!()
      |> Enum.map(&(String.trim(&1) |> Jason.decode!()))

    assert Enum.map(live_lines, & &1["status"]) == ["passed"],
           "the live history is reset at the start of the second outer attempt"
  end

  # --- failed-verification-resumes-same-developer ----------------------

  test "a failed cycle resumes the exact Developer session with the failed target's receipt and log paths, never the outer allowance" do
    dir = Fixture.fixture!()

    assert :ok = Fixture.run(dir, fail_first: [1], reviews: "accept")

    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resumes")) == "1"

    prompt = File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resume-1"))
    assert String.starts_with?(prompt, "Controller verification failed after your turn")
    assert prompt =~ "`make check` failed"
    assert prompt =~ ~r{receipts/cycle-1-check\.json}
    assert prompt =~ ~r{logs/cycle-1-check\.log}
    refute prompt =~ "state.json"
    refute prompt =~ "context.json"
    refute prompt =~ "state-history.jsonl"

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    # A resumed-and-fixed cycle never reaches a second outer attempt.
    assert attempt["number"] == 0
  end

  # `check` is an offline target, so five consecutive failures (not three)
  # exhaust `offline_retries: 4` and stop before Jev's advisory reading has
  # any bearing and before Review. The fake Developer changes the Candidate
  # on every resumed turn (`Kogen.ScriptedBuildFixture`'s default resume
  # edit), so this exhaustion is never mistaken for the controller's
  # unchanged-Candidate stop, which is covered by its own test below.
  test "the fifth consecutive offline failure exhausts offline_retries and stops before Review" do
    dir = Fixture.fixture!()

    assert {:error, reason} = Fixture.run(dir, fail_all: [1])

    assert String.starts_with?(
             reason,
             "offline retries exhausted (offline_retries: 4) after cycle 5"
           )

    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resumes")) == "4"

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]

    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) ==
             ~w(failed failed failed failed failed)

    assert Enum.all?(attempt["verification"]["cycles"], &(&1["class"] == "offline"))
    refute Map.has_key?(attempt, "outcome")
  end

  test "an outer Review rework resumption starts a fresh verification context with no reuse" do
    dir = Fixture.fixture!()

    assert :ok = Fixture.run(dir, fail_first: [1], reviews: "rework,accept")

    tracking = Fixture.record!(dir)
    [first, second] = tracking["attempts"]
    assert Enum.map(first["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]
    assert Enum.map(second["verification"]["cycles"], & &1["status"]) == ["passed"]

    assert first["verification_context"]["sha256"] != second["verification_context"]["sha256"],
           "each outer attempt gets its own verification context"

    refute Enum.any?(
             List.last(second["verification"]["cycles"])["receipts"],
             &Map.has_key?(&1, "reused_from")
           ),
           "a new outer attempt reuses nothing from a prior attempt"
  end

  # --- candidate-routing ---------------------------------------------------
  #
  # Scenario `candidate-routing`: the review packet binding `path` in the
  # record and a record-version `sidecar` locator stay control-relative
  # (`Tracking` and `ReviewPacket` compute them from the explicit control
  # root, never `File.cwd!()`), a controller-verification receipt's
  # `log_path` resolves under control's attempt directory even when the
  # Candidate is a different tree, and a Build started from a third cwd
  # settles and publishes with capture and verify reading the recorded
  # Candidate root throughout.

  test "candidate-routing: the review packet binding path and a record-version sidecar locator are control-relative" do
    control = F.repo!(%{"dummy.txt" => "baseline\n"})
    candidate = F.repo!(%{"dummy.txt" => "changed\n"})

    assert {:ok, state} =
             Tracking.new(
               %{"id" => "intent-1", "slug" => "sample", "title" => "Sample"},
               %{"scenarios" => [], "risks" => []},
               [],
               %{
                 route: "codex",
                 harness: "codex",
                 shaping: %{model: "m", effort: "low"},
                 developer: %{model: "m", effort: "low"},
                 reviewer: %{model: "m", effort: "low"},
                 helpers: %{
                   scout: %{model: "m", effort: "low"},
                   worker: %{model: "m", effort: "medium"},
                   expert: %{model: "m", effort: "medium"}
                 }
               },
               control
             )

    assert {:ok, state} = Tracking.start_attempt(state, "tok-1", 0)
    build_id = state.path |> Path.dirname() |> Path.basename()

    assert {:ok, binding} =
             ReviewPacket.write(state.path, 0, "{}", "tok-1", "cand-1", control)

    assert binding["path"] ==
             ".kogen/runtime/scenario-tracking/#{build_id}/review-packets/0.json"

    refute Path.type(binding["path"]) == :absolute
    resolved_packet = Path.expand(binding["path"], control)
    assert File.read!(resolved_packet) == "{}"

    assert {:ok, snapshot} = Tracking.retain_record_version(state, state.bytes)
    refute Path.type(snapshot["path"]) == :absolute
    refute Path.type(snapshot["sidecar"]) == :absolute
    resolved_sidecar = Path.expand(snapshot["sidecar"], control)
    assert File.read!(resolved_sidecar) == state.bytes

    # Both locators resolve under control's own scenario-tracking directory,
    # never under the (distinct) Candidate.
    tracking_dir = Path.join([control, ".kogen/runtime/scenario-tracking", build_id])
    assert String.starts_with?(resolved_packet, tracking_dir)
    assert String.starts_with?(resolved_sidecar, tracking_dir)
    refute String.starts_with?(resolved_packet, candidate)
    refute String.starts_with?(resolved_sidecar, candidate)
  end

  test "candidate-routing: a failed cycle's receipt log_path resolves under control's attempt directory even when the Candidate is a different tree, and settlement accepts it" do
    control =
      F.repo!(%{
        "dummy.txt" => "baseline\n",
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: check
            cost_class: offline-complete
            rank: 0
            dependencies: []
            provider_backed: false
            owner: fixture
        """
      })

    candidate =
      F.repo!(%{
        "Makefile" => ".PHONY: check\ncheck:\n\t@exit 1\n",
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: check
            cost_class: offline-complete
            rank: 0
            dependencies: []
            provider_backed: false
            owner: fixture
        """,
        "proof.txt" => "focused selector\n",
        "dummy.txt" => "baseline\n"
      })

    catalog = F.load_catalog!(candidate)
    scenario = F.scenario("s1", ["check"], offline: ["proof.txt"], affected_paths: ["dummy.txt"])
    plan = F.build_plan!(candidate, [scenario], catalog, guards: ["dummy.txt"])

    execution =
      F.initialize!(control, plan.targets, plan: plan, candidate_root: candidate)

    env = F.env(candidate, catalog, plan, [scenario], control_root: control)
    candidate_id = F.candidate_id!(candidate)

    {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
    cycle = List.last(state["cycles"])
    assert cycle["status"] == "failed"
    [receipt] = cycle["receipts"]

    refute Path.type(receipt["log_path"]) == :absolute

    resolved_log = Path.expand(receipt["log_path"], control)
    assert File.regular?(resolved_log)

    assert String.starts_with?(
             resolved_log,
             Path.join(control, ".kogen/runtime/scenario-tracking")
           )

    refute String.starts_with?(resolved_log, candidate)

    # `check` always fails in this fixture: run the remaining cycles until
    # verification is terminal (exhausted), so settlement has something to
    # settle.
    {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
    assert state["terminal_state"] == "pending"
    {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
    assert state["terminal_state"] == "exhausted"

    refute String.starts_with?(resolved_log, candidate)

    assert {:ok, _execution, _state} = Verification.settle(execution, "dev-1", candidate_id)
  end

  test "candidate-routing: a Build run from a third cwd whose target emits target evidence settles and publishes, capturing and verifying against the recorded Candidate root" do
    dir = Fixture.fixture!(target_evidence: true)

    third_cwd =
      Path.join(System.tmp_dir!(), "kogen-third-cwd-#{System.unique_integer([:positive])}")

    File.mkdir_p!(third_cwd)
    on_exit(fn -> File.rm_rf(third_cwd) end)

    assert :ok =
             Fixture.run(dir, cwd: third_cwd, edits: %{1 => "printf 'changed\\n' > dummy.txt"})

    record = Fixture.record!(dir)
    [attempt] = record["attempts"]
    assert attempt["outcome"] == "settled"

    receipt =
      attempt["verification"]["cycles"]
      |> List.last()
      |> Map.fetch!("receipts")
      |> Enum.find(&(&1["target"] == "check"))

    assert receipt["target_evidence"]["required_evidence"] != []
    assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{Fixture.slug()}"))
  end

  # --- bound-per-target-receipts ----------------------------------------

  test "each receipt carries every binding field, and status comes only from the exit code and cleanup" do
    dir =
      F.repo!(%{
        "Makefile" => """
        .PHONY: pass printer
        pass:
        \t@true
        printer:
        \t@echo PASS
        \t@exit 1
        """,
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: pass
            cost_class: offline-complete
            rank: 0
            dependencies: []
            provider_backed: false
            owner: fixture
          - name: printer
            cost_class: offline-complete
            rank: 1
            dependencies: []
            provider_backed: false
            owner: fixture
        """,
        "proof.txt" => "focused selector\n",
        "dummy.txt" => "baseline\n",
        ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
      })

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)

      scenario =
        F.scenario("s1", ["pass", "printer"],
          offline: ["proof.txt"],
          affected_paths: ["dummy.txt"]
        )

      plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])
      execution = F.initialize!(dir, plan.targets, plan: plan)
      env = F.env(dir, catalog, plan, [scenario])
      candidate_id = F.candidate_id!(dir)

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])
      assert cycle["status"] == "failed"

      [pass_receipt, printer_receipt] = cycle["receipts"]

      for receipt <- [pass_receipt, printer_receipt] do
        for key <- ~w(target status exit_code candidate_id attempt_token context_sha256
                      catalog_sha256 cycle_sequence started_at finished_at elapsed_ms
                      log_path log_sha256 cleanup) do
          assert Map.has_key?(receipt, key), "receipt for #{receipt["target"]} is missing #{key}"
        end

        assert receipt["candidate_id"] == candidate_id
        assert receipt["catalog_sha256"] == catalog.sha256
      end

      assert pass_receipt["status"] == "passed"
      assert printer_receipt["status"] == "failed"
      assert printer_receipt["exit_code"] != 0
      assert printer_receipt["output"] =~ "PASS"
    end)
  end

  test "a target that leaves a lingering process group member gets it terminated" do
    dir =
      F.repo!(%{
        "Makefile" => """
        .PHONY: pass lingering
        pass:
        \t@true
        lingering:
        \t@mkdir -p .kogen/runtime
        \t@sh -c 'sleep 5 & echo $$! > .kogen/runtime/lingering.pid'
        """,
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: pass
            cost_class: offline-complete
            rank: 0
            dependencies: []
            provider_backed: false
            owner: fixture
          - name: lingering
            cost_class: offline-complete
            rank: 1
            dependencies: []
            provider_backed: false
            owner: fixture
        """,
        "proof.txt" => "focused selector\n",
        "dummy.txt" => "baseline\n",
        ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
      })

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)

      scenario =
        F.scenario("s1", ["pass", "lingering"],
          offline: ["proof.txt"],
          affected_paths: ["dummy.txt"]
        )

      plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])
      execution = F.initialize!(dir, plan.targets, plan: plan)
      env = F.env(dir, catalog, plan, [scenario])
      candidate_id = F.candidate_id!(dir)

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])
      assert cycle["status"] == "passed"

      lingering_receipt = Enum.find(cycle["receipts"], &(&1["target"] == "lingering"))
      assert lingering_receipt["cleanup"] == "terminated"
      assert lingering_receipt["status"] == "passed"

      pid = Path.join(dir, ".kogen/runtime/lingering.pid") |> File.read!() |> String.trim()
      {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0, "the lingering process must have been reaped by the controller"
    end)
  end

  test "VerificationRunner.status/1 maps cleanup failed to a failed receipt" do
    assert VerificationRunner.status(%{
             "exit_code" => 0,
             "timed_out" => false,
             "cleanup" => "failed"
           }) ==
             "failed"

    assert VerificationRunner.status(%{
             "exit_code" => 0,
             "timed_out" => false,
             "cleanup" => "clean"
           }) ==
             "passed"

    assert VerificationRunner.status(%{
             "exit_code" => 1,
             "timed_out" => false,
             "cleanup" => "clean"
           }) ==
             "failed"

    assert VerificationRunner.status(%{
             "exit_code" => 0,
             "timed_out" => true,
             "cleanup" => "clean"
           }) ==
             "failed"
  end

  test "settlement rejects a receipt whose candidate id or catalog digest was edited, a rolled-back history, and an altered log" do
    dir =
      F.repo!(%{
        "Makefile" => """
        .PHONY: pass
        pass:
        \t@true
        """,
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: pass
            cost_class: offline-complete
            rank: 0
            dependencies: []
            provider_backed: false
            owner: fixture
        """,
        "proof.txt" => "focused selector\n",
        "dummy.txt" => "baseline\n",
        ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
      })

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)
      scenario = F.scenario("s1", ["pass"], offline: ["proof.txt"], affected_paths: ["dummy.txt"])
      plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])
      candidate_id = F.candidate_id!(dir)
      env = F.env(dir, catalog, plan, [scenario])

      # Sanity: an untampered cycle settles cleanly.
      base_execution = F.initialize!(dir, plan.targets, plan: plan)
      {base_execution, base_state} = F.run_cycle!(base_execution, "dev-1", candidate_id, env)

      assert {:ok, _execution, _state} =
               Verification.settle(base_execution, "dev-1", candidate_id)

      assert base_state["terminal_state"] == "passed"

      # A receipt whose candidate id was edited relative to its cycle's binding.
      tampered_candidate =
        update_in(base_state, ["cycles"], fn cycles ->
          List.update_at(cycles, -1, fn cycle ->
            update_in(cycle, ["receipts"], fn [receipt] ->
              [Map.put(receipt, "candidate_id", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")]
            end)
          end)
        end)

      assert {:error, _reason} = Verification.validate_state(tampered_candidate, base_execution)

      # A receipt whose catalog digest was edited relative to its cycle's binding.
      tampered_catalog =
        update_in(base_state, ["cycles"], fn cycles ->
          List.update_at(cycles, -1, fn cycle ->
            update_in(cycle, ["receipts"], fn [receipt] ->
              [Map.put(receipt, "catalog_sha256", String.duplicate("0", 64))]
            end)
          end)
        end)

      assert {:error, _reason} = Verification.validate_state(tampered_catalog, base_execution)

      # A rolled-back history file.
      rollback_execution = F.initialize!(dir, plan.targets, plan: plan)
      {rollback_execution, _state} = F.run_cycle!(rollback_execution, "dev-1", candidate_id, env)
      File.write!(rollback_execution.history_path, "")

      assert {:error, reason} = Verification.settle(rollback_execution, "dev-1", candidate_id)
      assert reason =~ "rolled back" or reason =~ "incomplete"

      # An altered log digest.
      log_execution = F.initialize!(dir, plan.targets, plan: plan)
      {log_execution, log_state} = F.run_cycle!(log_execution, "dev-1", candidate_id, env)
      [log_receipt] = List.last(log_state["cycles"])["receipts"]
      log_path = Path.expand(log_receipt["log_path"], dir)
      File.write!(log_path, "tampered log bytes\n", [:append])

      assert {:error, reason} = Verification.settle(log_execution, "dev-1", candidate_id)
      assert reason =~ "log digest changed"
    end)
  end

  test "Candidate-planted verification code with the controller's names is never loaded or run" do
    sentinel = Path.join(System.tmp_dir!(), "kogen-planted-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(sentinel) end)
    File.mkdir_p!(sentinel)

    planted_module = fn name ->
      """
      File.write!(#{inspect(Path.join(sentinel, name))}, "loaded")

      defmodule #{name} do
        def run_cycle(_, _, _, _), do: File.write!(#{inspect(Path.join(sentinel, name <> ".run"))}, "run")
        def settle(_, _, _), do: File.write!(#{inspect(Path.join(sentinel, name <> ".settle"))}, "run")
      end
      """
    end

    planted_script = fn name ->
      "#!/bin/sh\nprintf run > #{inspect(Path.join(sentinel, name))}\nprintf '{\"decision\":\"block\",\"reason\":\"planted\"}'\n"
    end

    dir =
      F.repo!(%{
        "Makefile" => ".PHONY: check\ncheck:\n\t@true\n",
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: check
            cost_class: offline-complete
            rank: 0
            dependencies: []
            provider_backed: false
            owner: fixture
        """,
        "proof.txt" => "focused selector\n",
        ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
      })

    # The Candidate plants modules and scripts under the controller's own
    # verification names; a controller that loaded or ran Candidate code would
    # leave a sentinel.
    for {path, content} <- [
          {"lib/kogen/build/verification.ex", planted_module.("Kogen.Build.Verification")},
          {"lib/kogen/build/verification_runner.ex",
           planted_module.("Kogen.Build.VerificationRunner")},
          {"lib/kogen/build/catalog_change.ex", planted_module.("Kogen.Build.CatalogChange")},
          {".codex/hooks/stop_runner.py", planted_script.("stop_runner")},
          {".codex/hooks/check.sh", planted_script.("check")},
          {"scripts/verification_runner.py", planted_script.("verification_runner")}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)
      scenario = F.scenario("s1", ["check"], offline: ["proof.txt"], affected_paths: ["lib/**"])
      plan = F.build_plan!(dir, [scenario], catalog, guards: ["lib/**"])
      execution = F.initialize!(dir, plan.targets, plan: plan)
      candidate_id = F.candidate_id!(dir)

      {execution, state} =
        F.run_cycle!(execution, "dev-1", candidate_id, F.env(dir, catalog, plan, [scenario]))

      assert List.last(state["cycles"])["status"] == "passed"

      assert {:ok, _execution, _state} =
               Verification.settle(execution, "dev-1", candidate_id)
    end)

    assert File.ls!(sentinel) == []

    for module <- [
          Kogen.Build.Verification,
          Kogen.Build.VerificationRunner,
          Kogen.Build.CatalogChange
        ] do
      refute to_string(:code.which(module)) =~ dir
    end
  end

  # --- no-special-gate-target --------------------------------------------

  test "a catalog with an offline `test` target and no `check` target runs exactly `make test`" do
    dir =
      F.repo!(%{
        "Makefile" => """
        .PHONY: test
        test:
        \t@true
        """,
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: test
            cost_class: offline-complete
            rank: 0
            dependencies: []
            provider_backed: false
            owner: fixture
        """,
        "proof.txt" => "focused selector\n",
        "dummy.txt" => "baseline\n",
        ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
      })

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)
      refute Map.has_key?(catalog.targets, "check")

      scenario = F.scenario("s1", ["test"], offline: ["proof.txt"], affected_paths: ["dummy.txt"])
      plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])
      assert plan.targets == ["test"]

      execution = F.initialize!(dir, plan.targets, plan: plan)
      env = F.env(dir, catalog, plan, [scenario])
      candidate_id = F.candidate_id!(dir)

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])
      assert cycle["status"] == "passed"
      assert Enum.map(cycle["receipts"], & &1["target"]) == ["test"]

      logs = Path.wildcard(Path.join(execution.log_root, "*"))

      assert Enum.map(logs, &Path.basename/1) == ["cycle-1-test.log"],
             "no unlisted target may run"

      # The local Verification Record's `target` field keeps the constant
      # `check` as a format value for existing readers; it selects nothing.
      assert {:ok, record} = Kogen.Check.read_record(dir)
      assert record["target"] == "check"
    end)
  end

  # --- offline-failures-own-budget ---------------------------------------
  #
  # `check` (offline) and `paid` (provider-backed, rank 100, depends on
  # `check`) are toggled through gitignored marker files, so the Candidate id
  # never changes across cycles.

  defp offline_budget_repo! do
    F.repo!(%{
      "Makefile" => """
      .PHONY: check paid
      check:
      \t@test ! -f .kogen/runtime/fail-check
      paid:
      \t@test ! -f .kogen/runtime/fail-paid
      """,
      "priv/kogen/verification_targets.yaml" => """
      targets:
        - name: check
          cost_class: offline-complete
          rank: 0
          dependencies: []
          provider_backed: false
          owner: fixture
        - name: paid
          cost_class: provider
          rank: 100
          dependencies: [check]
          provider_backed: true
          owner: fixture
          rehearsal:
            id: rehearse-paid
            command: "true"
            shared_entrypoints: ["paid.entrypoint"]
            correct_fixture: "paid-correct"
            wrong_fixture: "paid-wrong"
            trace_assertions: ["paid-trace"]
      """,
      "proof.txt" => "focused selector\n",
      "dummy.txt" => "baseline\n",
      ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
    })
  end

  # A scenario selecting a real provider-backed `target` must name it in
  # `proof.paid_target` with a `provider-required: <target>; observation:
  # …; offline-limit: …` reason (`VerificationPlan.valid_reason?/4`).
  defp paid_scenario(id, targets, target, opts) do
    F.scenario(
      id,
      targets,
      Keyword.merge(
        [
          paid_target: target,
          paid_reason:
            "provider-required: #{target}; observation: exercises the controller directly; offline-limit: none"
        ],
        opts
      )
    )
  end

  defp offline_budget_execution!(dir, opts) do
    catalog = F.load_catalog!(dir)

    scenario =
      paid_scenario("s1", ["check", "paid"], "paid",
        offline: ["proof.txt"],
        affected_paths: ["dummy.txt"]
      )

    plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])

    execution =
      F.initialize!(dir, plan.targets, Keyword.put(opts, :plan, plan))

    {execution, F.env(dir, catalog, plan, [scenario])}
  end

  defp touch!(dir, name), do: File.write!(Path.join(dir, ".kogen/runtime/#{name}"), "x\n")
  defp untouch!(dir, name), do: File.rm(Path.join(dir, ".kogen/runtime/#{name}"))

  test "offline failures spend only offline_retries, a later paid failure keeps its own budget, and the attempt settles" do
    dir = offline_budget_repo!()

    File.cd!(dir, fn ->
      {execution, env} =
        offline_budget_execution!(dir, retries: %{verification: 2, offline: 4})

      candidate_id = F.candidate_id!(dir)

      touch!(dir, "fail-check")
      {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle1 = List.last(state["cycles"])
      assert cycle1["status"] == "failed"
      assert cycle1["class"] == "offline"
      assert cycle1["offline_failures_before"] == 0
      assert cycle1["offline_failures_after"] == 1
      assert cycle1["failures_before"] == 0
      assert cycle1["failures_after"] == 0
      assert state["terminal_state"] == "pending"
      assert Enum.map(cycle1["receipts"], & &1["target"]) == ["check"]

      # A second offline failure, same Developer session resumed.
      {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle2 = List.last(state["cycles"])
      assert cycle2["class"] == "offline"
      assert cycle2["offline_failures_after"] == 2
      assert cycle2["failures_after"] == 0
      assert state["developer_session_id"] == "dev-1"

      # `check` passes; `paid` now fails. This spends `verification_retries`,
      # never `offline_retries`.
      untouch!(dir, "fail-check")
      touch!(dir, "fail-paid")
      {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle3 = List.last(state["cycles"])
      assert cycle3["class"] == "paid"
      assert cycle3["offline_failures_after"] == 2
      assert cycle3["failures_after"] == 1
      assert Enum.map(cycle3["receipts"], & &1["target"]) == ["check", "paid"]
      assert state["terminal_state"] == "pending"

      # Both pass; the attempt settles.
      untouch!(dir, "fail-paid")
      {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle4 = List.last(state["cycles"])
      assert cycle4["status"] == "passed"
      assert state["terminal_state"] == "passed"
      assert state["failures_since_pass"] == 0

      assert {:ok, _execution, _state} = Verification.settle(execution, "dev-1", candidate_id)
    end)
  end

  test "the fifth offline failure exhausts offline_retries while paid retries stay unspent" do
    dir = offline_budget_repo!()

    File.cd!(dir, fn ->
      {execution, env} =
        offline_budget_execution!(dir, retries: %{verification: 2, offline: 4})

      candidate_id = F.candidate_id!(dir)
      touch!(dir, "fail-check")

      {_execution, state} =
        Enum.reduce(1..5, {execution, nil}, fn _n, {execution, _state} ->
          F.run_cycle!(execution, "dev-1", candidate_id, env)
        end)

      cycle5 = List.last(state["cycles"])
      assert cycle5["class"] == "offline"
      assert cycle5["offline_failures_after"] == 5
      assert cycle5["failures_after"] == 0, "the paid budget stays unspent by offline failures"
      assert state["terminal_state"] == "offline_exhausted"
    end)
  end

  # --- offline-gate-before-paid-dispatch ----------------------------------

  test "every selected offline target runs before any provider-backed target, whatever the catalog's rank or dependencies say, and the Candidate is never rewritten" do
    dir =
      F.repo!(%{
        "Makefile" => """
        .PHONY: check paid
        paid:
        \t@test ! -f .kogen/runtime/fail-paid
        check:
        \t@test ! -f .kogen/runtime/fail-check
        """,
        "priv/kogen/verification_targets.yaml" => """
        targets:
          - name: paid
            cost_class: provider
            rank: 0
            dependencies: []
            provider_backed: true
            owner: fixture
            rehearsal:
              id: rehearse-paid
              command: "true"
              shared_entrypoints: ["paid.entrypoint"]
              correct_fixture: "paid-correct"
              wrong_fixture: "paid-wrong"
              trace_assertions: ["paid-trace"]
          - name: check
            cost_class: offline-complete
            rank: 100
            dependencies: []
            provider_backed: false
            owner: fixture
        """,
        "proof.txt" => "focused selector\n",
        "messy.txt" => "x=1;y  =2\n",
        "dummy.txt" => "baseline\n",
        ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
      })

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)

      # `verified_by` must list its targets in catalog rank order (a proof
      # rule, `VerificationPlan.verified_by_errors/3`), so `paid` (rank 0)
      # comes before `check` (rank 100) here; dispatch order is unaffected,
      # since offline targets always run first regardless of list or rank.
      scenario =
        paid_scenario("s1", ["paid", "check"], "paid",
          offline: ["proof.txt"],
          affected_paths: ["dummy.txt", "messy.txt"]
        )

      plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt", "messy.txt"])
      candidate_id = F.candidate_id!(dir)
      env = F.env(dir, catalog, plan, [scenario])
      messy_before = File.read!(Path.join(dir, "messy.txt"))

      execution =
        F.initialize!(dir, plan.targets, plan: plan, retries: %{verification: 2, offline: 4})

      touch!(dir, "fail-check")

      {execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle1 = List.last(state["cycles"])
      assert cycle1["status"] == "failed"

      assert Enum.map(cycle1["receipts"], & &1["target"]) == ["check"],
             "the paid target must never dispatch while the offline target fails, whatever its rank"

      untouch!(dir, "fail-check")
      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle2 = List.last(state["cycles"])
      assert cycle2["status"] == "passed"

      assert Enum.map(cycle2["receipts"], & &1["target"]) == ["check", "paid"],
             "the offline target still runs first even though `paid` has the lower rank"

      assert File.read!(Path.join(dir, "messy.txt")) == messy_before,
             "the controller never formats or otherwise rewrites the Candidate"
    end)
  end

  # --- controller-runs-prepare-before-paid --------------------------------

  defp prepare_repo!(entries) do
    F.repo!(%{
      "Makefile" => """
      .PHONY: check p1 p2 p3
      check:
      \t@true
      p1:
      \t@true
      p2:
      \t@true
      p3:
      \t@true
      """,
      "priv/kogen/verification_targets.yaml" => Jason.encode!(%{"targets" => entries}),
      "proof.txt" => "focused selector\n",
      "dummy.txt" => "baseline\n",
      ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
    })
  end

  defp offline_catalog_entry,
    do: %{
      "name" => "check",
      "cost_class" => "offline-complete",
      "rank" => 0,
      "dependencies" => [],
      "provider_backed" => false,
      "owner" => "fixture"
    }

  defp paid_catalog_entry(name, rank, prepare) do
    entry = %{
      "name" => name,
      "cost_class" => "provider",
      "rank" => rank,
      "dependencies" => ["check"],
      "provider_backed" => true,
      "owner" => "fixture",
      "rehearsal" => %{
        "id" => "rehearse-#{name}",
        "command" => "true",
        "shared_entrypoints" => ["#{name}.entrypoint"],
        "correct_fixture" => "#{name}-correct",
        "wrong_fixture" => "#{name}-wrong",
        "trace_assertions" => ["#{name}-trace"]
      }
    }

    if prepare, do: Map.put(entry, "prepare", prepare), else: entry
  end

  test "prepare runs for every dispatched provider-backed target before it starts; a Candidate-caused prepare failure spends offline_retries and dispatches no paid target" do
    dir =
      prepare_repo!([
        offline_catalog_entry(),
        paid_catalog_entry("p1", 100, nil),
        paid_catalog_entry("p2", 200, ["sh", "-c", "exit 0"]),
        paid_catalog_entry("p3", 300, ["sh", "-c", "echo prepare failed >&2; exit 1"])
      ])

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)

      # Each provider-backed target needs its own scenario (a scenario names
      # at most one paid target); the plan selects the union.
      scenarios =
        for target <- ["p1", "p2", "p3"] do
          paid_scenario("s-#{target}", ["check", target], target,
            offline: ["proof.txt"],
            affected_paths: ["dummy.txt"]
          )
        end

      plan = F.build_plan!(dir, scenarios, catalog, guards: ["dummy.txt"])
      candidate_id = F.candidate_id!(dir)
      env = F.env(dir, catalog, plan, scenarios)

      execution =
        F.initialize!(dir, plan.targets, plan: plan, retries: %{verification: 2, offline: 4})

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])

      assert cycle["status"] == "failed"
      assert cycle["class"] == "offline"

      assert Enum.map(cycle["receipts"], & &1["target"]) == ["check"],
             "no paid target may run once a dispatched target's prepare failed"

      prepared = Enum.map(cycle["prepare"], & &1["target"])
      assert prepared == ["p2", "p3"], "p1 declares no prepare and needs no step"

      failed_prepare = Enum.find(cycle["prepare"], &(&1["target"] == "p3"))
      assert failed_prepare["status"] == "failed"
      assert failed_prepare["class"] == "offline"
      assert is_binary(failed_prepare["log_sha256"])

      passed_prepare = Enum.find(cycle["prepare"], &(&1["target"] == "p2"))
      assert passed_prepare["status"] == "passed"
    end)
  end

  test "a prepare environment result stops the Build at once, spending no retry and dispatching no paid target" do
    frame =
      "KOGEN_PREPARE_RESULT\t" <>
        Jason.encode!(%{"class" => "environment", "reason" => "harness scope missing"})

    dir =
      prepare_repo!([
        offline_catalog_entry(),
        paid_catalog_entry("p1", 100, ["sh", "-c", "echo '#{frame}'; exit 1"])
      ])

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)

      scenario =
        paid_scenario("s1", ["check", "p1"], "p1",
          offline: ["proof.txt"],
          affected_paths: ["dummy.txt"]
        )

      plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])
      candidate_id = F.candidate_id!(dir)
      env = F.env(dir, catalog, plan, [scenario])

      execution =
        F.initialize!(dir, plan.targets, plan: plan, retries: %{verification: 2, offline: 4})

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])

      assert cycle["status"] == "failed"
      assert cycle["class"] == "environment"
      assert state["terminal_state"] == "environment"
      assert Enum.map(cycle["receipts"], & &1["target"]) == ["check"]
      assert cycle["failure"]["reason"] == "harness scope missing"
    end)
  end

  test "a catalog with no prepare at all runs its paid targets directly" do
    dir =
      prepare_repo!([
        offline_catalog_entry(),
        paid_catalog_entry("p1", 100, nil)
      ])

    File.cd!(dir, fn ->
      catalog = F.load_catalog!(dir)

      scenario =
        paid_scenario("s1", ["check", "p1"], "p1",
          offline: ["proof.txt"],
          affected_paths: ["dummy.txt"]
        )

      plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])
      candidate_id = F.candidate_id!(dir)
      env = F.env(dir, catalog, plan, [scenario])

      execution =
        F.initialize!(dir, plan.targets, plan: plan, retries: %{verification: 2, offline: 4})

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])

      assert cycle["status"] == "passed"
      refute Map.has_key?(cycle, "prepare")
      assert Enum.map(cycle["receipts"], & &1["target"]) == ["check", "p1"]
    end)
  end

  # --- environment-and-provider-classes (controller parts) ----------------

  defp provider_tail(name) do
    Path.expand("../support/provider_tails/#{name}", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("output")
  end

  defp provider_repo! do
    F.repo!(%{
      "Makefile" => """
      .PHONY: check paid
      check:
      \t@true
      paid:
      \t@if [ -f .kogen/runtime/paid-retried ]; then \\
      \t\techo retried-ok; \\
      \telse \\
      \t\ttouch .kogen/runtime/paid-retried; \\
      \t\tcat .kogen/runtime/paid-tail.txt; \\
      \t\texit 1; \\
      \tfi
      """,
      "priv/kogen/verification_targets.yaml" => """
      targets:
        - name: check
          cost_class: offline-complete
          rank: 0
          dependencies: []
          provider_backed: false
          owner: fixture
        - name: paid
          cost_class: provider
          rank: 100
          dependencies: [check]
          provider_backed: true
          owner: fixture
          rehearsal:
            id: rehearse-paid
            command: "true"
            shared_entrypoints: ["paid.entrypoint"]
            correct_fixture: "paid-correct"
            wrong_fixture: "paid-wrong"
            trace_assertions: ["paid-trace"]
      """,
      "proof.txt" => "focused selector\n",
      "dummy.txt" => "baseline\n",
      ".gitignore" => ".kogen/build.lock\n.kogen/runtime/\n"
    })
  end

  defp provider_execution!(dir) do
    catalog = F.load_catalog!(dir)

    scenario =
      paid_scenario("s1", ["check", "paid"], "paid",
        offline: ["proof.txt"],
        affected_paths: ["dummy.txt"]
      )

    plan = F.build_plan!(dir, [scenario], catalog, guards: ["dummy.txt"])

    execution =
      F.initialize!(dir, plan.targets, plan: plan, retries: %{verification: 2, offline: 4})

    {execution, F.env(dir, catalog, plan, [scenario])}
  end

  test "an overloaded or 5xx paid target is retried once on the same Candidate and settles when the retry passes, spending nothing" do
    dir = provider_repo!()

    File.cd!(dir, fn ->
      {execution, env} = provider_execution!(dir)
      candidate_id = F.candidate_id!(dir)

      File.write!(
        Path.join(dir, ".kogen/runtime/paid-tail.txt"),
        provider_tail("hjeqtbsg_codex_capacity_stream.json")
      )

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])

      assert cycle["status"] == "passed", "the retry on the same Candidate passed"
      assert state["failures_since_pass"] == 0
      assert state["offline_failures"] in [0, nil]

      [first] = cycle["provider_failures"]
      assert first["marker"]["kind"] == "overload"
      assert first["marker"]["retry"] == true
    end)
  end

  test "a usage limit paid failure is never retried and stops the Build as provider" do
    dir = provider_repo!()

    File.cd!(dir, fn ->
      {execution, env} = provider_execution!(dir)
      candidate_id = F.candidate_id!(dir)

      # This Makefile recipe only fails once (it passes on any later
      # invocation), which already proves no retry was attempted: a usage
      # limit is a single, unretried failure.
      File.write!(
        Path.join(dir, ".kogen/runtime/paid-tail.txt"),
        provider_tail("be_n9crq_claude_session_limit.json")
      )

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])

      assert cycle["status"] == "failed"
      assert cycle["class"] == "provider"
      assert state["terminal_state"] == "provider"
      refute Map.has_key?(cycle, "provider_failures")
      assert cycle["failure"]["provider"]["kind"] == "usage_limit"
      assert cycle["failure"]["provider"]["retry"] == false
      [paid_receipt] = Enum.filter(cycle["receipts"], &(&1["target"] == "paid"))
      assert paid_receipt["output"] =~ "session limit"
    end)
  end

  test "a second overload failure stops the Build as provider, with the first attempt retained" do
    dir = provider_repo!()

    File.cd!(dir, fn ->
      {execution, env} = provider_execution!(dir)

      # Simplify the recipe so both attempts (the original and the
      # controller's one automatic retry) emit the same overload marker.
      # `Makefile` is tracked, so the Candidate id is read only after this
      # edit.
      File.write!(
        Path.join(dir, "Makefile"),
        ".PHONY: check paid\ncheck:\n\t@true\npaid:\n\t@cat .kogen/runtime/paid-tail.txt\n\t@exit 1\n"
      )

      candidate_id = F.candidate_id!(dir)

      File.write!(
        Path.join(dir, ".kogen/runtime/paid-tail.txt"),
        provider_tail("hjeqtbsg_codex_capacity_stream.json")
      )

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])

      assert cycle["status"] == "failed"
      assert cycle["class"] == "provider"
      assert state["terminal_state"] == "provider"
      assert state["failures_since_pass"] == 0

      [first] = cycle["provider_failures"]
      assert first["marker"]["retry"] == true
      assert cycle["failure"]["provider"]["kind"] == "overload"
    end)
  end

  # Negative controls: a timeout is never a provider marker, whether Kogen's
  # own harness turn timeout inside a paid target (btwokrNx's exit 124) or an
  # ExUnit timeout. Each stays a paid failure that spends one
  # `verification_retries` and returns to the Developer.
  for tail <- [
        "btwokrnx_c1_turn_timeout_negative_control.json",
        "haoggjsc_c2_exunit_timeout_negative_control.json"
      ] do
    test "a paid target failing with #{tail} is a paid failure that resumes the Developer" do
      dir = provider_repo!()

      File.cd!(dir, fn ->
        {execution, env} = provider_execution!(dir)
        candidate_id = F.candidate_id!(dir)

        File.write!(
          Path.join(dir, ".kogen/runtime/paid-tail.txt"),
          provider_tail(unquote(tail))
        )

        {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
        cycle = List.last(state["cycles"])

        assert cycle["status"] == "failed"
        assert cycle["class"] == "paid"
        refute Map.has_key?(cycle, "provider_failures")
        refute Map.has_key?(cycle["failure"], "provider")
        assert state["failures_since_pass"] == 1
        assert state["terminal_state"] == "pending"
      end)
    end
  end

  describe "provider markers on Developer and Reviewer turns" do
    @capacity "hjeqtbsg_codex_capacity_stream.json"
    @session_limit "be_n9crq_claude_session_limit.json"

    test "an overloaded Developer turn resumes the same session once with the same prompt and the Build settles, spending nothing" do
      dir = Fixture.fixture!()

      assert :ok =
               Fixture.run(dir,
                 provider_fail: ["developer-1"],
                 provider_tail: provider_tail(@capacity)
               )

      [attempt] = Fixture.record!(dir)["attempts"]

      assert [%{"role" => "developer", "session_id" => "developer-session"} = retry] =
               attempt["provider_retries"]

      assert retry["marker"]["kind"] == "overload"
      assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["passed"]

      # The retry is a resume of the exact session the failed turn started,
      # carrying the same prompt as the failed launch.
      assert fake_state(dir, "developer-invocations") == "2"
      assert fake_state(dir, "developer-invocation-2") =~ ~r/^exec resume .*developer-session -$/

      assert fake_state(dir, "developer-invocation-1-prompt") ==
               fake_state(dir, "developer-invocation-2-prompt")
    end

    test "a usage-limited Developer turn is never retried and stops the Build as provider" do
      dir = Fixture.fixture!()

      assert {:error, reason} =
               Fixture.run(dir,
                 provider_fail: ["developer-1"],
                 provider_tail: provider_tail(@session_limit)
               )

      assert reason =~ "provider failure during Developer turn (class provider, usage_limit)"
      assert fake_state(dir, "developer-invocations") == "1"
      [attempt] = Fixture.record!(dir)["attempts"]
      assert attempt["stop_class"] == "provider"
      refute Map.has_key?(attempt, "verification")
    end

    test "a second overloaded Developer turn stops the Build as provider" do
      dir = Fixture.fixture!()

      assert {:error, reason} =
               Fixture.run(dir,
                 provider_fail: ["developer-1", "developer-2"],
                 provider_tail: provider_tail(@capacity)
               )

      assert reason =~ "provider failure during Developer turn (class provider, overload)"
      assert fake_state(dir, "developer-invocations") == "2"
      [attempt] = Fixture.record!(dir)["attempts"]
      assert attempt["stop_class"] == "provider"
      assert [%{"role" => "developer"}] = attempt["provider_retries"]
    end

    test "an overloaded Review gets one fresh Review with the same packet and the Build settles" do
      dir = Fixture.fixture!()

      assert :ok =
               Fixture.run(dir,
                 provider_fail: ["reviewer-1"],
                 provider_tail: provider_tail(@capacity)
               )

      assert fake_state(dir, "reviews") == "2"

      assert fake_state(dir, "reviewer-packet-1.json") ==
               fake_state(dir, "reviewer-packet-2.json")

      [attempt] = Fixture.record!(dir)["attempts"]
      assert [%{"role" => "reviewer"} = retry] = attempt["provider_retries"]
      assert retry["marker"]["kind"] == "overload"
      assert attempt["verdict"]["verdict"] == "accept"
    end

    test "a usage-limited Review is never retried and stops the Build as provider" do
      dir = Fixture.fixture!()

      assert {:error, reason} =
               Fixture.run(dir,
                 provider_fail: ["reviewer-1"],
                 provider_tail: provider_tail(@session_limit)
               )

      assert reason =~ "provider failure during Review (class provider, usage_limit)"
      assert fake_state(dir, "reviews") == "1"
      [attempt] = Fixture.record!(dir)["attempts"]
      assert attempt["stop_class"] == "provider"
    end

    test "a Codex Developer login rejection stops once as an environment failure" do
      dir = Fixture.fixture!()

      assert {:error, reason} =
               Fixture.run(dir,
                 provider_fail: ["developer-1"],
                 provider_tail: provider_tail("synthetic_codex_refresh_failed.json")
               )

      assert String.starts_with?(
               reason,
               "developer: codex login rejected (401) (class environment); run `mix kogen.codex.login`"
             )

      assert fake_state(dir, "developer-invocations") == "1"
      [attempt] = Fixture.record!(dir)["attempts"]
      assert attempt["stop_class"] == "environment"
    end

    test "a Claude Reviewer login rejection is not a review failure and is not retried" do
      dir = Fixture.fixture!()

      assert {:error, reason} =
               Fixture.run(dir,
                 provider_fail: ["reviewer-1"],
                 provider_tail: provider_tail("xfjcrm76_claude_oauth_revoked.json")
               )

      assert String.starts_with?(
               reason,
               "reviewer: claude login rejected (401) (class environment); run `mix kogen.claude.login`"
             )

      refute reason =~ "review-failure"
      assert fake_state(dir, "reviews") == "1"
      [attempt] = Fixture.record!(dir)["attempts"]
      assert attempt["stop_class"] == "environment"
    end

    defp fake_state(dir, name), do: File.read!(Kogen.CandidateFixture.fake_state(dir, name))
  end

  test "a paid target login rejection is terminal environment without retry" do
    dir = provider_repo!()

    File.cd!(dir, fn ->
      {execution, env} = provider_execution!(dir)
      candidate_id = F.candidate_id!(dir)

      File.write!(
        Path.join(dir, ".kogen/runtime/paid-tail.txt"),
        provider_tail("xfjcrm76_claude_oauth_revoked.json")
      )

      {_execution, state} = F.run_cycle!(execution, "dev-1", candidate_id, env)
      cycle = List.last(state["cycles"])

      assert cycle["status"] == "failed"
      assert cycle["class"] == "environment"
      assert state["terminal_state"] == "environment"

      assert cycle["failure"]["reason"] ==
               "make paid: claude login rejected (401) (class environment); run `mix kogen.claude.login`"

      refute Map.has_key?(cycle, "provider_failures")
    end)
  end

  # --- unchanged-candidate-stops -------------------------------------------

  test "a Developer turn that leaves the Candidate unchanged after a failed cycle stops the Build without re-running the cycle" do
    dir = Fixture.fixture!()

    # `fail_all: [1]` keeps `check` failing forever; `freeze_resume_edit:
    # [1]` suppresses the fixture's default resume-edit for the first
    # resume, so the Candidate is byte-identical to cycle 1's failed one.
    assert {:error, reason} = Fixture.run(dir, fail_all: [1], freeze_resume_edit: [1])

    assert reason =~ "Candidate unchanged since failed cycle 1 (class offline)"
    assert reason =~ "signature:"

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    assert attempt["stop_class"] == "unchanged_candidate"
    assert attempt["unchanged_candidate"]["cycle"] == 1
    assert attempt["unchanged_candidate"]["class"] == "offline"
    # This stop never reaches `settle_verification` (only a settled terminal
    # state does), so the attempt carries no `verification` key; the single
    # failed cycle's own record lives in the attempt's verification state.
    refute Map.has_key?(attempt, "verification")

    [state_path] =
      Path.wildcard(
        Path.join(dir, ".kogen/runtime/scenario-tracking/*/verification/attempt-*/state.json")
      )

    state = state_path |> File.read!() |> Jason.decode!()
    assert Enum.map(state["cycles"], & &1["status"]) == ["failed"]

    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resumes")) == "1",
           "the controller must not re-run a second cycle on the unchanged Candidate"
  end

  test "a changed Candidate after a failed cycle is verified normally (control for the unchanged-Candidate stop)" do
    dir = Fixture.fixture!()

    # The default fixture behaviour (every resume edits `dummy.txt`) is the
    # positive control: `fail_first` clears the failure on the resumed turn,
    # and the resumed turn's default edit changes the Candidate, so the
    # controller must run (and here, pass) a second cycle rather than
    # stopping as unchanged.
    case Fixture.run(dir, fail_first: [1]) do
      {:error, reason} -> refute reason =~ "Candidate unchanged"
      :ok -> :ok
    end

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]
  end

  # `Kogen.ScriptedBuildFixture.run/2` unconditionally clears
  # `KOGEN_RAW_LOG_DIR` around its call so unrelated tests never leak private
  # raw logs; this replicates its Codex-protocol environment without that
  # deletion, so this test alone can observe archiving.
  defp run_with_raw_log_dir!(dir, archive_dir, opts) do
    runtime = Path.join(dir, ".kogen/runtime")
    notes_dir = Path.join(runtime, "handoff-notes")
    File.mkdir_p!(notes_dir)

    root = Path.expand("../..", __DIR__)

    env = [
      {"KOGEN_HARNESS", Path.join(dir, "provider.py")},
      {"HANDOFF_NOTES_DIR", notes_dir},
      {"HANDOFF_REVIEWS", Keyword.get(opts, :reviews, "accept")},
      {"HANDOFF_RESPONSE_HELPER", Path.join(root, "test/support/scenario_response.py")},
      {"HANDOFF_FAIL_FIRST", Enum.join(Keyword.get(opts, :fail_first, []), ",")},
      {"HANDOFF_FAIL_ALL", Enum.join(Keyword.get(opts, :fail_all, []), ",")},
      {"HANDOFF_PACKET_MUTATION", ""},
      {"FAKE_JEV_LOG_DIR", Path.join(runtime, "fake-jev")},
      {"FAKE_JEV_ANSWERS", "{}"},
      {"FAKE_SECURITY_ITEM", "present"},
      {"KOGEN_JEV_TRANSPORT", Kogen.FakeJev.transport_path()},
      {"KOGEN_JEV_SECURITY", Kogen.FakeJev.security_path()},
      {"KOGEN_RAW_LOG_DIR", archive_dir}
    ]

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    try do
      File.cd!(dir, fn -> Kogen.Build.run(Fixture.slug(), nil, dir) end)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
