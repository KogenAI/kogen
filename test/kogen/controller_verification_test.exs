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

    assert reason =~ "verification retries exhausted after cycle 3"

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
    assert verification["terminal_state"] == "exhausted"
    assert verification["candidate_id"] != "forged"

    [attempt_verification_dir] =
      Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/verification/attempt-*"))

    state = attempt_verification_dir |> Path.join("state.json") |> File.read!() |> Jason.decode!()
    assert state["terminal_state"] == "exhausted"
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

  test "the third consecutive failure exhausts verification and stops before Jev and Review" do
    dir = Fixture.fixture!()

    assert {:error, reason} = Fixture.run(dir, fail_all: [1])

    assert String.starts_with?(reason, "verification retries exhausted after cycle 3")
    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
    refute File.exists?(Path.join(dir, ".kogen/runtime/fake-jev"))
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "verification-resumes")) == "2"

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ~w(failed failed failed)
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
